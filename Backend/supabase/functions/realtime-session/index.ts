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
import {
  effectiveVoiceEnabled,
  readEntitlement,
} from '../_shared/entitlements.ts';
import { incrementQuotaAtomic, refundQuota } from '../_shared/quota.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiModel } from '../_shared/gemini.ts';
import { LiveMintError, mintLiveToken } from '../_shared/live_mint.ts';
import { logAIRequest } from '../_shared/ai_request_log.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { RealtimeSessionRequest, zodToFieldErrors } from '../_shared/validation.ts';

const FEATURE_KEY = 'cook_mode_realtime';
const MODEL = GeminiModel.FlashLivePreview;

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
    userLog.warn('json_parse_failed', { err: String(err) });
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
  // 4. Kill switch
  // ---------------------------------------------------------------------
  try {
    const flags = await readFlags(client, userLog);
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
  const entitlement = await readEntitlement(client, claims.canonical_user_key);
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
  // 6. Quota: atomic voice_cook_session increment
  // ---------------------------------------------------------------------
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

  const consumedPeriodStart = quotaResult.period_start;

  // ---------------------------------------------------------------------
  // 7. Prompt + render
  // ---------------------------------------------------------------------
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    await refundQuota(
      client, userLog, claims.canonical_user_key, 'voice_cook_session', consumedPeriodStart,
    );
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  const renderedPrompt = renderPrompt(activePrompt.template_blob, {
    recipe_title_json: body.recipe_context.title,
    recipe_servings_json: body.recipe_context.servings,
    recipe_estimated_minutes_json: body.recipe_context.estimated_minutes,
    current_step_number_json: body.current_step_number,
    total_steps_json: body.recipe_context.total_steps,
    current_step_text_json: body.recipe_context.current_step_text,
    current_step_timer_seconds_json:
      body.recipe_context.current_step_timer_seconds ?? 0,
    remaining_ingredients_json: body.recipe_context.remaining_ingredients,
    pantry_snapshot_json: body.household_context.pantry_snapshot,
    dietary_rules_json: body.household_context.dietary_rules,
    available_equipment_json: body.household_context.available_equipment,
  });

  // ---------------------------------------------------------------------
  // 8. Mint
  // ---------------------------------------------------------------------
  let mint;
  try {
    mint = await mintLiveToken({
      systemInstruction: renderedPrompt,
      model: `models/${MODEL}`,
      thinkingLevel: 'minimal',
    });
  } catch (err) {
    await refundQuota(
      client, userLog, claims.canonical_user_key, 'voice_cook_session', consumedPeriodStart,
    );
    if (err instanceof LiveMintError) {
      userLog.error('mint_failed', err, { upstream_status: err.statusCode });
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
    userLog.error('mint_unexpected_error', err);
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  // ---------------------------------------------------------------------
  // 9. Log + respond
  // ---------------------------------------------------------------------
  const sessionId = crypto.randomUUID();

  // Cost is zero at mint time — the minted session's real spend arrives via
  // usageMetadata frames during the Live WS turns (not plumbed to backend
  // in v1). Log the mint as a zero-cost event row so the voice_cook_session
  // counter increment has a matching ai_request_log anchor for cost attribution
  // dashboards. Future work: pipe iOS-forwarded usageMetadata deltas in.
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
    voice_sessions_used: quotaResult.used,
    voice_sessions_cap: quotaResult.cap,
  });

  return jsonOk(wire, requestId);
});
