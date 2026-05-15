// POST /functions/v1/cook-turn
// Logical endpoint: POST /v1/ai/cook-turn (spec §3).
//
// Text fallback for Cook Mode voice. When Gemini Live is unavailable
// (disable_cook_realtime flag active, mint failed, mid-session WS drop,
// etc.), iOS runs SFSpeechRecognizer locally, POSTs the transcript here,
// and feeds the model's spoken_response to AVSpeechSynthesizer.
//
// Quota: voice_cook_session is consumed only at realtime-session mint
// time, not per fallback turn. cook-turn is "unmetered" in the
// usage_counters sense — a user on the Live path with a mint charge
// covered pays nothing extra for fallback turns in the same session.
//
// Cost control for the persistent-C.3 path (kill switch engaged, or
// chronic mint failures that route every turn to cook-turn): both an
// IP-scoped cap (ip:cook_turn_daily 300/day — DoS defense across users)
// AND a user-scoped cap (user:cook_turn_hourly 30/hour — worst-case
// cost per account). Without the user cap, the 300/day IP window
// permits ~$0.69/day/user against Premium's $1.89/mo AI budget — see
// review 2026-04-22 §Critical #2.
//
// Flow:
//   1. Auth: session JWT (AUTH-01 on failure)
//   2. Body: Zod parse (VAL-01 on failure)
//   3. Rate limits: IP daily + user hourly (RATE-01)
//   4. User row read: banned / merged / missing
//   5. Entitlement: effectiveVoiceEnabled() → 403 ENT-VOICE-01 if Free
//   6. Prompt: read active cook_turn v1.x
//   7. Render system prompt with recipe + household + transcript
//   8. Call gemini-3-flash-preview with responseSchema JSON output
//   9. Parse + validate response; log ai_request_log; return.

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readAppUser } from '../_shared/identity.ts';
import { effectiveVoiceEnabled, readEntitlement } from '../_shared/entitlements.ts';
import {
  readActivePrompt,
  renderPrompt,
  USER_DATA_END,
  USER_DATA_START,
} from '../_shared/prompt_versions.ts';
import { GeminiError, geminiGenerate, GeminiModel } from '../_shared/gemini.ts';
import { computeCostUSD } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { CookTurnRequest, zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
} from '../_shared/rate_limiter.ts';

const FEATURE_KEY = 'cook_turn';
const MODEL = GeminiModel.Flash;

// Response JSON schema Gemini adheres to. Shape matches the wire response
// we return to iOS.
const COOK_TURN_RESPONSE_SCHEMA: Record<string, unknown> = {
  type: 'OBJECT',
  properties: {
    spoken_response: { type: 'STRING' },
    suggested_action: {
      type: 'STRING',
      enum: ['advance_step', 'start_timer', 'none'],
    },
    action_params: {
      type: 'OBJECT',
      nullable: true,
      properties: {
        seconds: { type: 'INTEGER' },
        label: { type: 'STRING' },
      },
    },
  },
  required: ['spoken_response', 'suggested_action'],
};

// Runtime schema for re-validating Gemini's output after JSON.parse.
const CookTurnOutput = z.object({
  spoken_response: z.string().min(1).max(500),
  suggested_action: z.enum(['advance_step', 'start_timer', 'none']),
  action_params: z.object({
    seconds: z.number().int().min(1).max(36000).optional(),
    label: z.string().min(1).max(128).optional(),
  }).nullable().optional(),
});

type ParsedCookTurn = z.infer<typeof CookTurnOutput>;

interface WireResponse {
  spoken_response: string;
  suggested_action: 'advance_step' | 'start_timer' | 'none';
  action_params: { seconds?: number | undefined; label?: string | undefined } | null;
  prompt_version: string;
  latency_ms: number;
  retry_count: number;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/cook-turn';
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

  // 1. Auth
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

  // 2. Body validation
  let body: CookTurnRequest;
  try {
    const raw = await req.text();
    body = CookTurnRequest.parse(JSON.parse(raw));
  } catch (err) {
    if (err instanceof ZodError) {
      userLog.warn('validation_failed', { issue_count: err.issues.length });
      return jsonError(
        ErrorCode.VAL_01,
        400,
        { message: 'Request body failed validation.', field_errors: zodToFieldErrors(err) },
        requestId,
      );
    }
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

  // 3. Rate limits: IP (cross-user DoS defense) + user (cost cap).
  // The user cap is the real cost control — voice_cook_session is
  // NOT decremented for cook-turn (the fallback path is "unmetered"
  // per spec §9), so without the user-scoped hourly cap a persistent
  // C.3 user could burn through Premium budget at $0.69/day/user.
  // See review 2026-04-22 §Critical #2.
  const sourceIP = extractSourceIP(req);
  try {
    const rlIP = await checkAndIncrement(client, 'ip:cook_turn_daily', sourceIP);
    if (!rlIP.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:cook_turn_daily' });
      return buildRate01Response(
        'ip:cook_turn_daily',
        rlIP.retry_after_seconds,
        rlIP.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // SCA-396: fail-open is intentional — see ADR 0036.
    // Mid-cook voice fallback path; lock-out during an active Cook
    // Mode session is the worst possible UX.
  }
  try {
    const rlUser = await checkAndIncrement(
      client,
      'user:cook_turn_hourly',
      claims.canonical_user_key,
    );
    if (!rlUser.allowed) {
      userLog.warn('rate_limited', { scope: 'user:cook_turn_hourly' });
      return buildRate01Response(
        'user:cook_turn_hourly',
        rlUser.retry_after_seconds,
        rlUser.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // SCA-396: fail-open is intentional — see ADR 0036 (and IP gate above).
  }

  // 4. User row
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
    return jsonError(
      ErrorCode.BILL_01,
      403,
      { message: 'Account is not eligible for Stir.', state: 'banned' },
      requestId,
    );
  }
  if (userRow.merged_into) {
    return jsonError(
      ErrorCode.AUTH_01,
      401,
      { message: 'User identity was merged; re-bootstrap required.', reason: 'user_stale' },
      requestId,
    );
  }

  // 5. Entitlement — voice is Premium+ only (same gate as realtime-session)
  const entitlement = await readEntitlement(client, claims.canonical_user_key);
  if (!entitlement) {
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

  // 6. Prompt
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  // 7. Render — wrap the user-supplied transcript in USER_DATA markers as
  // defense-in-depth against prompt injection (matches substitution's
  // treatment of user_problem_text).
  const renderedPrompt = renderPrompt(activePrompt.template_blob, {
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
    transcript_json: body.transcript,
  }, {
    untrusted: new Set(['transcript_json']),
  });
  // renderPrompt already wraps the transcript in USER_DATA markers via
  // `untrusted`. Unused import warning for the raw markers is OK.
  void USER_DATA_START;
  void USER_DATA_END;

  // 8. Gemini call (retry-once on 5xx or schema failure)
  let parsed: ParsedCookTurn | null = null;
  let retryCount = 0;
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let totalLatency = 0;
  let lastErr: unknown;

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const result = await geminiGenerate({
        model: MODEL,
        systemInstruction: renderedPrompt,
        userText: 'Respond with JSON matching the schema exactly.',
        thinkingLevel: 'minimal',
        responseSchema: COOK_TURN_RESPONSE_SCHEMA,
        maxOutputTokens: 512,
        promptVersion: activePrompt.version,
      });
      totalInputTokens += result.inputTokens;
      totalOutputTokens += result.outputTokens;
      totalLatency += result.latencyMs;
      try {
        parsed = CookTurnOutput.parse(JSON.parse(result.text));
        break;
      } catch (schemaErr) {
        lastErr = schemaErr;
        retryCount++;
        userLog.warn('schema_validation_failed', {
          attempt: attempt + 1,
          finish_reason: result.finishReason,
        });
        if (attempt === 0) continue;
        break;
      }
    } catch (err) {
      lastErr = err;
      if (err instanceof GeminiError && err.status >= 500 && attempt === 0) {
        retryCount++;
        userLog.warn('gemini_upstream_error', { attempt: attempt + 1, status: err.status });
        continue;
      }
      userLog.error('gemini_call_failed', err);
      break;
    }
  }

  const costUsd = computeCostUSD(MODEL, {
    textInputTokens: totalInputTokens,
    textOutputTokens: totalOutputTokens,
  });

  if (!parsed) {
    userLog.error('cook_turn_failed_after_retry', lastErr, { retry_count: retryCount });
    recordAIRequest(
      client,
      userLog,
      {
        request_id: body.client_request_id,
        canonical_user_key: claims.canonical_user_key,
        feature_key: FEATURE_KEY,
        model: MODEL,
        input_tokens: totalInputTokens,
        output_tokens: totalOutputTokens,
        cost_usd: costUsd,
        latency_ms: totalLatency,
        thinking_level: 'minimal',
        prompt_version: activePrompt.version,
        retry_count: retryCount,
      },
      {
        trace_id: body.client_request_id,
        span_name: 'cook_turn',
        is_error: true,
        error_code: ErrorCode.AI_01,
        path: 'gemini_fallback',
      },
    );
    return jsonError(
      ErrorCode.AI_01,
      502,
      { message: 'Voice fallback is taking longer than expected.' },
      requestId,
    );
  }

  recordAIRequest(
    client,
    userLog,
    {
      request_id: body.client_request_id,
      canonical_user_key: claims.canonical_user_key,
      feature_key: FEATURE_KEY,
      model: MODEL,
      input_tokens: totalInputTokens,
      output_tokens: totalOutputTokens,
      cost_usd: costUsd,
      latency_ms: totalLatency,
      thinking_level: 'minimal',
      prompt_version: activePrompt.version,
      retry_count: retryCount,
    },
    {
      trace_id: body.client_request_id,
      span_name: 'cook_turn',
      path: 'gemini_fallback',
    },
  );

  const wire: WireResponse = {
    spoken_response: parsed.spoken_response,
    suggested_action: parsed.suggested_action,
    action_params: parsed.action_params ?? null,
    prompt_version: activePrompt.version,
    latency_ms: Math.round(performance.now() - started),
    retry_count: retryCount,
  };

  userLog.info('request_complete', {
    status: 200,
    latency_ms: wire.latency_ms,
    retry_count: retryCount,
    suggested_action: parsed.suggested_action,
    cost_usd: costUsd,
  });

  return jsonOk(wire, requestId);
});
