// POST /functions/v1/voice-turn-usage
// Logical endpoint: POST /v1/ai/voice-turn-usage (spec §3).
//
// Reports per-turn usageMetadata for Cook Mode voice sessions. iOS
// fire-and-forget POSTs after every Gemini Live `turnComplete`, batching
// allowed from v1 (turns: [...]). Backend:
//   1. Verifies session JWT (AUTH-01 on fail).
//   2. Parses VoiceTurnUsageRequest (VAL-01 on fail).
//   3. Guards banned/merged users.
//   4. For each turn: computes cost via MODEL_PRICING, inserts one
//      ai_request_log row (request_id="voice:<session_id>:<turn_index>",
//      ON CONFLICT DO NOTHING), captures one $ai_generation to PostHog.
//   5. Returns 204 No Content.
//
// Idempotency: ai_request_log's UNIQUE(request_id) + upsert ignoreDuplicates
// means iOS can safely replay the same (session_id, turn_index) without
// double-counting cost or duplicating PostHog events. Replay captures a
// second $ai_generation but PostHog dedupes at visualization time.
//
// Quota: no quota increment here. Voice session quota is consumed at mint
// time (realtime-session/index.ts). Per-turn is pure accounting.
//
// Why no quota refund on turn-usage failure: if this write fails, the
// voice turn still happened — cost did occur on Gemini's side, the user
// still got the Premium experience. The write failure is an observability
// gap, not a billing event.

import { ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError } from '../_shared/errors.ts';
import { readAppUser } from '../_shared/identity.ts';
import { computeCostUSD, MODEL_PRICING } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import { createLogger, requestIdFrom, sanitizeErrorForLog } from '../_shared/logger.ts';
import { GeminiModel } from '../_shared/gemini.ts';
import { VoiceTurnUsageRequest, zodToFieldErrors } from '../_shared/validation.ts';
import { effectiveVoiceEnabled, readEntitlement } from '../_shared/entitlements.ts';
import { checkAndIncrement, extractSourceIP, ipBucket } from '../_shared/rate_limiter.ts';

const VOICE_FEATURE_KEY = 'cook_mode_realtime';
const MODEL = GeminiModel.FlashLivePreview;

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/voice-turn-usage';
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
  let body: VoiceTurnUsageRequest;
  try {
    const raw = await req.text();
    body = VoiceTurnUsageRequest.parse(JSON.parse(raw));
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
  // 3. User row guard (banned / merged)
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
  // 4. Rate limits (IP + per-user hourly)
  // ---------------------------------------------------------------------
  // Matches cook-turn / dinner-solve pattern. A Premium user on a
  // ~15-turn session emits 15 POSTs; 500/hr cap allows ~33 sessions/hr
  // which is far above realistic Premium usage and blocks abuse
  // scenarios (forged iOS client trying to inflate ai_request_log +
  // PostHog ingest volume under their own canonical key).
  const sourceIP = extractSourceIP(req);
  try {
    const ipRl = await checkAndIncrement(client, 'ip:voice_turn_usage_daily', sourceIP);
    if (!ipRl.allowed) {
      userLog.warn('rate_limited', {
        scope: 'ip:voice_turn_usage_daily',
        source_ip_bucket: await ipBucket(sourceIP),
      });
      return jsonError(
        ErrorCode.RATE_01,
        429,
        {
          message: "You've used all of this window's available actions.",
          scope: 'ip:voice_turn_usage_daily',
          retry_after_seconds: ipRl.retry_after_seconds,
          reset_at: ipRl.reset_at,
        },
        requestId,
      );
    }
    const userRl = await checkAndIncrement(
      client,
      'user:voice_turn_usage_hourly',
      claims.canonical_user_key,
    );
    if (!userRl.allowed) {
      userLog.warn('rate_limited', { scope: 'user:voice_turn_usage_hourly' });
      return jsonError(
        ErrorCode.RATE_01,
        429,
        {
          message: "You've used all of this window's available actions.",
          scope: 'user:voice_turn_usage_hourly',
          retry_after_seconds: userRl.retry_after_seconds,
          reset_at: userRl.reset_at,
        },
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // SCA-396: fail-open is intentional — see ADR 0036.
    // Observability-only write path; failing closed loses telemetry for
    // a real voice session in flight without preventing any spend.
  }

  // ---------------------------------------------------------------------
  // 5. Entitlement: voice is Premium+ only
  // ---------------------------------------------------------------------
  // Even though the mint gated on entitlement already, a forged client
  // could POST directly to voice-turn-usage without minting. The check
  // is cheap (one DB read) and keeps dashboard data uniform with
  // realtime-session's own gate.
  const entitlement = await readEntitlement(client, claims.canonical_user_key);
  if (!entitlement || !effectiveVoiceEnabled(entitlement)) {
    userLog.info('voice_not_entitled', {
      tier: entitlement?.tier,
      billing_state: entitlement?.billing_state,
    });
    return jsonError(
      ErrorCode.ENT_VOICE_01,
      403,
      {
        message: 'Cook Mode voice is a Premium feature.',
        tier: entitlement?.tier,
        billing_state: entitlement?.billing_state,
      },
      requestId,
    );
  }

  // ---------------------------------------------------------------------
  // 5.5 Session ownership: this user must own the session_id they're
  //     posting turns under. P1-B / SA2-W4 (2026-04-23) closes a
  //     bounded IDOR class: a forged Premium client could previously
  //     POST turns under any UUID, polluting other users' $ai_trace
  //     rollups and billing their ai_request_log cost attribution to
  //     the wrong canonical_user_key.
  //
  //     `voice_session_owners` is populated by realtime-session at
  //     mint time. Retention is 2 h — more than the 35-min Gemini
  //     hard mint deadline — so a binding is always fresh enough for
  //     any in-flight session. Missing row → 403 (fail-closed).
  // ---------------------------------------------------------------------
  const { data: ownerRow, error: ownerErr } = await client
    .from('voice_session_owners')
    .select('canonical_user_key, closed_at')
    .eq('session_id', body.session_id)
    .maybeSingle();
  if (ownerErr) {
    userLog.error('voice_session_owner_lookup_failed', ownerErr);
    // Fail CLOSED on lookup error — the alternative (admit the post)
    // re-opens the IDOR class we're closing. Tiny blast radius:
    // observability rows for this turn are lost, not user-visible.
    // Use VOICE_SESSION_01 with `reason: lookup_failed` (not AI_01)
    // per SA2-W6 — AI_01 is "Gemini upstream temporarily unavailable"
    // and iOS maps it to user-facing retry copy. A DB outage here is
    // neither Gemini-related nor user-retryable.
    return jsonError(
      ErrorCode.VOICE_SESSION_01,
      500,
      { message: 'Could not verify session ownership.', reason: 'lookup_failed' },
      requestId,
    );
  }
  if (!ownerRow) {
    userLog.warn('voice_session_owner_missing', {
      session_id: body.session_id,
    });
    return jsonError(
      ErrorCode.VOICE_SESSION_01,
      403,
      {
        message: 'Session not found or expired. Start a new voice session.',
        reason: 'session_missing',
      },
      requestId,
    );
  }
  if (ownerRow.canonical_user_key !== claims.canonical_user_key) {
    // SA2-W5 (2026-04-24): the session may have been minted under an
    // install:<uuid> key that's since been alias-forwarded to the
    // ck:<record> the caller is now authenticated as. Do a single
    // merged_into lookup before rejecting — accept if the authenticated
    // user IS the legitimate post-merge owner of the session's original
    // key. Nested merges are a bug (one hop only).
    const { data: originalUser } = await client
      .from('app_users')
      .select('merged_into')
      .eq('canonical_user_key', ownerRow.canonical_user_key)
      .maybeSingle();
    const isAliasForwarded = originalUser?.merged_into === claims.canonical_user_key;
    if (!isAliasForwarded) {
      // Authenticated user is posting turns under someone else's session
      // id. Attempted IDOR (or a VM bug writing a stale session_id —
      // either way, reject). This is the signal ops dashboards should
      // alert on if it ever fires at non-zero rate.
      userLog.error(
        'voice_session_owner_mismatch',
        new Error('authenticated user does not own posted session_id'),
      );
      return jsonError(
        ErrorCode.VOICE_SESSION_01,
        403,
        {
          message: 'Session does not belong to this user.',
          reason: 'owner_mismatch',
        },
        requestId,
      );
    }
    // Log the alias-forward acceptance so ops can audit "how often
    // does mid-session identity migration happen" — should be rare.
    userLog.info('voice_session_owner_alias_forwarded', {
      session_id: body.session_id,
      original_key: ownerRow.canonical_user_key,
    });
  }
  if (ownerRow.closed_at !== null) {
    // P1-B lifecycle check: session was superseded by a newer mint.
    // ENT-VOICE-01 (not AI-VOICE-01 — that's AI-pipeline failure, not
    // a match for lifecycle) with a typed `reason` discriminator so
    // ops dashboards can split lifecycle failures from ownership
    // failures. See ADR 0017 for the full reason taxonomy.
    userLog.warn('voice_session_owner_closed', {
      session_id: body.session_id,
      closed_at: ownerRow.closed_at,
    });
    return jsonError(
      ErrorCode.VOICE_SESSION_01,
      403,
      {
        message: 'Voice session was superseded by a newer session.',
        reason: 'session_closed',
      },
      requestId,
    );
  }

  // ---------------------------------------------------------------------
  // 6. Per-turn: compute cost → recordAIRequest (upsert + PostHog)
  // ---------------------------------------------------------------------
  // v1 writes one row + one event per turn. Batched writes are a future
  // optimization — at current voice volumes (40 sessions/mo * 15 turns *
  // ~3 Premium users in beta) the per-turn round trip is cheap and the
  // per-row ergonomics simplify dashboards.
  //
  // recordAIRequest enforces the 1:1 reconciliation contract: on retry
  // with the same (session_id, turn_index), the ai_request_log upsert's
  // ON CONFLICT DO NOTHING fires AND the PostHog capture is suppressed.
  let processed = 0;
  const livePricing = MODEL_PRICING[MODEL];
  for (const turn of body.turns) {
    const rowRequestId = `voice:${body.session_id}:${turn.turn_index}`;

    // Row dashboards use Gemini's raw totals (`promptTokenCount` /
    // `responseTokenCount`). The text+audio breakdown may undersum the
    // total by the AUDIO-mode per-pass overhead — iOS forwards both.
    // Defensive clamp: if a misbehaving client sends `total < text+audio`,
    // fall back to the breakdown sum so downstream math never goes
    // negative.
    const breakdownPromptSum = turn.prompt_tokens_text + turn.prompt_tokens_audio;
    const breakdownResponseSum = turn.response_tokens_text + turn.response_tokens_audio;
    let inputTokens = turn.prompt_tokens_total;
    let outputTokens = turn.response_tokens_total;
    if (inputTokens < breakdownPromptSum || outputTokens < breakdownResponseSum) {
      userLog.warn('voice_turn_totals_below_breakdown', {
        session_id: body.session_id,
        turn_index: turn.turn_index,
        prompt_total: turn.prompt_tokens_total,
        prompt_breakdown_sum: breakdownPromptSum,
        response_total: turn.response_tokens_total,
        response_breakdown_sum: breakdownResponseSum,
      });
      inputTokens = Math.max(inputTokens, breakdownPromptSum);
      outputTokens = Math.max(outputTokens, breakdownResponseSum);
    }

    // ADR 0015 invariant-break signal: implicit caching is expected to
    // stay at zero on Gemini Live (measurement-locked). Any non-zero
    // `prompt_tokens_cached` on Live is a trigger to manually re-check
    // Google's Live-API pricing BEFORE the cost math feeds into a
    // cap-reversal decision — the 25% discount rate we assume for
    // FlashLivePreview in MODEL_PRICING is a best-guess defensive value,
    // not a published Google rate. Warn-level so the Supabase log
    // aggregator surfaces it to ops without spamming alerts.
    if (turn.prompt_tokens_cached !== undefined && turn.prompt_tokens_cached > 0) {
      userLog.warn('voice_live_caching_unexpected_nonzero', {
        session_id: body.session_id,
        turn_index: turn.turn_index,
        prompt_tokens_cached: turn.prompt_tokens_cached,
        prompt_tokens_text: turn.prompt_tokens_text,
        note:
          'ADR 0015 assumed cached=0 on Live; re-verify Google pricing page before trusting cost math',
      });
    }

    // Breakdown sanity: `prompt_tokens_cached` MUST be ≤ `prompt_tokens_text`
    // (cached tokens are a subset of text input — Google's cache stores
    // text-only content; audio doesn't participate in implicit caching).
    // If this ever fires, `computeCostUSD` silently clamps, but we need
    // the log so the upstream breakdown bug is visible instead of
    // swallowed by the clamp.
    if (
      turn.prompt_tokens_cached !== undefined &&
      turn.prompt_tokens_cached > turn.prompt_tokens_text
    ) {
      userLog.warn('voice_cached_tokens_exceed_text', {
        session_id: body.session_id,
        turn_index: turn.turn_index,
        prompt_tokens_cached: turn.prompt_tokens_cached,
        prompt_tokens_text: turn.prompt_tokens_text,
      });
    }

    // Cost = categorized breakdown via MODEL_PRICING + the uncategorized
    // remainder priced at audio in/out rate (CLAUDE.md sharp-edge #15 —
    // the AUDIO-mode per-pass overhead is charged as audio input).
    //
    // `cachedInputTokens` discounts the cached portion of text input
    // at 25% of the standard rate. ADR 0015 measurement keeps this at
    // 0 for every observed Live turn (caching doesn't fire on Live),
    // but passing the value through means if Google ever enables Live
    // caching the cost math reflects it without a code change. The
    // Zod wire validator enforces `prompt_tokens_cached ≤ prompt_tokens_total`
    // upstream; `computeCostUSD` also defensively clamps `cachedInputTokens
    // ≤ textInputTokens` in case the breakdown attributes cached tokens
    // to the audio column instead of text.
    const baseCost = computeCostUSD(MODEL, {
      textInputTokens: turn.prompt_tokens_text,
      cachedInputTokens: turn.prompt_tokens_cached,
      audioInputTokens: turn.prompt_tokens_audio,
      textOutputTokens: turn.response_tokens_text,
      audioOutputTokens: turn.response_tokens_audio,
    });
    const promptRemainder = Math.max(0, inputTokens - breakdownPromptSum);
    const responseRemainder = Math.max(0, outputTokens - breakdownResponseSum);
    const remainderCost = (promptRemainder * livePricing.audioInPer1M) / 1_000_000 +
      (responseRemainder * livePricing.audioOutPer1M) / 1_000_000;
    // Round to 6 decimal places to match ai_request_log.cost_usd NUMERIC(10,6).
    const costUsd = Math.round((baseCost + remainderCost) * 1_000_000) / 1_000_000;

    recordAIRequest(
      client,
      userLog,
      {
        request_id: rowRequestId,
        canonical_user_key: claims.canonical_user_key,
        feature_key: VOICE_FEATURE_KEY,
        model: MODEL,
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cost_usd: costUsd,
        latency_ms: turn.latency_ms,
        thinking_level: 'minimal',
        prompt_version: turn.prompt_version,
        retry_count: 0,
        // Forward implicit-cache hit count straight from iOS. Zero/absent
        // means either (a) Gemini Live caching didn't fire on this turn
        // (the hypothesis we're trying to disprove) or (b) caching fired
        // but the iOS accumulator was zero (shouldn't happen — iOS omits
        // the field in that case). prompt_tokens_cached is optional in
        // the Zod schema, so turn.prompt_tokens_cached may be undefined.
        prompt_cached_tokens: turn.prompt_tokens_cached,
        // session_id populated from body.session_id (already validated as
        // UUID upstream). Indexed via idx_ai_request_log_voice_session for
        // ops aggregations; replaces split_part parsing at the query
        // layer. Migration 20260424000003 adds the column + index.
        session_id: body.session_id,
      },
      {
        trace_id: body.session_id,
        span_name: 'voice_cook_turn',
        is_error: turn.ended_reason === 'error',
        path: turn.path,
      },
    );

    processed++;
  }

  userLog.info('request_complete', {
    status: 204,
    latency_ms: Math.round(performance.now() - started),
    session_id: body.session_id,
    turns_processed: processed,
  });

  // 204 No Content — empty body by convention.
  return new Response(null, {
    status: 204,
    headers: { 'x-request-id': requestId },
  });
});
