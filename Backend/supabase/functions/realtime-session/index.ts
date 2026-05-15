// POST /functions/v1/realtime-session
// Logical endpoint: POST /v1/ai/realtime-session (spec §3).
//
// Mints one Gemini Live ephemeral token for one Cook Session. Premium+
// only — voice cook sessions gate on voice_cook_mode entitlement and
// consume one voice_cook_session quota row at mint time.
//
// Flow (happy path):
//   1. Auth: session JWT (AUTH-01 on failure)
//   2. Body: Zod parse (VAL-01 on failure)
//   3. User row read: banned / merged / missing
//   4. Kill switch: `disable_cook_realtime` → 503 AI-VOICE-01
//   5. Entitlement: effectiveVoiceEnabled() → 403 ENT-VOICE-01 if Free
//   6. Quota: atomic voice_cook_session increment → 429 RATE-01 if capped
//   7. Prompt: read active cook_mode_realtime v1.0.0
//   8. Render system prompt with recipe + household context
//   9. mintLiveToken() → 502 AI-01 + quota refund on Gemini upstream fail
//  10. Log ai_request_log, return { auth_token, expires_at, session_id,
//      ws_url, prompt_version }
//
// The response's `auth_token` value is the mint's `.name` field
// (auth_tokens/<hex>). iOS passes it unchanged as the `access_token`
// query param on the WebSocket URL (which we also pre-build into
// ws_url for convenience).
//
// Quota refund rules (match dinner-solve pattern):
//   - Refund ONLY on mint upstream 5xx / timeout.
//   - Do NOT refund on iOS-side WebSocket failures (work was done; any
//     minted token's quota charge stands even if the client never opens
//     the WS).

import { ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readAppUser } from '../_shared/identity.ts';
import { readFlags } from '../_shared/flags.ts';
import { effectiveVoiceEnabled, readEntitlement } from '../_shared/entitlements.ts';
import { hashCanonicalKey } from '../_shared/hashing.ts';
import { captureSafe } from '../_shared/posthog.ts';
import { incrementQuotaAtomic, refundQuota } from '../_shared/quota.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiModel } from '../_shared/gemini.ts';
import { LiveMintError, mintLiveToken } from '../_shared/live_mint.ts';
import { logAIRequest } from '../_shared/ai_request_log.ts';
import {
  createLogger,
  type Logger,
  requestIdFrom,
  sanitizeErrorForLog,
} from '../_shared/logger.ts';
import { checkAndIncrement, extractSourceIP, ipBucket } from '../_shared/rate_limiter.ts';
import { RealtimeSessionRequest, zodToFieldErrors } from '../_shared/validation.ts';

const FEATURE_KEY = 'cook_mode_realtime';
const MODEL = GeminiModel.FlashLivePreview;

/** PostgREST error.code for SQLSTATE 23505 (unique_violation). */
const UNIQUE_VIOLATION_CODE = '23505';

/**
 * SCA-145 — refund-audit observability. Emit `voice_quota_refund` to
 * PostHog from the two refund call sites in the request handler. The
 * is_refresh=false increment-then-refund path on the placeholder-key
 * CI path is observationally identical to never-incremented at the
 * `usage_counters` layer; this event disambiguates by stamping every
 * refund decision so dashboards/tests can pin the correct branch.
 *
 * Spec §15 + CLAUDE.md telemetry list + canonical-properties.md §8
 * register this event.
 *
 * Properties:
 * - `request_id` — request-scoped correlator. NOTE: both refund call
 *   sites return BEFORE `logAIRequest()`, so the matching
 *   `ai_request_log` row does NOT exist. `request_id` correlates
 *   only with the function logger's structured-output lines (which
 *   expire) — not with a Supabase row. Ops triage finds the
 *   refunded request via PostHog Insight on this event, NOT via a
 *   join against `ai_request_log`.
 * - `reason` — what tripped the refund. Discriminated:
 *     `no_active_prompt` — prompt-version table empty for FEATURE_KEY
 *     `mint_failed` — Gemini /v1alpha/auth_tokens returned 4xx/5xx
 *     `mint_unexpected_error` — non-LiveMintError thrown during mint
 * - `upstream_status` — number, present iff `reason='mint_failed'` and
 *   the LiveMintError carried a status code. Lets ops correlate
 *   refund storms with Gemini outage windows.
 *
 * `is_refresh` is intentionally NOT a property: the `didConsumeQuota`
 * guard short-circuits refresh mints before the refund branch fires,
 * making `is_refresh=true` structurally unreachable here. Emitting a
 * dead property without an alarm to detect inversion is decorative;
 * Sprint-B-review W6 dropped it.
 *
 * Privacy: distinct_id is `hashCanonicalKey(canonical_user_key)` —
 * 16-char SHA-256 prefix, same as every other server emit. No user
 * content (ADR 0009). Failure is swallowed via `captureSafe`'s
 * internal try/catch; the user's HTTP response isn't gated on
 * PostHog ingest.
 */
async function emitVoiceQuotaRefund(
  log: Logger,
  args: {
    canonicalUserKey: string;
    requestId: string;
    reason: 'no_active_prompt' | 'mint_failed' | 'mint_unexpected_error';
    upstreamStatus?: number;
  },
): Promise<void> {
  const properties: Record<string, unknown> = {
    request_id: args.requestId,
    reason: args.reason,
  };
  if (args.upstreamStatus !== undefined) {
    properties.upstream_status = args.upstreamStatus;
  }
  await captureSafe(log, {
    event: 'voice_quota_refund',
    distinctIdSource: () => hashCanonicalKey(args.canonicalUserKey),
    properties,
  });
}

/**
 * Supersede any prior open `voice_session_owners` row for this user,
 * then insert the new one. Retries once on unique_violation — the
 * UNIQUE partial index `voice_session_owners_one_open_per_user_uniq`
 * enforces "at most one open row per user" at the DB layer, so a
 * concurrent-mint race produces 23505 on one side. Single retry
 * handles the two-way race; a three-way race is pathological and
 * logged.
 *
 * Returns true if the new row landed, false if both attempts failed.
 */
async function supersedeAndInsertWithRetry(args: {
  client: ReturnType<typeof createServiceClient>;
  sessionId: string;
  canonicalUserKey: string;
  userLog: { warn: (msg: string, fields?: Record<string, unknown>) => void };
}): Promise<boolean> {
  for (let attempt = 1; attempt <= 2; attempt++) {
    // Supersede any currently-open row for this user.
    const { error: updateErr } = await args.client
      .from('voice_session_owners')
      .update({ closed_at: new Date().toISOString() })
      .eq('canonical_user_key', args.canonicalUserKey)
      .is('closed_at', null);
    if (updateErr) {
      args.userLog.warn('voice_session_owner_supersede_failed', {
        attempt,
        err: updateErr.message,
      });
      // Supersede failure doesn't prevent the INSERT from trying —
      // if the unique index rejects it we know why. If it succeeds,
      // we accept that the prior row may still be open (stale
      // closed_at), which voice-turn-usage will gate correctly.
    }
    const { error: insertErr } = await args.client
      .from('voice_session_owners')
      .insert({
        session_id: args.sessionId,
        canonical_user_key: args.canonicalUserKey,
      });
    if (!insertErr) return true;
    // Retry only on unique_violation (23505). All other errors we
    // log and bail — the issue isn't a race we can resolve by
    // retrying (network, permission, schema drift).
    if (insertErr.code !== UNIQUE_VIOLATION_CODE) {
      args.userLog.warn('voice_session_owner_insert_failed', {
        attempt,
        code: insertErr.code,
        err: insertErr.message,
      });
      return false;
    }
    args.userLog.warn('voice_session_owner_insert_race_retry', {
      attempt,
      code: insertErr.code,
    });
  }
  return false;
}

interface WireResponse {
  auth_token: string;
  expires_at: string;
  session_id: string;
  ws_url: string;
  prompt_version: string;
  /** Pre-serialized `{"setup": {...}}` frame iOS MUST send as the first
   * WebSocket message after `open`. Server waits for this before
   * emitting `setupComplete`, even with a Constrained ephemeral token.
   * See live_mint.setupFrameJSON for provenance. */
  setup_frame_json: string;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/realtime-session';
  const log = await createLogger(requestId, endpoint);

  if (req.method !== 'POST') {
    log.warn('method_not_allowed', { method: req.method });
    return jsonError(
      ErrorCode.METHOD_NOT_ALLOWED_01,
      405,
      { message: 'Method Not Allowed; use POST.', allowed: ['POST'] },
      requestId,
    );
  }

  const started = performance.now();
  log.info('request_start');

  // ---------------------------------------------------------------------
  // 1. Auth
  // ---------------------------------------------------------------------
  let claims;
  try {
    claims = await verifySessionJWT(req);
  } catch (err) {
    if (err instanceof AuthError) {
      log.warn('auth_failed', { reason: err.reason });
      return jsonError(
        ErrorCode.AUTH_01,
        401,
        { message: 'Session expired or missing.', reason: err.reason },
        requestId,
      );
    }
    log.error('auth_unexpected', err);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }

  const userLog = await createLogger(requestId, endpoint, claims.canonical_user_key);

  // ---------------------------------------------------------------------
  // 2. Body validation
  // ---------------------------------------------------------------------
  let body: RealtimeSessionRequest;
  try {
    const raw = await req.text();
    body = RealtimeSessionRequest.parse(JSON.parse(raw));
  } catch (err) {
    if (err instanceof ZodError) {
      userLog.warn('validation_failed', { issue_count: err.issues.length });
      return jsonError(
        ErrorCode.VAL_01,
        400,
        {
          message: 'Request body failed validation.',
          field_errors: zodToFieldErrors(err),
        },
        requestId,
      );
    }
    userLog.warn('json_parse_failed', { err: sanitizeErrorForLog(err) });
    return jsonError(
      ErrorCode.VAL_01,
      400,
      {
        message: 'Request body is not valid JSON.',
        field_errors: [{ field: '<root>', issue: 'invalid JSON' }],
      },
      requestId,
    );
  }

  const client = createServiceClient();

  // ---------------------------------------------------------------------
  // 3. User row (banned / merged / missing)
  // ---------------------------------------------------------------------
  const userRow = await readAppUser(client, claims.canonical_user_key);
  if (!userRow) {
    userLog.warn('user_row_missing');
    return jsonError(
      ErrorCode.AUTH_01,
      401,
      { message: 'User not found; re-bootstrap.', reason: 'user_stale' },
      requestId,
    );
  }
  if (userRow.status === 'banned') {
    userLog.warn('banned_user_blocked');
    return jsonError(
      ErrorCode.BILL_01,
      403,
      { message: 'Account is not eligible for Stir.', state: 'banned' },
      requestId,
    );
  }
  if (userRow.merged_into) {
    userLog.info('merged_user_re_bootstrap_required');
    return jsonError(
      ErrorCode.AUTH_01,
      401,
      {
        message: 'User identity was merged; re-bootstrap required.',
        reason: 'user_stale',
      },
      requestId,
    );
  }

  // ---------------------------------------------------------------------
  // 3.5 Rate limit (IP + user) — applies to BOTH fresh mints and
  //     refresh mints. Refreshes bypass the monthly voice_cook_session
  //     quota (ADR 0014 — is_refresh skips increment); without a
  //     rate-limit layer a runaway is_refresh=true loop could drive
  //     Gemini API spend indefinitely. Fail-open on rate limiter
  //     outage (same posture as other AI endpoints).
  // ---------------------------------------------------------------------
  const sourceIP = extractSourceIP(req);
  try {
    const ipRl = await checkAndIncrement(client, 'ip:realtime_session_daily', sourceIP);
    if (!ipRl.allowed) {
      // P2-C (2026-04-23 filed; 2026-04-24 shipped as HMAC-SHA256):
      // log salted+hashed IP. Enforcement still keys on raw IP via
      // the rate-limit bucket; logs get the bucket form so retention
      // doesn't hold raw IP PII. `ipBucket` is async because WebCrypto's
      // HMAC is async; see _shared/rate_limiter.ts.
      userLog.warn('rate_limited', {
        scope: 'ip:realtime_session_daily',
        source_ip_bucket: await ipBucket(sourceIP),
        is_refresh: body.is_refresh,
      });
      return jsonError(
        ErrorCode.RATE_01,
        429,
        {
          message: 'Too many voice session starts. Try again shortly.',
          scope: 'ip:realtime_session_daily',
          retry_after_seconds: ipRl.retry_after_seconds,
          reset_at: ipRl.reset_at,
        },
        requestId,
      );
    }
    const userRl = await checkAndIncrement(
      client,
      'user:realtime_session_hourly',
      claims.canonical_user_key,
    );
    if (!userRl.allowed) {
      userLog.warn('rate_limited', {
        scope: 'user:realtime_session_hourly',
        is_refresh: body.is_refresh,
      });
      return jsonError(
        ErrorCode.RATE_01,
        429,
        {
          message: 'Too many voice session starts in the past hour. Try again shortly.',
          scope: 'user:realtime_session_hourly',
          retry_after_seconds: userRl.retry_after_seconds,
          reset_at: userRl.reset_at,
        },
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // SCA-396: fail-open is intentional — see ADR 0036.
    // Post-auth + billable + paid-tier; entitlement gate (Premium/Pro)
    // catches Free-tier abuse first.
  }

  // ---------------------------------------------------------------------
  // 4. Parallel reads: flags + entitlement + active prompt
  // ---------------------------------------------------------------------
  // P3-G (2026-04-23): these three reads are independent of each
  // other (different tables, no ordering dependency) but prior code
  // serialized them, paying ~20-60ms of DB round-trip latency on the
  // happy path. Parallelizing via Promise.all runs all three against
  // the Supabase connection pool at once; even under heavy load
  // they complete in ~max(t_flags, t_ent, t_prompt) rather than sum.
  //
  // Gating order (kill switch → entitlement → quota → prompt) is
  // preserved below by reading from the resolved tuple in the same
  // sequence — just with the latency collapsed to one round-trip.
  //
  // Fail-open on flag read failure only (same posture as prior code:
  // flag outage shouldn't block a paid user from starting voice).
  // Entitlement / prompt failures remain hard errors since they
  // gate the mint's correctness (entitlement) or its ability to
  // build a system prompt (prompt row).
  const [flagsResult, entitlement, activePrompt] = await Promise.all([
    readFlags(client, userLog).catch((err) => {
      userLog.warn('flag_read_failed', { err: String(err) });
      return [] as Awaited<ReturnType<typeof readFlags>>;
    }),
    readEntitlement(client, claims.canonical_user_key),
    readActivePrompt(client, FEATURE_KEY),
  ]);

  const flags: Awaited<ReturnType<typeof readFlags>> = flagsResult;
  try {
    const disableRealtime = flags.find((f) => f.key === 'disable_cook_realtime');
    if (disableRealtime?.is_enabled && disableRealtime.value === true) {
      userLog.warn('kill_switch_active', { flag: 'disable_cook_realtime' });
      return jsonError(
        ErrorCode.AI_VOICE_01,
        503,
        {
          message: 'Voice mode is temporarily unavailable. Tap Cook Mode still works.',
        },
        requestId,
      );
    }
  } catch (err) {
    userLog.warn('flag_read_failed', { err: String(err) });
    // Fail open — flag read failure shouldn't block a paid user.
  }

  // ---------------------------------------------------------------------
  // 5. Entitlement: voice is Premium+ only
  // ---------------------------------------------------------------------
  // Already read in parallel above (P3-G); just gate on the result.
  if (!entitlement) {
    userLog.warn('entitlement_row_missing');
    return jsonError(
      ErrorCode.VAL_01,
      400,
      {
        message: 'No entitlement row. Call /v1/session/bootstrap to refresh.',
        field_errors: [{ field: 'session', issue: 'entitlement_snapshots missing row' }],
      },
      requestId,
    );
  }
  if (!effectiveVoiceEnabled(entitlement)) {
    userLog.info('voice_not_entitled', {
      tier: entitlement.tier,
      billing_state: entitlement.billing_state,
    });
    // SCA-284 Cluster D: include tier + billing_state to match the
    // ENT-VOICE-01 response shape from `cook-turn` and
    // `voice-turn-usage`. iOS uses these for paywall trigger
    // routing (annual-trial CTA shown to Free users).
    return jsonError(
      ErrorCode.ENT_VOICE_01,
      403,
      {
        message: 'Cook Mode voice is a Premium feature.',
        tier: entitlement.tier,
        billing_state: entitlement.billing_state,
      },
      requestId,
    );
  }

  // ---------------------------------------------------------------------
  // 6. Quota: atomic voice_cook_session increment (skipped on refresh)
  // ---------------------------------------------------------------------
  // Refresh mints are silent handoffs within an already-active cook
  // session (ADR 0014). The user's original session start consumed a
  // quota slot; the refresh is a cost-control mechanism on the SAME
  // session, so we skip the atomic increment here entirely.
  //
  // `didConsumeQuota` is the source of truth for downstream refund
  // decisions — any refund path (missing prompt, mint failure) must
  // gate on it so we never decrement a counter we never incremented
  // (review 2026-04-22 Critical #3). `consumedPeriodStart` is only
  // set on the non-refresh branch; passing it to refundQuota without
  // a real increment would corrupt `usage_counters.used_count` for
  // this user's current period.
  const didConsumeQuota = !body.is_refresh;
  let consumedPeriodStart: string | undefined;
  // Keep typed data from the quota read for logging (used/cap); -1
  // sentinels on refresh indicate "not applicable here" — log consumers
  // should filter those when aggregating.
  let quotaUsed = -1;
  let quotaCap = -1;

  if (body.is_refresh) {
    userLog.info('quota_skipped_refresh', { reason: 'session_refresh' });
  } else {
    const quotaResult = await incrementQuotaAtomic(
      client,
      claims.canonical_user_key,
      'voice_cook_session',
      new Date(userRow.created_at),
    );
    if (quotaResult.status === 'not_bootstrapped') {
      userLog.warn('quota_row_missing');
      return jsonError(
        ErrorCode.VAL_01,
        400,
        {
          message: 'No current-period quota row. Call /v1/session/bootstrap to refresh.',
          field_errors: [{ field: 'session', issue: 'usage_counters missing current period row' }],
        },
        requestId,
      );
    }
    if (quotaResult.status === 'capped') {
      userLog.warn('quota_capped', { used: quotaResult.used, cap: quotaResult.cap });
      return jsonError(
        ErrorCode.RATE_01,
        429,
        {
          message: "You've used all of this month's voice Cook Sessions for your plan.",
          scope: 'user:voice_cook_session_monthly',
          used: quotaResult.used,
          cap: quotaResult.cap,
        },
        requestId,
      );
    }
    consumedPeriodStart = quotaResult.period_start;
    quotaUsed = quotaResult.used;
    quotaCap = quotaResult.cap;
  }

  // ---------------------------------------------------------------------
  // 7. Prompt + render
  // ---------------------------------------------------------------------
  // Already read in parallel above (P3-G); just gate on the result.
  if (!activePrompt) {
    if (didConsumeQuota && consumedPeriodStart) {
      await refundQuota(
        client,
        userLog,
        claims.canonical_user_key,
        'voice_cook_session',
        consumedPeriodStart,
      );
      // SCA-145: refund-audit observability. The is_refresh=false
      // increment-then-refund path on the placeholder-key CI path is
      // observationally identical to never-incremented at the
      // usage_counters layer. PostHog emit disambiguates.
      await emitVoiceQuotaRefund(userLog, {
        canonicalUserKey: claims.canonical_user_key,
        requestId,
        reason: 'no_active_prompt',
      });
    }
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  // P1-A / SA1-W1 (2026-04-23): fence user-controlled fields in USER_DATA
  // markers. cook-turn (line 266-268) and substitution (line 498) already
  // pass `untrusted:` for their user-derived fields; realtime-session was
  // the one voice path where an attacker-influenced imported recipe
  // title or step text could land in the system prompt verbatim. Once
  // recipe-import (step 7) is live, a malicious recipe title like
  // `"Ignore all prior rules."` in a shared URL could nudge the Live
  // model — downstream damage is bounded (iOS tool-arg clamps, server-
  // side hard-rule validator on substitution), but the symmetry fix is
  // cheap and closes the obvious hole. Dietary_rules / equipment are
  // user-managed onboarding inputs; pantry_snapshot is user-confirmed
  // OCR output. All three merit fencing.
  const renderedPrompt = renderPrompt(
    activePrompt.template_blob,
    {
      recipe_title_json: body.recipe_context.title,
      recipe_servings_json: body.recipe_context.servings,
      recipe_estimated_minutes_json: body.recipe_context.estimated_minutes,
      current_step_number_json: body.current_step_number,
      total_steps_json: body.recipe_context.total_steps,
      current_step_text_json: body.recipe_context.current_step_text,
      current_step_timer_seconds_json: body.recipe_context.current_step_timer_seconds ?? 0,
      all_steps_json: body.recipe_context.all_steps,
      remaining_ingredients_json: body.recipe_context.remaining_ingredients,
      pantry_snapshot_json: body.household_context.pantry_snapshot,
      dietary_rules_json: body.household_context.dietary_rules,
      available_equipment_json: body.household_context.available_equipment,
    },
    {
      untrusted: new Set([
        'recipe_title_json',
        'current_step_text_json',
        'all_steps_json',
        'remaining_ingredients_json',
        'pantry_snapshot_json',
        'dietary_rules_json',
        'available_equipment_json',
      ]),
    },
  );

  // ---------------------------------------------------------------------
  // 8. Mint
  // ---------------------------------------------------------------------
  // Reflect feature flags in the mint config. `cook_voice_thinking_level`
  // escalates from MINIMAL → LOW if Gate 2 (preamble rate) drops and we
  // need more consistent spontaneous preambles. `voice_turn_detection_mode`
  // flips to `server_vad` if the tuned kitchen VAD profile misbehaves in
  // prod. Both safe defaults when the flag is absent.
  const thinkingFlag = flags.find((f) => f.key === 'cook_voice_thinking_level');
  const resolvedThinkingLevel: 'minimal' | 'low' =
    thinkingFlag?.is_enabled && (thinkingFlag.value === 'minimal' || thinkingFlag.value === 'low')
      ? thinkingFlag.value
      : 'minimal';
  const vadFlag = flags.find((f) => f.key === 'voice_turn_detection_mode');
  const resolvedTurnDetectionMode: 'semantic_vad' | 'server_vad' =
    vadFlag?.is_enabled && (vadFlag.value === 'semantic_vad' || vadFlag.value === 'server_vad')
      ? vadFlag.value
      : 'semantic_vad';

  let mint;
  try {
    // If the request carried a recap (session-refresh path per ADR 0014),
    // append it as a clearly-delimited suffix to systemInstruction so the
    // new session's very first turn has continuity context. Delimiter
    // markers ensure the model treats the recap as context, not part of
    // the core style/rules contract.
    const systemInstructionWithRecap = body.recap && body.recap.trim().length > 0
      ? `${renderedPrompt}\n\n# Recent conversation context (from prior session)\n${body.recap.trim()}`
      : renderedPrompt;

    mint = await mintLiveToken({
      systemInstruction: systemInstructionWithRecap,
      model: `models/${MODEL}`,
      thinkingLevel: resolvedThinkingLevel,
      turnDetectionMode: resolvedTurnDetectionMode,
    });
  } catch (err) {
    // Refund only if we actually consumed quota. Refresh mints
    // skip the increment entirely; refunding there would decrement
    // a counter we never touched and grant the user extra free
    // sessions (review 2026-04-22 Critical #3).
    if (didConsumeQuota && consumedPeriodStart) {
      await refundQuota(
        client,
        userLog,
        claims.canonical_user_key,
        'voice_cook_session',
        consumedPeriodStart,
      );
      // SCA-145: refund-audit observability. See no_active_prompt
      // refund site for rationale. `upstream_status` is included on
      // the LiveMintError branch so ops can correlate refunds with
      // Gemini outage windows.
      await emitVoiceQuotaRefund(userLog, {
        canonicalUserKey: claims.canonical_user_key,
        requestId,
        reason: err instanceof LiveMintError ? 'mint_failed' : 'mint_unexpected_error',
        // exactOptionalPropertyTypes rejects `upstreamStatus: undefined`
        // — only set the key when there's a real value.
        ...(err instanceof LiveMintError ? { upstreamStatus: err.statusCode } : {}),
      });
    }
    // `refund_applied` metadata mirrors the actual refund decision so
    // ops triage isn't misled on refresh-mint failures.
    if (err instanceof LiveMintError) {
      userLog.error('mint_failed', err, {
        upstream_status: err.statusCode,
        refund_applied: didConsumeQuota,
        is_refresh: body.is_refresh,
      });
      return jsonError(
        ErrorCode.AI_01,
        502,
        {
          message: 'Voice mode is unavailable right now. Try again in a moment.',
          upstream_status: err.statusCode,
        },
        requestId,
      );
    }
    userLog.error('mint_unexpected_error', err, {
      refund_applied: didConsumeQuota,
      is_refresh: body.is_refresh,
    });
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  // ---------------------------------------------------------------------
  // 9. Log + respond
  // ---------------------------------------------------------------------
  const sessionId = crypto.randomUUID();

  // P1-B / SA2-W4 (2026-04-23; revised post-review): persist the
  // (session_id → owner) binding so `/v1/ai/voice-turn-usage` can
  // reject turns posted under someone else's session_id AND turns
  // posted on a superseded session.
  //
  // Two-step sequence, inline (not fire-and-forget), because the
  // ordering matters and both steps must complete before the mint
  // response lands on iOS:
  //
  //   1. Supersede: mark any prior unclosed rows for THIS user as
  //      closed. Gemini Live has no server-side logout; this
  //      UPDATE is how we declare "the client's previous session_id
  //      is no longer accepting turns." The partial index
  //      `voice_session_owners_open_by_user_idx` makes the WHERE
  //      predicate O(log n) even at scale.
  //
  //   2. Insert the new row with closed_at=NULL. The authenticated
  //      client's next /v1/ai/voice-turn-usage POST will pass the
  //      ownership + lifecycle checks; any concurrent POST under an
  //      OLD session_id will now hit closed_at IS NOT NULL and 403
  //      with `reason: session_closed` — the smoke-test-targeted
  //      signal ops need to distinguish "forgot to mint" (missing)
  //      from "client holding stale session_id" (closed).
  //
  // Inline (not waitUntil) because a fire-and-forget order creates
  // a race: iOS can POST its first turn BEFORE the supersede
  // UPDATE lands, missing the old row's new closed_at timestamp.
  // The 10-30ms latency cost is negligible on the mint path.
  // Supersede + insert with one retry on unique_violation (SQLSTATE
  // 23505). The UNIQUE partial index
  // `voice_session_owners_one_open_per_user_uniq` enforces "at most
  // one open row per user" at the DB layer. Under a concurrent-mint
  // race, the losing INSERT returns 23505; we retry once — the
  // retry's UPDATE finds the winner's row open and closes it, then
  // the INSERT succeeds. A third concurrent mint on the same user
  // within the same instant is pathological; if it ever happens
  // we'll see repeated 23505s in logs and have a known case to
  // address.
  const inserted = await supersedeAndInsertWithRetry({
    client,
    sessionId,
    canonicalUserKey: claims.canonical_user_key,
    userLog,
  });
  if (!inserted) {
    userLog.warn('voice_session_owner_write_gave_up', {});
    // Non-fatal for the mint — voice-turn-usage will fail-close on
    // the missing binding, which disables THIS session's turn posts
    // but doesn't break the response path.
  }

  // Cost is zero at mint time — the minted session's real spend arrives via
  // usageMetadata frames during the Live WS turns. iOS forwards those per
  // turn to /v1/ai/voice-turn-usage, which emits one ai_request_log row +
  // one $ai_generation per turn (request_id="voice:<session_id>:<turn_index>").
  // The mint row here stays as a zero-cost anchor so the voice_cook_session
  // quota increment has a matching ai_request_log entry for cost attribution
  // dashboards — the session-level $ai_trace below is the PostHog equivalent.
  logAIRequest(client, userLog, {
    request_id: body.client_request_id,
    canonical_user_key: claims.canonical_user_key,
    feature_key: FEATURE_KEY,
    model: MODEL,
    input_tokens: 0,
    output_tokens: 0,
    cost_usd: 0,
    latency_ms: Math.round(performance.now() - started),
    thinking_level: 'minimal',
    prompt_version: activePrompt.version,
    retry_count: 0,
  });

  // PostHog $ai_trace is fired by iOS (CookModeViewModel) at session
  // close with BOTH $ai_input_state (mint context) and $ai_output_state
  // (session totals) in one event. Emitting a mint-time $ai_trace was
  // considered but dropped per ADR 0009 — PostHog is an append-only
  // event store, so same-trace_id emissions create sibling events
  // rather than overwriting. One emission at close keeps the trace
  // record consistent. Child $ai_generation events aggregate into the
  // trace view automatically via PostHog's pseudo-trace rollup.

  const wire: WireResponse = {
    auth_token: mint.tokenName,
    expires_at: mint.expiresAt,
    session_id: sessionId,
    ws_url: mint.wsUrl,
    prompt_version: activePrompt.version,
    setup_frame_json: mint.setupFrameJSON,
  };

  userLog.info('request_complete', {
    status: 200,
    latency_ms: Math.round(performance.now() - started),
    session_id: sessionId,
    voice_sessions_used: quotaUsed,
    voice_sessions_cap: quotaCap,
  });

  return jsonOk(wire, requestId);
});
