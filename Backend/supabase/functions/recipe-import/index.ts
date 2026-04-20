// POST /functions/v1/recipe-import
// Logical endpoint: POST /v1/ai/recipe-import (spec §3).
//
// Four source_type paths (wire-contract stable):
//   url            : iOS paste flow; server fetches HTML
//   share_sheet    : Safari share extension; server fetches HTML (same code path
//                    as 'url' but distinct for funnel telemetry)
//   screenshot_ocr : iOS ran VNRecognizeTextRequest on-device; sends ocr_text
//   pasted_text    : user pasted free-form text
//
// Sync vs async: if raw content byte-size > feature_flags.recipe_import_async_threshold
// (default 8 KiB), queue the job via notification_jobs and return HTTP 202
// { status: 'queued', import_id }. iOS re-POSTs with same import_id after
// APNs push completion; second call hits ai_response_cache and replays.
// Sync path: single generateContent call to gemini-3.1-flash-lite-preview;
// result persisted to ai_response_cache for idempotent retries.
//
// Safety: imported content is UNTRUSTED. System prompt explicitly forbids
// following embedded directives. Hard-rule validator runs on extracted
// ingredients against household dietary rules; violations flag via
// edit_hints=["dietary_conflict"] — iOS surfaces in Import Review.
//
// Quota: recipe_import is metered (Free:2/mo, Premium/Pro:unlimited per §9).
// Atomic increment BEFORE Gemini work. Refund on Gemini 5xx; NO refund on
// parse_quality='low' or edit_hints with dietary_conflict (we did the work).

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readAppUser } from '../_shared/identity.ts';
import { readFlags } from '../_shared/flags.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiError, GeminiModel, geminiGenerate } from '../_shared/gemini.ts';
import { computeCostUSD, logAIRequest } from '../_shared/ai_request_log.ts';
import { createLogger, requestIdFrom, type Logger } from '../_shared/logger.ts';
import { RecipeImportRequest, zodToFieldErrors } from '../_shared/validation.ts';
import { buildRate01Response, checkAndIncrement, extractSourceIP } from '../_shared/rate_limiter.ts';
import { readCache, responseFromCache, writeCache } from '../_shared/idempotency.ts';
import { incrementQuotaAtomic, refundQuota } from '../_shared/quota.ts';

const FEATURE_KEY = 'recipe_import';
const MODEL = GeminiModel.FlashLite;
const DEFAULT_ASYNC_THRESHOLD_BYTES = 8192;
const URL_FETCH_TIMEOUT_MS = 10_000;
const URL_FETCH_MAX_BYTES = 2 * 1024 * 1024;  // 2 MB
const URL_FETCH_USER_AGENT = 'StirBot/1.0 (+https://stir.app)';

// -----------------------------------------------------------------------------
// Gemini output schema (must match prompt v1.0.0 recipe_import shape)
// -----------------------------------------------------------------------------
const IMPORT_RESPONSE_SCHEMA: Record<string, unknown> = {
  type: 'OBJECT',
  properties: {
    title: { type: 'STRING' },
    servings: { type: 'INTEGER', nullable: true },
    estimated_minutes: { type: 'INTEGER', nullable: true },
    ingredients: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          display_name: { type: 'STRING' },
          canonical_slug: { type: 'STRING', nullable: true },
          amount_text: { type: 'STRING', nullable: true },
          group: { type: 'STRING', nullable: true },
        },
        required: ['display_name'],
      },
    },
    steps: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          step_number: { type: 'INTEGER' },
          instruction_text: { type: 'STRING' },
          timer_seconds: { type: 'INTEGER', nullable: true },
          caution_tags: { type: 'ARRAY', items: { type: 'STRING' } },
        },
        required: ['step_number', 'instruction_text'],
      },
    },
    parse_quality: { type: 'STRING', enum: ['high', 'medium', 'low'] },
    edit_hints: { type: 'ARRAY', items: { type: 'STRING' } },
  },
  required: ['title', 'ingredients', 'steps', 'parse_quality'],
};

const ImportedRecipeSchema = z.object({
  title: z.string().min(1).max(256),
  servings: z.number().int().min(1).max(24).nullable().optional(),
  estimated_minutes: z.number().int().min(1).max(1440).nullable().optional(),
  ingredients: z.array(z.object({
    display_name: z.string().min(1).max(256),
    canonical_slug: z.string().max(128).nullable().optional(),
    amount_text: z.string().max(256).nullable().optional(),
    group: z.string().max(64).nullable().optional(),
  })).max(100),
  steps: z.array(z.object({
    step_number: z.number().int().min(1).max(100),
    instruction_text: z.string().min(1).max(2000),
    timer_seconds: z.number().int().min(0).max(86400).nullable().optional(),
    caution_tags: z.array(z.string().max(64)).max(10).optional(),
  })).max(50),
  parse_quality: z.enum(['high', 'medium', 'low']),
  edit_hints: z.array(z.string().max(64)).max(10).optional(),
});

type ImportedRecipe = z.infer<typeof ImportedRecipeSchema>;

interface RecipeImportResponse {
  import_id: string;
  status: 'completed' | 'queued';
  recipe: ImportedRecipe | null;
  retry_count: number;
  prompt_version: string;
  async_job_id?: string;
}

// -----------------------------------------------------------------------------
// Entry
// -----------------------------------------------------------------------------
Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/recipe-import';
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

  // ---- 1. Auth
  let claims;
  try {
    claims = await verifySessionJWT(req);
  } catch (err) {
    if (err instanceof AuthError) {
      log.warn('auth_failed', { reason: err.reason });
      return jsonError(ErrorCode.AUTH_01, 401, { message: 'Session expired or missing.', reason: err.reason }, requestId);
    }
    log.error('auth_unexpected', err);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }

  const userLog = await createLogger(requestId, endpoint, claims.canonical_user_key);

  // ---- 2. Body validation
  let body: RecipeImportRequest;
  try {
    const raw = await req.text();
    body = RecipeImportRequest.parse(JSON.parse(raw));
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
      { message: 'Request body is not valid JSON.', field_errors: [{ field: '<root>', issue: 'invalid JSON' }] },
      requestId,
    );
  }

  const client = createServiceClient();

  // ---- 3. Idempotency cache — covers both prior sync completion and async re-poll
  try {
    const hit = await readCache(client, claims.canonical_user_key, body.import_id);
    if (hit) {
      userLog.info('cache_replay', { age_seconds: hit.age_seconds, status: hit.status_code });
      return responseFromCache(hit, requestId);
    }
  } catch (err) {
    userLog.warn('cache_read_failed', { err: String(err) });
  }

  // ---- 4. Rate limits (IP)
  const sourceIP = extractSourceIP(req);
  try {
    const ipRl = await checkAndIncrement(client, 'ip:recipe_import_daily', sourceIP);
    if (!ipRl.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:recipe_import_daily', source_ip: sourceIP });
      return buildRate01Response('ip:recipe_import_daily', ipRl.retry_after_seconds, ipRl.reset_at, requestId);
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
  }

  // ---- 5. Kill switch
  try {
    const flags = await readFlags(client);
    const disable = flags.find((f) => f.key === 'disable_imports');
    if (disable?.is_enabled && (disable.value as { value?: boolean } | boolean) === true) {
      userLog.warn('kill_switch_active', { flag: 'disable_imports' });
      return jsonError(
        ErrorCode.IMPORT_01,
        503,
        { message: 'Recipe import is temporarily disabled.' },
        requestId,
      );
    }
  } catch (err) {
    userLog.warn('flag_read_failed', { err: String(err) });
  }

  // ---- 6. User + quota (Free:2/mo, Premium/Pro:unlimited)
  const userRow = await readAppUser(client, claims.canonical_user_key);
  if (!userRow) {
    userLog.warn('user_row_missing');
    return jsonError(ErrorCode.AUTH_01, 401, { message: 'User not found; re-bootstrap.', reason: 'user_stale' }, requestId);
  }
  if (userRow.status === 'banned') {
    return jsonError(ErrorCode.BILL_01, 403, { message: 'Account is not eligible for Stir.', state: 'banned' }, requestId);
  }

  const quotaResult = await incrementQuotaAtomic(
    client,
    claims.canonical_user_key,
    'recipe_import',
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
        message: "You've used all of this month's Recipe Imports for your plan.",
        scope: 'user:recipe_import_monthly',
        used: quotaResult.used,
        cap: quotaResult.cap,
      },
      requestId,
    );
  }
  const consumedPeriodStart = quotaResult.period_start;

  // ---- 7. Resolve raw content per source_type
  let rawContent: string;
  try {
    rawContent = await resolveRawContent(body, userLog);
  } catch (err) {
    await refundQuota(client, userLog, claims.canonical_user_key, 'recipe_import', consumedPeriodStart);
    const message = err instanceof FetchFailure ? err.message : 'Failed to fetch source content.';
    userLog.warn('source_fetch_failed', { source_type: body.source_type, err: String(err) });
    return jsonError(ErrorCode.IMPORT_01, 502, { message, source_type: body.source_type }, requestId);
  }

  // ---- 8. Async threshold check
  const asyncThresholdBytes = await readAsyncThresholdBytes(client);
  const rawBytes = new TextEncoder().encode(rawContent).byteLength;
  const isAsync = rawBytes > asyncThresholdBytes;

  if (isAsync) {
    const jobId = await enqueueAsync(
      client,
      claims.canonical_user_key,
      body,
      rawContent,
    );
    const queuedBody = {
      import_id: body.import_id,
      status: 'queued' as const,
      recipe: null,
      retry_count: 0,
      prompt_version: '1.0.0',   // best-effort; worker records real version on completion
      async_job_id: jobId,
    };
    userLog.info('queued_async', { job_id: jobId, raw_bytes: rawBytes });
    return jsonOk(queuedBody, requestId, 202);
  }

  // ---- 9. Sync path — prompt + Gemini
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    await refundQuota(client, userLog, claims.canonical_user_key, 'recipe_import', consumedPeriodStart);
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  const rendered = renderPrompt(
    activePrompt.template_blob,
    { source_type: body.source_type, raw_content: rawContent },
    { untrusted: new Set(['raw_content']) },
  );

  let recipe: ImportedRecipe | null = null;
  let retryCount = 0;
  let totalInputTokens = 0;
  let totalOutputTokens = 0;
  let totalLatencyMs = 0;
  let lastErr: unknown;

  for (let attempt = 0; attempt <= 1; attempt++) {
    try {
      const result = await geminiGenerate({
        model: MODEL,
        systemInstruction: rendered,
        userText: 'Normalize the raw content into the structured recipe schema.',
        thinkingLevel: 'minimal',
        responseSchema: IMPORT_RESPONSE_SCHEMA,
        maxOutputTokens: 4096,
        promptVersion: activePrompt.version,
      });
      totalInputTokens += result.inputTokens;
      totalOutputTokens += result.outputTokens;
      totalLatencyMs += result.latencyMs;

      try {
        recipe = ImportedRecipeSchema.parse(JSON.parse(result.text));
        break;
      } catch (schemaErr) {
        lastErr = schemaErr;
        userLog.warn('import_schema_invalid', { attempt: attempt + 1, err: String(schemaErr) });
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

  const costUsd = computeCostUSD(MODEL, {
    textInputTokens: totalInputTokens,
    textOutputTokens: totalOutputTokens,
  });

  if (!recipe) {
    await refundQuota(client, userLog, claims.canonical_user_key, 'recipe_import', consumedPeriodStart);
    logAIRequest(client, userLog, {
      request_id: body.import_id,
      canonical_user_key: claims.canonical_user_key,
      feature_key: FEATURE_KEY,
      model: MODEL,
      input_tokens: totalInputTokens,
      output_tokens: totalOutputTokens,
      cost_usd: costUsd,
      latency_ms: totalLatencyMs,
      thinking_level: 'minimal',
      prompt_version: activePrompt.version,
      retry_count: retryCount,
    });
    userLog.error('import_failed_upstream', lastErr, { retry_count: retryCount });
    return jsonError(
      ErrorCode.IMPORT_01,
      502,
      { message: "I couldn't turn that recipe into clean steps yet." },
      requestId,
    );
  }

  // Dietary-conflict pass: deferred to iOS. The backend doesn't mirror
  // HouseholdProfile / DietaryRule (CloudKit-only per §3 invariant), so
  // the check runs at Import Review with local rules. edit_hints flows
  // through from the model unchanged. When household_context is wired
  // into this handler later (same pattern as substitution), re-enable a
  // server-side pass here as belt-and-suspenders.

  logAIRequest(client, userLog, {
    request_id: body.import_id,
    canonical_user_key: claims.canonical_user_key,
    feature_key: FEATURE_KEY,
    model: MODEL,
    input_tokens: totalInputTokens,
    output_tokens: totalOutputTokens,
    cost_usd: costUsd,
    latency_ms: totalLatencyMs,
    thinking_level: 'minimal',
    prompt_version: activePrompt.version,
    retry_count: retryCount,
  });

  const responseBody: RecipeImportResponse = {
    import_id: body.import_id,
    status: 'completed',
    recipe,
    retry_count: retryCount,
    prompt_version: activePrompt.version,
  };

  // Cache the completed response so a retry hits the idempotency cache
  // before re-charging quota.
  try {
    await writeCache(client, claims.canonical_user_key, body.import_id, FEATURE_KEY, 200, responseBody);
  } catch (err) {
    userLog.warn('cache_write_failed', { err: String(err) });
  }

  userLog.info('request_complete', {
    status: 200,
    latency_ms: Math.round(performance.now() - started),
    parse_quality: recipe.parse_quality,
    ingredient_count: recipe.ingredients.length,
    step_count: recipe.steps.length,
    retry_count: retryCount,
    cost_usd: costUsd,
  });

  return jsonOk(responseBody, requestId, 200);
});

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

class FetchFailure extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'FetchFailure';
  }
}

async function resolveRawContent(
  body: RecipeImportRequest,
  log: Logger,
): Promise<string> {
  const payload = body.payload as unknown as {
    url?: string;
    ocr_text?: string;
    pasted_text?: string;
  };

  switch (body.source_type) {
    case 'url':
    case 'share_sheet': {
      if (!payload.url) throw new FetchFailure('url missing');
      const html = await fetchUrlText(payload.url);
      const extracted = extractRecipeText(html);
      log.info('source_fetched', {
        url: payload.url.slice(0, 200),
        html_bytes: html.length,
        extracted_bytes: extracted.length,
      });
      return extracted;
    }
    case 'screenshot_ocr':
      if (!payload.ocr_text) throw new FetchFailure('ocr_text missing');
      return payload.ocr_text;
    case 'pasted_text':
      if (!payload.pasted_text) throw new FetchFailure('pasted_text missing');
      return payload.pasted_text;
  }
  // Unreachable under Zod-narrowed source_type (enum of 4); present so the
  // function return type stays honest if a fifth variant is ever added.
  throw new FetchFailure(`unknown source_type: ${String(body.source_type)}`);
}

async function fetchUrlText(url: string): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), URL_FETCH_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      method: 'GET',
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        'user-agent': URL_FETCH_USER_AGENT,
        'accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
        'accept-language': 'en-US,en;q=0.9',
      },
    });
    if (!response.ok) {
      throw new FetchFailure(`upstream ${response.status}`);
    }
    const contentType = response.headers.get('content-type') ?? '';
    if (!contentType.includes('text/') && !contentType.includes('json') && !contentType.includes('xml')) {
      throw new FetchFailure(`unsupported content-type: ${contentType.slice(0, 64)}`);
    }
    // Enforce the byte cap while streaming — avoids pulling a 50MB video
    // page wholesale into memory only to discover it's unusable.
    const reader = response.body?.getReader();
    if (!reader) throw new FetchFailure('empty body');
    const chunks: Uint8Array[] = [];
    let total = 0;
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > URL_FETCH_MAX_BYTES) {
        await reader.cancel();
        throw new FetchFailure(`response exceeds ${URL_FETCH_MAX_BYTES} bytes`);
      }
      chunks.push(value);
    }
    const decoder = new TextDecoder('utf-8', { fatal: false });
    return chunks.map((c) => decoder.decode(c, { stream: true })).join('') + decoder.decode();
  } catch (err) {
    if (err instanceof FetchFailure) throw err;
    if ((err as Error).name === 'AbortError') throw new FetchFailure(`timeout after ${URL_FETCH_TIMEOUT_MS}ms`);
    throw new FetchFailure(`fetch failed: ${(err as Error).message}`);
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Minimal HTML → text extraction:
 *   1. Prefer <script type="application/ld+json"> recipe schema if present
 *      (schema.org/Recipe); return as pretty JSON string for the model.
 *   2. Strip <script>/<style>/<noscript>/<template> blocks wholesale.
 *   3. Collapse remaining HTML tags + entities to plain text, normalize
 *      whitespace, trim.
 *
 * Keeps ~30–120 KB of content for a typical recipe page. The model is
 * instructed to treat this content as untrusted data.
 */
function extractRecipeText(html: string): string {
  // JSON-LD first pass.
  const ldJsonMatches = Array.from(html.matchAll(
    /<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi,
  ));
  for (const match of ldJsonMatches) {
    const blob = match[1]?.trim();
    if (!blob) continue;
    try {
      const parsed = JSON.parse(blob);
      const recipes = findRecipeBlocks(parsed);
      if (recipes.length > 0) {
        // Return the first Recipe block pretty-printed — compact + rich.
        return JSON.stringify(recipes[0], null, 2);
      }
    } catch {
      // Not valid JSON-LD; fall through to HTML stripping.
    }
  }

  // Strip noise blocks.
  let stripped = html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<template[\s\S]*?<\/template>/gi, ' ')
    .replace(/<!--[\s\S]*?-->/g, ' ');

  // Replace block-level tags with newlines for readability.
  stripped = stripped.replace(/<\/(p|div|section|article|li|h[1-6]|tr)>/gi, '\n');

  // Drop remaining tags.
  stripped = stripped.replace(/<[^>]+>/g, ' ');

  // Decode a minimal set of HTML entities.
  stripped = stripped
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>')
    .replace(/&quot;/gi, '"')
    .replace(/&#039;/gi, "'")
    .replace(/&#x27;/gi, "'")
    .replace(/&rsquo;/gi, "\u2019")
    .replace(/&lsquo;/gi, "\u2018");

  // Collapse whitespace.
  return stripped.replace(/\s+/g, ' ').trim();
}

function findRecipeBlocks(jsonLd: unknown): unknown[] {
  const out: unknown[] = [];
  const visit = (node: unknown): void => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) {
      for (const n of node) visit(n);
      return;
    }
    const obj = node as Record<string, unknown>;
    const type = obj['@type'];
    if (type === 'Recipe' || (Array.isArray(type) && type.includes('Recipe'))) {
      out.push(obj);
    }
    if (Array.isArray(obj['@graph'])) {
      for (const n of obj['@graph']) visit(n);
    }
    // Recurse into common recipe-container keys too.
    for (const key of ['mainEntity', 'hasPart', 'itemListElement']) {
      const v = obj[key];
      if (v !== undefined) visit(v);
    }
  };
  visit(jsonLd);
  return out;
}

async function readAsyncThresholdBytes(client: ReturnType<typeof createServiceClient>): Promise<number> {
  try {
    const flags = await readFlags(client);
    const flag = flags.find((f) => f.key === 'recipe_import_async_threshold');
    if (flag?.is_enabled && typeof flag.value === 'number' && flag.value >= 512) {
      return flag.value;
    }
  } catch {
    // Fall through to default.
  }
  return DEFAULT_ASYNC_THRESHOLD_BYTES;
}

interface AsyncJobPayload {
  import_id: string;
  source_type: RecipeImportRequest['source_type'];
  raw_content: string;
  original_url?: string;
  ocr_page_count?: number;
}

async function enqueueAsync(
  client: ReturnType<typeof createServiceClient>,
  canonicalUserKey: string,
  body: RecipeImportRequest,
  rawContent: string,
): Promise<string> {
  const payload = body.payload as unknown as { url?: string; ocr_page_count?: number };
  const jobPayload: AsyncJobPayload = {
    import_id: body.import_id,
    source_type: body.source_type,
    raw_content: rawContent,
    ...(payload.url ? { original_url: payload.url } : {}),
    ...(payload.ocr_page_count !== undefined ? { ocr_page_count: payload.ocr_page_count } : {}),
  };
  const { data, error } = await client
    .from('notification_jobs')
    .insert({
      canonical_user_key: canonicalUserKey,
      kind: 'recipe_import_async',
      state: 'pending',
      payload_json: jobPayload,
    })
    .select('id')
    .single<{ id: string }>();
  if (error) throw error;
  return data.id;
}
