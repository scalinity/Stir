// POST /functions/v1/pantry-parse
// Logical endpoint: POST /v1/ai/pantry-parse (spec §3).
//
// Flow (happy path):
//   1. Auth: session JWT (AUTH-01 on failure)
//   1a. Body-size pre-check (SCA-36 W2): non-Pro callers above ~12MiB
//       short-circuit to ENT-MULTI-IMAGE-01 BEFORE we accept the body.
//   2. Body: Zod parse (VAL-01 on failure)
//   3. Idempotency: ai_response_cache replay if client_request_id known
//   4. Rate limit: ip:pantry_parse_daily (RATE-01)
//   5. Entitlement: multi-image requires Pro (ENT-MULTI-IMAGE-01)
//   5a. Image bytes: decode + magic-byte validation per image
//   6. Kill switch: disable_scan_parse → AI-01 with degraded copy
//   7. Prompt: read active v1.1.0 for pantry_parse
//   8. Call Gemini 3 Flash with image(s) + JSON schema
//   9. Validate output: schema + confidence enum;
//      retry ONCE on single-image failure, NO retry on multi-image
//      (SCA-36 W4 — multi-image retry doubles a $0.02 call).
//  10. Log ai_request_log; cache response; return.
//
// Scan is unmetered across tiers — cost is tracked in ai_request_log but
// no per-user quota row is decremented (per CLAUDE.md §usage_counters).
// IP rate limit stops abuse.
//
// SCA-36 S19 — memory envelope (4-image Pro request):
//   (a) raw req.text() ~40 MB        (b) Zod-parsed body keeping images[] ~40 MB
//   (c) incomingImages[] reshape ~40 MB references (no copy, same backing)
//   (d) per-image Uint8Array decode × 4 = ~24 MB
//   peak isolate heap: ~150 MB. Supabase Edge Function default tier is
//   256 MB. A future bump to 8 photos would push peak to ~300 MB and is
//   NOT safe on the default tier — would need a memory-tier upgrade.

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readFlags } from '../_shared/flags.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { INGREDIENT_ONTOLOGY_SLUGS } from '../_shared/ingredient_ontology.ts';
import { GeminiError, geminiGenerate, GeminiModel } from '../_shared/gemini.ts';
import { computeCostUSD } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import { createLogger, requestIdFrom, sanitizeErrorForLog } from '../_shared/logger.ts';
import { PantryParseRequest, zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
  ipBucket,
} from '../_shared/rate_limiter.ts';
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
  // 1a. Body-size pre-check (SCA-36 W2).
  //
  // A non-Pro caller sending `images: [4 × 10MB-base64]` would force
  // the Edge Function to buffer + Zod-parse ~40 MB before being told
  // ENT-MULTI-IMAGE-01 by the entitlement gate downstream. Read
  // Content-Length and short-circuit non-Pro callers above the
  // single-image budget BEFORE we accept the body. Pro callers retain
  // the full 40 MB ceiling (Zod still bounds each image at 10 MB
  // base64 and total max 4 images = 40 MB).
  //
  // Cap: ~12 MiB — a single image at the 10 MB base64 cap plus JSON
  // overhead and headroom for client-side encoding variance.
  // ---------------------------------------------------------------------
  const NON_PRO_BODY_CAP = 12 * 1024 * 1024;
  const contentLengthHeader = req.headers.get('content-length');
  const declaredContentLength = contentLengthHeader ? parseInt(contentLengthHeader, 10) : NaN;
  if (
    claims.tier !== 'pro' &&
    Number.isFinite(declaredContentLength) &&
    declaredContentLength > NON_PRO_BODY_CAP
  ) {
    userLog.warn('non_pro_oversized_body', {
      tier: claims.tier,
      content_length: declaredContentLength,
    });
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
    const hit = await readCache(client, claims.canonical_user_key, body.client_request_id);
    if (hit) {
      userLog.info('cache_replay', { age_seconds: hit.age_seconds });
      return responseFromCache(hit, requestId);
    }
  } catch (err) {
    // Cache miss-path shouldn't block primary flow.
    userLog.warn('cache_read_failed', { err: sanitizeErrorForLog(err) });
  }

  // ---------------------------------------------------------------------
  // 4. IP rate limit (shared 429 shape via buildRate01Response)
  // ---------------------------------------------------------------------
  const sourceIP = extractSourceIP(req);
  try {
    const rl = await checkAndIncrement(client, 'ip:pantry_parse_daily', sourceIP);
    if (!rl.allowed) {
      userLog.warn('rate_limited', {
        scope: 'ip:pantry_parse_daily',
        source_ip_bucket: await ipBucket(sourceIP),
      });
      return buildRate01Response(
        'ip:pantry_parse_daily',
        rl.retry_after_seconds,
        rl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // SCA-396: fail-open is intentional — see ADR 0036.
    // User-initiated camera shutter; failing during a brownout asks them
    // to re-shoot. Per-IP daily cap absorbs the abuse case.
  }

  // ---------------------------------------------------------------------
  // 5. Entitlement check: multi-image requires Pro
  //
  // SCA-35: derive image count from actual payload shape. `body.images` is
  // the multi-image array (length 2..4, Zod-enforced); when absent, the
  // request is single-image. The legacy `body.image_count` field is a
  // checksum already validated against the actual count in Zod's
  // superRefine, so we don't re-read it here.
  // ---------------------------------------------------------------------
  const imageCount = body.images?.length ?? 1;
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

  // ---------------------------------------------------------------------
  // 5a. Image bytes: decode + magic-byte validation (SA1-003)
  // Before this check we trusted the client-declared mime_type. A request
  // with image_mime_type="image/png" and SVG bytes would flow to Gemini
  // verbatim, opening a narrow OCR-based prompt-injection channel and
  // wasting Gemini quota on broken inputs.
  //
  // SCA-35: validate every image part (singular OR multi) the same way.
  // Build a normalized array of `{ base64, mime_type }` so the rest of
  // the handler doesn't care which payload shape arrived.
  // ---------------------------------------------------------------------
  type IncomingImage = {
    base64: string;
    mime_type: 'image/jpeg' | 'image/png' | 'image/heic' | 'image/webp';
  };
  const incomingImages: IncomingImage[] = body.images
    ? body.images.map((img: IncomingImage): IncomingImage => ({
      base64: img.base64,
      mime_type: img.mime_type,
    }))
    : [{ base64: body.image_base64!, mime_type: body.image_mime_type! }];

  for (let i = 0; i < incomingImages.length; i++) {
    const part = incomingImages[i]!;
    const result = decodeAndValidateImage(part.base64, part.mime_type);
    if (result.kind === 'error') {
      // Translate field path to the actual payload location so client
      // dashboards point at the bad image, not just "image_base64".
      const fieldPath = body.images
        ? `images[${i}].${result.field === 'image_base64' ? 'base64' : 'mime_type'}`
        : result.field;
      userLog.warn('image_validation_failed', { index: i, reason: result.reason });
      return jsonError(
        ErrorCode.VAL_01,
        400,
        {
          message: 'Image bytes failed validation.',
          field_errors: [{ field: fieldPath, issue: result.reason }],
        },
        requestId,
      );
    }
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
        {
          message: 'Scan parsing is temporarily disabled. Try again shortly or pick a saved meal.',
        },
        requestId,
      );
    }
  } catch (err) {
    userLog.warn('flag_read_failed', { err: sanitizeErrorForLog(err) });
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
    // SCA-46: real canonical slug vocabulary. The pantry-parse prompt
    // template instructs the model to draw `canonical_slug` from this
    // list when confident; before SCA-46 the variable rendered as `[]`
    // so every emission was either null or hallucinated, breaking
    // slug coordination with dinner-solve. ~135 starter slugs cover
    // the dominant US weeknight cooking surface; expand as field
    // reports surface gaps.
    ingredient_ontology_slugs: INGREDIENT_ONTOLOGY_SLUGS,
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

  // SCA-35: build the image part(s) once outside the retry loop.
  const isMultiImage = imageCount > 1;
  const userText = isMultiImage
    ? `Identify cooking-relevant ingredients across these ${imageCount} photos of the same kitchen. Merge across photos, dedupe, and respond with JSON matching the schema.`
    : 'Identify cooking-relevant ingredients in this image. Respond with JSON matching the schema.';
  const geminiImages = incomingImages.map((p) => ({
    mimeType: p.mime_type,
    dataBase64: p.base64,
  }));

  // SCA-36 W4: bound retries on multi-image. The retry-once loop
  // helps single-image scans recover from the rare schema-validation
  // drift; on multi-image the cost of re-sending 4 images doubles a
  // ~$0.02 call to ~$0.04, which is meaningful at the per-IP daily cap
  // budget. Schema-validation failures on Gemini 3 Flash with
  // `responseSchema` enforcement are uncommon enough that a single
  // attempt + AI-02 surfaced to the user is the right tradeoff at the
  // higher cost-per-call.
  const maxAttempts = isMultiImage ? 1 : 2;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      const result = await geminiGenerate({
        model: MODEL,
        systemInstruction: renderedPrompt,
        userText,
        ...(isMultiImage ? { images: geminiImages } : { image: geminiImages[0]! }),
        thinkingLevel: 'minimal',
        responseSchema: GEMINI_RESPONSE_SCHEMA,
        // Multi-image scans need slightly more headroom — 4 photos can
        // surface 80+ ingredients easily, and truncation here would force
        // a retry-then-fail. Single-image keeps the existing 2048 budget.
        maxOutputTokens: isMultiImage ? 4096 : 2048,
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
        if (attempt < maxAttempts - 1) {
          retryCount++;
          continue;
        }
      }
    } catch (err) {
      lastErr = err;
      if (err instanceof GeminiError && err.status >= 500) {
        userLog.warn('gemini_upstream_error', { attempt: attempt + 1, status: err.status });
        if (attempt < maxAttempts - 1) {
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
    // SCA-36 S6: include image_count so PostHog cost-attribution
    // distinguishes 1-image vs 4-image failures.
    userLog.error('pantry_parse_failed_after_retry', lastErr, {
      retry_count: retryCount,
      image_count: imageCount,
    });

    // Log failed attempt for cost observability.
    const failedCostUsd = computeCostUSD(MODEL, {
      textInputTokens: totalInputTokens - totalImageTokens,
      imageInputTokens: totalImageTokens,
      textOutputTokens: totalOutputTokens,
    });
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
        cost_usd: failedCostUsd,
        latency_ms: totalLatency,
        thinking_level: 'minimal',
        prompt_version: activePrompt.version,
        retry_count: retryCount,
      },
      {
        trace_id: body.client_request_id,
        span_name: 'pantry_parse',
        is_error: true,
        error_code: ErrorCode.AI_02,
      },
    );

    return jsonError(
      ErrorCode.AI_02,
      status,
      {
        message:
          "I'm not confident about a few ingredients. Try retaking the photo with better lighting.",
      },
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
      span_name: 'pantry_parse',
    },
  );

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
    await writeCache(
      client,
      claims.canonical_user_key,
      body.client_request_id,
      FEATURE_KEY,
      200,
      wire,
    );
  } catch (err) {
    userLog.warn('cache_write_failed', { err: sanitizeErrorForLog(err) });
  }

  userLog.info('request_complete', {
    status: 200,
    latency_ms: wire.latency_ms,
    ingredient_count: parsedOutput.ingredients.length,
    image_count: imageCount,
    retry_count: retryCount,
    cost_usd: costUsd,
  });
  return jsonOk(wire, requestId);
});
