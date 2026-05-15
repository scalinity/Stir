// POST /functions/v1/recipe-step-rewrite
// Logical endpoint: POST /v1/ai/recipe-step-rewrite (SCA-432).
//
// Called from SubstitutionSheetViewModel.accept() right after the user
// taps Accept on a safe swap. Returns a rewritten version of the current
// step's instructionText so the prose references the substitute instead
// of the original ingredient.
//
// Pattern mirrors substitution/index.ts — same auth/idempotency/rate-limit/
// prompt-version/Gemini scaffolding — but skips the hard-rule retry loop:
// the safety call already ran in /v1/ai/substitution. This endpoint is a
// prose rewrite, not a constraint solver. One Gemini call, one schema
// retry if the model returns malformed JSON, then surface AI-02 if the
// model still drifts.
//
// Cost-attribution: feature_key='recipe_step_rewrite' so PostHog dashboards
// can slice per-substitution-accept cost separately from the substitution
// call itself.

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiError, geminiGenerate, GeminiModel } from '../_shared/gemini.ts';
import { computeCostUSD } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import { createLogger, requestIdFrom, sanitizeErrorForLog } from '../_shared/logger.ts';
import { RecipeStepRewriteRequest, zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
} from '../_shared/rate_limiter.ts';
import { readCache, responseFromCache, writeCache } from '../_shared/idempotency.ts';

const FEATURE_KEY = 'recipe_step_rewrite';
const MODEL = GeminiModel.Flash;

// Cache-key namespace. `ai_response_cache`'s PK is
// (canonical_user_key, request_id) — feature_key is NOT in the key
// (Backend/supabase/migrations/20260418000024_ai_response_cache_user_scope.sql).
// The accept flow calls /v1/ai/substitution and then /v1/ai/recipe-step-
// rewrite with the SAME sub_event_id; without a namespace the rewrite
// readCache would hit substitution's body and iOS would fail to decode
// the {substitution_text, constraint_safe, ...} payload as a
// {rewritten_text, ...} response. The suffix is server-side only — the
// wire body keeps `sub_event_id` so ai_request_log.request_id still
// joins to the upstream substitution call for cost-attribution.
const REWRITE_CACHE_SUFFIX = ':rewrite';
// Sentinel string passed to the prompt template when an optional field
// is absent. Empty-string fallbacks rendered as bare `<<<USER_DATA_START>>>
// <<<USER_DATA_END>>>` fences which wasted tokens and read ambiguously.
const PROMPT_OPTIONAL_ABSENT = '(not provided)';

// Response JSON schema Gemini is asked to adhere to. One field: the
// rewritten step prose. No metadata fields — the model returns the literal
// replacement string and that's it.
const GEMINI_RESPONSE_SCHEMA: Record<string, unknown> = {
  type: 'OBJECT',
  properties: {
    rewritten_text: { type: 'STRING' },
  },
  required: ['rewritten_text'],
};

// Zod schema for what we expect back from Gemini AFTER JSON.parse. The
// max bound (2000) matches RecipeStep.instructionText's wire limit.
const RewriteOutput = z.object({
  rewritten_text: z.string().min(1).max(2000),
});

type ParsedRewrite = z.infer<typeof RewriteOutput>;

interface WireResponse {
  sub_event_id: string;
  rewritten_text: string;
  prompt_version: string;
  latency_ms: number;
  retry_count: number;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/recipe-step-rewrite';
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
    body = RecipeStepRewriteRequest.parse(JSON.parse(raw));
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
  // 3. Idempotency cache. Keyed on `<sub_event_id>:rewrite` so a fast
  //    double-tap on Accept collapses to one Gemini call while NOT
  //    colliding with substitution's cache entry under the same
  //    sub_event_id (see REWRITE_CACHE_SUFFIX comment).
  // ---------------------------------------------------------------------
  const cacheKey = body.sub_event_id + REWRITE_CACHE_SUFFIX;
  try {
    const hit = await readCache(client, claims.canonical_user_key, cacheKey);
    if (hit) {
      userLog.info('cache_replay', { age_seconds: hit.age_seconds });
      return responseFromCache(hit, requestId);
    }
  } catch (err) {
    userLog.warn('cache_read_failed', { err: sanitizeErrorForLog(err) });
  }

  // ---------------------------------------------------------------------
  // 4. IP rate limit. Distinct scope from substitution so a user can
  //    accept many substitutions without bumping the substitution daily
  //    limit (which is meant for the upstream rescue calls).
  // ---------------------------------------------------------------------
  const sourceIP = extractSourceIP(req);
  try {
    const rl = await checkAndIncrement(client, 'ip:recipe_step_rewrite_daily', sourceIP);
    if (!rl.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:recipe_step_rewrite_daily' });
      return buildRate01Response(
        'ip:recipe_step_rewrite_daily',
        rl.retry_after_seconds,
        rl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // Fail open — limiter glitch shouldn't block mid-cook rewrite.
  }

  // ---------------------------------------------------------------------
  // 5. Prompt
  // ---------------------------------------------------------------------
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  const renderedPrompt = renderPrompt(
    activePrompt.template_blob,
    {
      step_instruction_text: body.step_instruction_text,
      original_ingredient: body.original_ingredient,
      substitute_ingredient: body.substitute_ingredient,
      // Sentinel rather than empty-string so the rendered prompt reads
      // `Amount conversion (may be empty): (not provided)` instead of
      // `Amount conversion (may be empty): <<<USER_DATA_START>>><<<USER_DATA_END>>>`.
      amount_conversion: body.amount_conversion ?? PROMPT_OPTIONAL_ABSENT,
      recipe_title: body.recipe_title ?? PROMPT_OPTIONAL_ABSENT,
    },
    {
      // step_instruction_text is recipe prose generated by Gemini at
      // dinner-solve time — not directly user-typed — but a malicious
      // local edit (or a future iOS surface that lets users hand-edit
      // steps) could inject prompt instructions. Fence it the same way
      // substitution fences `user_problem`. original/substitute
      // ingredient names ALSO flow from user-facing surfaces (the
      // substitute is model-generated; the original is the recipe's
      // RecipeIngredient.displayName which can be edited).
      untrusted: new Set([
        'step_instruction_text',
        'original_ingredient',
        'substitute_ingredient',
        'amount_conversion',
        'recipe_title',
      ]),
    },
  );

  // ---------------------------------------------------------------------
  // 6. Gemini call + one schema-retry. No hard-rule loop — see header.
  // ---------------------------------------------------------------------
  let parsed: ParsedRewrite | null = null;
  let lastErr: unknown;
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let totalLatency = 0;
  let schemaRetryCount = 0;
  let upstreamRetryCount = 0;

  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const result = await geminiGenerate({
        model: MODEL,
        systemInstruction: renderedPrompt,
        userText:
          'Rewrite the step. Respond with JSON matching the schema exactly. Keep the same cooking technique, structure, and step length — only adjust references to the swapped ingredient and any quantities tied to it.',
        thinkingLevel: 'minimal',
        responseSchema: GEMINI_RESPONSE_SCHEMA,
        maxOutputTokens: 1024,
        promptVersion: activePrompt.version,
      });
      totalInputTokens += result.inputTokens;
      totalOutputTokens += result.outputTokens;
      totalLatency += result.latencyMs;

      try {
        const json = JSON.parse(result.text);
        parsed = RewriteOutput.parse(json);
        break;
      } catch (schemaErr) {
        lastErr = schemaErr;
        schemaRetryCount++;
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
        upstreamRetryCount++;
        userLog.warn('gemini_upstream_error', { attempt: attempt + 1, status: err.status });
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
  const totalRetries = schemaRetryCount + upstreamRetryCount;

  if (!parsed) {
    userLog.error('rewrite_failed_after_retry', lastErr, { retry_count: totalRetries });
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
        span_name: 'recipe_step_rewrite',
        is_error: true,
        error_code: ErrorCode.AI_02,
      },
    );
    return jsonError(
      ErrorCode.AI_02,
      502,
      {
        message: 'Rewriting the step is taking longer than expected. The substitution is saved.',
      },
      requestId,
    );
  }

  const wire: WireResponse = {
    sub_event_id: body.sub_event_id,
    rewritten_text: parsed.rewritten_text,
    prompt_version: activePrompt.version,
    latency_ms: Math.round(performance.now() - started),
    retry_count: totalRetries,
  };

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
      span_name: 'recipe_step_rewrite',
    },
  );

  try {
    // Use the same `:rewrite`-namespaced key as readCache above so a
    // following double-tap with the same sub_event_id replays this
    // rewrite, not the substitution body cached under the bare key.
    await writeCache(client, claims.canonical_user_key, cacheKey, FEATURE_KEY, 200, wire);
  } catch (err) {
    userLog.warn('cache_write_failed', { err: sanitizeErrorForLog(err) });
  }

  userLog.info('request_complete', {
    status: 200,
    latency_ms: wire.latency_ms,
    retry_count: totalRetries,
    cost_usd: costUsd,
  });

  return jsonOk(wire, requestId);
});
