// POST /functions/v1/pantry-parse
// Logical endpoint: POST /v1/ai/pantry-parse (spec §3).
//
// Flow (happy path):
//   1. Auth: session JWT (AUTH-01 on failure)
//   2. Body: Zod parse (VAL-01 on failure)
//   3. Idempotency: ai_response_cache replay if client_request_id known
//   4. Rate limit: ip:pantry_parse_daily (RATE-01)
//   5. Entitlement: multi-image requires Pro (ENT-MULTI-IMAGE-01)
//   6. Kill switch: disable_scan_parse → AI-01 with degraded copy
//   7. Prompt: read active v1.0.0 for pantry_parse
//   8. Call Gemini 3 Flash with image + JSON schema
//   9. Validate output: schema + confidence enum; retry ONCE on failure
//  10. Log ai_request_log; cache response; return.
//
// Scan is unmetered across tiers — cost is tracked in ai_request_log but
// no per-user quota row is decremented (per CLAUDE.md §usage_counters).
// IP rate limit stops abuse.

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import {
  ErrorCode,
  jsonError,
  jsonOk,
} from '../_shared/errors.ts';
import { readFlags } from '../_shared/flags.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiError, GeminiModel, geminiGenerate } from '../_shared/gemini.ts';
import { computeCostUSD, logAIRequest } from '../_shared/ai_request_log.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { PantryParseRequest, zodToFieldErrors } from '../_shared/validation.ts';
import { buildRate01Response, checkAndIncrement, extractSourceIP } from '../_shared/rate_limiter.ts';
import { readCache, responseFromCache, writeCache } from '../_shared/idempotency.ts';
import { decodeAndValidateImage } from '../_shared/image_validation.ts';

const FEATURE_KEY = 'pantry_parse';
const MODEL = GeminiModel.Flash;

// Response JSON schema Gemini is asked to adhere to.
const GEMINI_RESPONSE_SCHEMA: Record<string, unknown> = {
  type: 'OBJECT',
  properties: {
    ingredients: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          display_name: { type: 'STRING' },
          canonical_slug: { type: 'STRING', nullable: true },
          confidence: {
            type: 'STRING',
            enum: ['confirmed', 'needs_review', 'likely_staple'],
          },
          amount_text: { type: 'STRING', nullable: true },
          bounding_box: {
            type: 'OBJECT',
            nullable: true,
            properties: {
              x: { type: 'NUMBER' },
              y: { type: 'NUMBER' },
              w: { type: 'NUMBER' },
              h: { type: 'NUMBER' },
            },
          },
        },
        required: ['display_name', 'confidence'],
      },
    },
    overall_confidence: { type: 'NUMBER' },
  },
  required: ['ingredients', 'overall_confidence'],
};

// ZodSchema for what we expect back from Gemini AFTER JSON.parse.
// This is the output-validation step per CLAUDE.md §AI architecture.
const ParseOutput = z.object({
  ingredients: z.array(z.object({
    display_name: z.string().min(1),
    canonical_slug: z.string().min(1).nullable().optional(),
    confidence: z.enum(['confirmed', 'needs_review', 'likely_staple']),
    amount_text: z.string().nullable().optional(),
    bounding_box: z.object({
      x: z.number(),
      y: z.number(),
      w: z.number(),
      h: z.number(),
    }).nullable().optional(),
  })),
  overall_confidence: z.number().min(0).max(1),
});

type ParsedOutput = z.infer<typeof ParseOutput>;

interface WireResponse {
  parse_id: string;
  ingredients: ParsedOutput['ingredients'];
  overall_confidence: number;
  prompt_version: string;
  latency_ms: number;
  retry_count: number;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/pantry-parse';
  const log = await createLogger(requestId, endpoint);

  if (req.method !== 'POST') {
    log.warn('method_not_allowed', { method: req.method });
    return jsonError(ErrorCode.VAL_01, 405, { message: 'Method Not Allowed; use POST.' }, requestId);
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
    const parsed = PantryParseRequest.parse(JSON.parse(raw));
    body = parsed;
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
      { message: 'Request body is not valid JSON.', field_errors: [{ field: '<root>', issue: 'invalid JSON' }] },
      requestId,
    );
  }

  const client = createServiceClient();

  // ---------------------------------------------------------------------
  // 3. Idempotency cache
  // ---------------------------------------------------------------------
  try {
    const hit = await readCache(client, body.client_request_id);
    if (hit) {
      userLog.info('cache_replay', { age_seconds: hit.age_seconds });
      return responseFromCache(hit, requestId);
    }
  } catch (err) {
    // Cache miss-path shouldn't block primary flow.
    userLog.warn('cache_read_failed', { err: String(err) });
  }

  // ---------------------------------------------------------------------
  // 4. IP rate limit (shared 429 shape via buildRate01Response)
  // ---------------------------------------------------------------------
  const sourceIP = extractSourceIP(req);
  try {
    const rl = await checkAndIncrement(client, 'ip:pantry_parse_daily', sourceIP);
    if (!rl.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:pantry_parse_daily', source_ip: sourceIP });
      return buildRate01Response(
        'ip:pantry_parse_daily',
        rl.retry_after_seconds,
        rl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // Fail open — rate limiter error shouldn't block legitimate requests.
  }

  // ---------------------------------------------------------------------
  // 5. Entitlement check: multi-image requires Pro
  // ---------------------------------------------------------------------
  const imageCount = body.image_count ?? 1;
  if (imageCount > 1 && claims.tier !== 'pro') {
    userLog.warn('multi_image_denied', { tier: claims.tier, image_count: imageCount });
    return jsonError(
      ErrorCode.ENT_MULTI_IMAGE_01,
      403,
      {
        message: 'Multi-image scan is available on Pro.',
        required_tier: 'pro',
        current_tier: claims.tier,
      },
      requestId,
    );
  }

  // TODO(step-7): remove this block when multi-image UX ships. Step 3 is
  // single-image only even for Pro — the tier gate above is the stable
  // backend surface; this block only fails safe until the UI catches up.
  if (imageCount > 1) {
    userLog.warn('multi_image_not_yet_supported', { image_count: imageCount });
    return jsonError(
      ErrorCode.VAL_01,
      400,
      {
        message: 'Multi-image scan is not yet implemented in the backend. Send image_count=1.',
        field_errors: [{ field: 'image_count', issue: 'Only image_count=1 accepted in step 3.' }],
      },
      requestId,
    );
  }

  // ---------------------------------------------------------------------
  // 5a. Image bytes: decode + magic-byte validation (SA1-003)
  // Before this check we trusted the client-declared mime_type. A request
  // with image_mime_type="image/png" and SVG bytes would flow to Gemini
  // verbatim, opening a narrow OCR-based prompt-injection channel and
  // wasting Gemini quota on broken inputs.
  // ---------------------------------------------------------------------
  const imageBytes = decodeAndValidateImage(body.image_base64, body.image_mime_type);
  if (imageBytes.kind === 'error') {
    userLog.warn('image_validation_failed', { reason: imageBytes.reason });
    return jsonError(
      ErrorCode.VAL_01,
      400,
      {
        message: 'Image bytes failed validation.',
        field_errors: [{ field: imageBytes.field, issue: imageBytes.reason }],
      },
      requestId,
    );
  }

  // ---------------------------------------------------------------------
  // 6. Kill switch: disable_scan_parse
  // ---------------------------------------------------------------------
  try {
    const flags = await readFlags(client);
    const killSwitch = flags.find((f) => f.key === 'disable_scan_parse');
    if (killSwitch?.is_enabled && killSwitch.value === true) {
      userLog.warn('kill_switch_active', { flag: 'disable_scan_parse' });
      return jsonError(
        ErrorCode.AI_01,
        503,
        { message: 'Scan parsing is temporarily disabled. Try again shortly or pick a saved meal.' },
        requestId,
      );
    }
  } catch (err) {
    userLog.warn('flag_read_failed', { err: String(err) });
    // Fail open — if flags unreadable, default to enabled.
  }

  // ---------------------------------------------------------------------
  // 7. Prompt
  // ---------------------------------------------------------------------
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  const renderedPrompt = renderPrompt(activePrompt.template_blob, {
    household_profile_json: { hash: body.household_profile_hash ?? null },
    ingredient_ontology_slugs: [],
  });

  // ---------------------------------------------------------------------
  // 8. Gemini call + retry-once
  // ---------------------------------------------------------------------
  const parseId = crypto.randomUUID();
  let retryCount = 0;
  let parsedOutput: ParsedOutput | null = null;
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let totalImageTokens = 0;
  let totalLatency = 0;
  let lastErr: unknown;

  for (let attempt = 0; attempt <= 1; attempt++) {
    try {
      const result = await geminiGenerate({
        model: MODEL,
        systemInstruction: renderedPrompt,
        userText: 'Identify cooking-relevant ingredients in this image. Respond with JSON matching the schema.',
        image: {
          mimeType: body.image_mime_type,
          dataBase64: body.image_base64,
        },
        thinkingLevel: 'minimal',
        responseSchema: GEMINI_RESPONSE_SCHEMA,
        maxOutputTokens: 2048,
        promptVersion: activePrompt.version,
      });
      totalInputTokens += result.inputTokens;
      totalOutputTokens += result.outputTokens;
      totalImageTokens += result.imageInputTokens;
      totalLatency += result.latencyMs;

      try {
        const json = JSON.parse(result.text);
        parsedOutput = ParseOutput.parse(json);
        break; // success
      } catch (schemaErr) {
        lastErr = schemaErr;
        userLog.warn('schema_validation_failed', {
          attempt: attempt + 1,
          finish_reason: result.finishReason,
          err: String(schemaErr),
        });
        if (attempt === 0) {
          retryCount++;
          continue;
        }
      }
    } catch (err) {
      lastErr = err;
      if (err instanceof GeminiError && err.status >= 500) {
        userLog.warn('gemini_upstream_error', { attempt: attempt + 1, status: err.status });
        if (attempt === 0) {
          retryCount++;
          continue;
        }
      } else {
        userLog.error('gemini_call_failed', err);
        break;
      }
    }
  }

  if (!parsedOutput) {
    // Both Gemini 5xx and schema-invalid output surface as 502 AI-02. The
    // distinction would be useful (upstream vs model drift), but not
    // different enough to warrant separate status codes in step 3.
    const status = 502;
    userLog.error('pantry_parse_failed_after_retry', lastErr, { retry_count: retryCount });

    // Log failed attempt for cost observability.
    logAIRequest(client, userLog, {
      request_id: body.client_request_id,
      canonical_user_key: claims.canonical_user_key,
      feature_key: FEATURE_KEY,
      model: MODEL,
      input_tokens: totalInputTokens,
      output_tokens: totalOutputTokens,
      cost_usd: computeCostUSD(MODEL, {
        textInputTokens: totalInputTokens - totalImageTokens,
        imageInputTokens: totalImageTokens,
        textOutputTokens: totalOutputTokens,
      }),
      latency_ms: totalLatency,
      thinking_level: 'minimal',
      prompt_version: activePrompt.version,
      retry_count: retryCount,
    });

    return jsonError(
      ErrorCode.AI_02,
      status,
      { message: "I'm not confident about a few ingredients. Try retaking the photo with better lighting." },
      requestId,
    );
  }

  // ---------------------------------------------------------------------
  // 9. Success: log + cache + respond
  // ---------------------------------------------------------------------
  const costUsd = computeCostUSD(MODEL, {
    textInputTokens: totalInputTokens - totalImageTokens,
    imageInputTokens: totalImageTokens,
    textOutputTokens: totalOutputTokens,
  });
  logAIRequest(client, userLog, {
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
  });

  const wire: WireResponse = {
    parse_id: parseId,
    ingredients: parsedOutput.ingredients,
    overall_confidence: parsedOutput.overall_confidence,
    prompt_version: activePrompt.version,
    latency_ms: Math.round(performance.now() - started),
    retry_count: retryCount,
  };

  // Best-effort cache write.
  try {
    await writeCache(client, body.client_request_id, FEATURE_KEY, 200, wire);
  } catch (err) {
    userLog.warn('cache_write_failed', { err: String(err) });
  }

  userLog.info('request_complete', {
    status: 200,
    latency_ms: wire.latency_ms,
    ingredient_count: parsedOutput.ingredients.length,
    retry_count: retryCount,
    cost_usd: costUsd,
  });
  return jsonOk(wire, requestId);
});
