// POST /functions/v1/substitution
// Logical endpoint: POST /v1/ai/substitution (spec §3, spec §12.2).
//
// Mid-cook rescue. Called from the Substitution Sheet on all tiers; step 6
// adds a second invocation path via Gemini Live function-call that hits
// this same endpoint — the wire shape is deliberately stable.
//
// Flow (happy path):
//   1. Auth: session JWT (AUTH-01 on failure)
//   2. Body: Zod parse (VAL-01 on failure)
//   3. Idempotency: ai_response_cache replay if sub_event_id known (10 min)
//   4. Rate limit: ip:substitution_daily (RATE-01)
//   5. Prompt: read active v1.0.0 for substitution
//   6. Call Gemini 3 Flash with JSON schema + thinkingLevel=minimal
//   7. Hard-rule validate. On violation: retry ONCE with amplified prompt.
//      On second violation: return canned-safe body (constraint_safe=false +
//      safety message) with HTTP 200 — the UI shows a red warning card, so
//      this is a legitimate product response, not an error.
//   8. Log ai_request_log; cache response; return.
//
// Substitution is UNMETERED across tiers per CLAUDE.md §usage_counters —
// cost is tracked in ai_request_log but no per-user quota row is touched.
// IP rate limit stops abuse.
//
// CLAUDE.md §Invariants: "Hard-rule validator runs on every substitution
// output, regardless of invocation path." This handler is the canonical
// entry point; step 6's Live function-call handler wraps the same core
// without mutating the contract.

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiError, geminiGenerate, GeminiModel } from '../_shared/gemini.ts';
import { computeCostUSD } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import { createLogger, requestIdFrom, sanitizeErrorForLog } from '../_shared/logger.ts';
import { SubstitutionRequest, zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
} from '../_shared/rate_limiter.ts';
import { readCache, responseFromCache, writeCache } from '../_shared/idempotency.ts';
import {
  type DietaryRule,
  summarizeViolations,
  validateSubstitution,
} from '../_shared/hard_rules.ts';
import { equipmentDisplayNames } from '../_shared/equipment_display.ts';

const FEATURE_KEY = 'substitution';
const MODEL = GeminiModel.Flash;

// Canned safety message returned when no safe substitution can be produced
// after one retry. Matches the prompt's fallback text so the model and the
// server converge on the same copy when they agree. iOS maps this body to
// the "red warning card, no Accept button" UI state.
const CANNED_UNSAFE_MESSAGE =
  "That substitution can't be made safely — skip this ingredient or pause to pick another recipe.";

// Response JSON schema Gemini is asked to adhere to.
const GEMINI_RESPONSE_SCHEMA: Record<string, unknown> = {
  type: 'OBJECT',
  properties: {
    substitution_text: { type: 'STRING' },
    amount_conversion: { type: 'STRING', nullable: true },
    constraint_safe: { type: 'BOOLEAN' },
    constraint_violation_reason: { type: 'STRING', nullable: true },
    reasoning: { type: 'STRING' },
    confidence: { type: 'STRING', enum: ['high', 'medium', 'low'] },
  },
  required: ['substitution_text', 'constraint_safe', 'reasoning', 'confidence'],
};

// Zod schema for what we expect back from Gemini AFTER JSON.parse.
const SubstitutionOutput = z.object({
  substitution_text: z.string().min(1).max(400),
  amount_conversion: z.string().max(400).nullable().optional(),
  constraint_safe: z.boolean(),
  constraint_violation_reason: z.string().max(400).nullable().optional(),
  reasoning: z.string().min(1).max(400),
  confidence: z.enum(['high', 'medium', 'low']),
});

type ParsedSubstitution = z.infer<typeof SubstitutionOutput>;

interface WireResponse {
  sub_event_id: string;
  substitution_text: string;
  amount_conversion: string | null;
  constraint_safe: boolean;
  constraint_violation_reason: string | null;
  reasoning: string;
  confidence: 'high' | 'medium' | 'low';
  prompt_version: string;
  latency_ms: number;
  retry_count: number;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/substitution';
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
  let body;
  try {
    const raw = await req.text();
    body = SubstitutionRequest.parse(JSON.parse(raw));
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
  // 3. Idempotency cache
  // ---------------------------------------------------------------------
  try {
    const hit = await readCache(client, claims.canonical_user_key, body.sub_event_id);
    if (hit) {
      userLog.info('cache_replay', { age_seconds: hit.age_seconds });
      return responseFromCache(hit, requestId);
    }
  } catch (err) {
    userLog.warn('cache_read_failed', { err: sanitizeErrorForLog(err) });
  }

  // ---------------------------------------------------------------------
  // 4. IP rate limit
  // ---------------------------------------------------------------------
  const sourceIP = extractSourceIP(req);
  try {
    const rl = await checkAndIncrement(client, 'ip:substitution_daily', sourceIP);
    if (!rl.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:substitution_daily' });
      return buildRate01Response(
        'ip:substitution_daily',
        rl.retry_after_seconds,
        rl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // Fail open — limiter glitch shouldn't block mid-cook rescue.
  }

  // ---------------------------------------------------------------------
  // 5. Prompt
  // ---------------------------------------------------------------------
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  // ---------------------------------------------------------------------
  // 6. Gemini call + hard-rule retry loop
  // ---------------------------------------------------------------------
  //
  // We run up to 2 attempts:
  //   attempt 1: vanilla prompt
  //   attempt 2: prompt amplified with the specific violation from attempt 1
  //
  // If attempt 2 still violates, we return the canned-safe body regardless
  // of what the model said (safety-first). The endpoint returns HTTP 200
  // because the body IS a valid product response — a red warning card with
  // no Accept button is the intended UX.
  //
  // A separate retry-once path covers transient JSON-schema failures (the
  // model returned malformed JSON). Schema failures after retry surface as
  // AI-02 — model drift that ops should investigate.
  let retryCount = 0;
  // CA1-L4 / I8 split: distinguish "model returned malformed JSON" from
  // "Gemini upstream 5xx" so PostHog dashboards can separate model-drift
  // cost from upstream-blip cost. `totalRetries` (the wire field) stays
  // the sum so existing consumers see the same number.
  let schemaRetryCount = 0;
  let upstreamRetryCount = 0;
  let parsed: ParsedSubstitution | null = null;
  let lastErr: unknown;
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let totalLatency = 0;
  let finalValidationValid = false;
  let amplifyNote: string | null = null;

  for (let attempt = 0; attempt < 2; attempt++) {
    const renderedPrompt = renderPromptForAttempt(activePrompt.template_blob, body, amplifyNote);
    try {
      const result = await geminiGenerate({
        model: MODEL,
        systemInstruction: renderedPrompt,
        userText:
          'Propose one substitution. Respond with JSON matching the schema exactly. If no safe substitution exists, set constraint_safe=false and return the canned safety message.',
        thinkingLevel: 'minimal',
        responseSchema: GEMINI_RESPONSE_SCHEMA,
        maxOutputTokens: 1024,
        promptVersion: activePrompt.version,
      });
      totalInputTokens += result.inputTokens;
      totalOutputTokens += result.outputTokens;
      totalLatency += result.latencyMs;

      let candidate: ParsedSubstitution;
      try {
        const json = JSON.parse(result.text);
        candidate = SubstitutionOutput.parse(json);
      } catch (schemaErr) {
        lastErr = schemaErr;
        schemaRetryCount++;
        userLog.warn('schema_validation_failed', {
          attempt: attempt + 1,
          finish_reason: result.finishReason,
        });
        // Only one schema-retry budget — if attempt 0 failed schema, we've
        // used our retry. Break out so we hit the AI-02 path below. Don't
        // double-count a schema failure as a hard-rule retry.
        if (attempt === 0) {
          // Advance to attempt 1 (the for-loop bumps `attempt`), drop the
          // amplification note — schema failures are malformed JSON, not
          // hard-rule violations, so the retry shouldn't carry a violation
          // summary into the next prompt.
          amplifyNote = null;
          continue;
        }
        break;
      }

      // Hard-rule validation. Coerce amount_conversion through `?? null`
      // because Zod's .optional() yields `string | null | undefined` but
      // the validator's Candidate type narrows to `string | null` under
      // exactOptionalPropertyTypes.
      const validation = validateSubstitution(
        {
          substitution_text: candidate.substitution_text,
          reasoning: candidate.reasoning,
          amount_conversion: candidate.amount_conversion ?? null,
          constraint_safe: candidate.constraint_safe,
        },
        {
          dietaryRules: body.household_context.dietary_rules as DietaryRule[],
          availableEquipment: body.household_context.available_equipment,
        },
      );

      if (validation.valid) {
        parsed = candidate;
        finalValidationValid = true;
        break;
      }

      // Invalid — log PII-free issue kinds and build amplified prompt for retry
      const kinds = validation.issues.map((i) => i.kind);
      userLog.warn('hard_rule_violation', {
        attempt: attempt + 1,
        issue_kinds: kinds,
        issue_count: validation.issues.length,
      });

      if (attempt === 0) {
        retryCount++;
        amplifyNote = summarizeViolations(validation);
        // Remember the candidate so if retry also fails we have something
        // to log (we still prefer canned-safe over the un-safe suggestion).
        parsed = candidate;
        continue;
      }

      // Attempt 2 still violates — keep parsed=candidate for telemetry but
      // we WILL override it with canned-safe below.
      parsed = candidate;
      finalValidationValid = false;
      break;
    } catch (err) {
      lastErr = err;
      if (err instanceof GeminiError && err.status >= 500 && attempt === 0) {
        upstreamRetryCount++;
        userLog.warn('gemini_upstream_error', { attempt: attempt + 1, status: err.status });
        amplifyNote = null;
        continue;
      }
      userLog.error('gemini_call_failed', err);
      break;
    }
  }

  // ---------------------------------------------------------------------
  // 7. Build wire response
  // ---------------------------------------------------------------------
  const costUsd = computeCostUSD(MODEL, {
    textInputTokens: totalInputTokens,
    textOutputTokens: totalOutputTokens,
  });
  const totalRetries = retryCount + schemaRetryCount + upstreamRetryCount;

  if (!parsed) {
    // No candidate at all — both attempts failed schema validation or
    // Gemini returned an unrecoverable error. Surface AI-02.
    userLog.error('substitution_failed_after_retry', lastErr, {
      retry_count: totalRetries,
    });
    recordAIRequest(
      client,
      userLog,
      {
        request_id: body.sub_event_id,
        canonical_user_key: claims.canonical_user_key,
        feature_key: FEATURE_KEY,
        model: MODEL,
        input_tokens: totalInputTokens,
        output_tokens: totalOutputTokens,
        cost_usd: costUsd,
        latency_ms: totalLatency,
        thinking_level: 'minimal',
        prompt_version: activePrompt.version,
        retry_count: totalRetries,
      },
      {
        trace_id: body.sub_event_id,
        span_name: 'substitution',
        is_error: true,
        error_code: ErrorCode.AI_02,
      },
    );
    return jsonError(
      ErrorCode.AI_02,
      502,
      {
        message: 'Substitution is taking longer than expected. Try again or skip this ingredient.',
      },
      requestId,
    );
  }

  // Override with canned-safe body if final validation failed. The model
  // MAY have said constraint_safe=true while our validator disagreed —
  // safety-first: validator wins.
  const wire: WireResponse = finalValidationValid
    ? {
      sub_event_id: body.sub_event_id,
      substitution_text: parsed.substitution_text,
      amount_conversion: parsed.amount_conversion ?? null,
      constraint_safe: true,
      constraint_violation_reason: null,
      reasoning: parsed.reasoning,
      confidence: parsed.confidence,
      prompt_version: activePrompt.version,
      latency_ms: Math.round(performance.now() - started),
      retry_count: totalRetries,
    }
    : {
      sub_event_id: body.sub_event_id,
      substitution_text: CANNED_UNSAFE_MESSAGE,
      amount_conversion: null,
      constraint_safe: false,
      // Intentionally generic — avoids leaking rule specifics back to the
      // client and keeps the iOS UX copy stable.
      constraint_violation_reason: parsed.constraint_violation_reason ??
        'Violates a hard dietary or equipment constraint.',
      reasoning: "No substitution passed the household's hard rules.",
      confidence: 'low',
      prompt_version: activePrompt.version,
      latency_ms: Math.round(performance.now() - started),
      retry_count: totalRetries,
    };

  // Log cost + best-effort cache write.
  recordAIRequest(
    client,
    userLog,
    {
      request_id: body.sub_event_id,
      canonical_user_key: claims.canonical_user_key,
      feature_key: FEATURE_KEY,
      model: MODEL,
      input_tokens: totalInputTokens,
      output_tokens: totalOutputTokens,
      cost_usd: costUsd,
      latency_ms: totalLatency,
      thinking_level: 'minimal',
      prompt_version: activePrompt.version,
      retry_count: totalRetries,
    },
    {
      trace_id: body.sub_event_id,
      span_name: 'substitution',
    },
  );

  try {
    await writeCache(client, claims.canonical_user_key, body.sub_event_id, FEATURE_KEY, 200, wire);
  } catch (err) {
    userLog.warn('cache_write_failed', { err: sanitizeErrorForLog(err) });
  }

  userLog.info('request_complete', {
    status: 200,
    latency_ms: wire.latency_ms,
    retry_count: totalRetries,
    constraint_safe: wire.constraint_safe,
    cost_usd: costUsd,
    // Step 6: log invocation path for cost-attribution dashboards.
    // Present when the request came from the Live API function-call
    // round-trip (sharp-edges #9/#12 path); absent for Substitution Sheet.
    invocation: body.live_session_id ? 'realtime_function_call' : 'sheet',
    ...(body.live_session_id ? { live_session_id: body.live_session_id } : {}),
  });

  return jsonOk(wire, requestId);
});

// ---------------------------------------------------------------------------
// Prompt rendering
// ---------------------------------------------------------------------------
//
// Re-renders the base substitution prompt for each attempt. On the second
// attempt, an "amplifyNote" is prepended warning the model of the specific
// violation kind from the first attempt (e.g., "allergens=peanut"). The
// note is stripped down — we never leak user identifiers or raw user text
// back into the model context beyond what was already in the base render.

function renderPromptForAttempt(
  template: string,
  body: SubstitutionRequest,
  amplifyNote: string | null,
): string {
  // SA1-01 defense-in-depth: wrap user-controlled free text in
  // USER_DATA markers so the model can be instructed (via the prompt
  // template) to treat content between them as literal data rather
  // than instructions. The hard-rule validator remains the primary
  // defense on output; this lowers the probability of the model being
  // steered into unsafe suggestions in the first place.
  //   - user_problem_text: raw free text from the user
  //   - missing_ingredient_json: display_name is user-controlled
  //     (free-text "something else…" path)
  // Other keys (dietary_rules_json, available_equipment_json,
  // pantry_snapshot_json, recipe_context_json) come from server-
  // validated CloudKit entities or prior AI output; not user-controlled
  // in a way that would enable syntactic injection beyond JSON.stringify.
  const base = renderPrompt(template, {
    dietary_rules_json: body.household_context.dietary_rules,
    // SCA-423: render display names; validator above stays on slugs.
    available_equipment_json: equipmentDisplayNames(
      body.household_context.available_equipment,
    ),
    pantry_snapshot_json: body.household_context.pantry_snapshot,
    recipe_context_json: body.recipe_context,
    missing_ingredient_json: body.missing_ingredient,
    user_problem_text: body.user_problem,
  }, {
    untrusted: new Set(['user_problem_text', 'missing_ingredient_json']),
  });
  if (!amplifyNote) return base;
  return [
    'PREVIOUS ATTEMPT VIOLATED HARD RULES:',
    amplifyNote,
    'This retry MUST NOT repeat that violation. If no safe substitution exists, return the canned safety message with constraint_safe=false.',
    '',
    base,
  ].join('\n');
}
