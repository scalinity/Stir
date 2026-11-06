// POST /functions/v1/recipe-import admits URL, shared URL, OCR, or pasted text.
// Large inputs enter a ten-minute queued operation; identical import_id retries
// replay its job/result before quota work. GET ?import_id=<uuid> retrieves only
// the authenticated owner's existing result and never admits work or debits quota.
// Parsed results are readable for ten minutes from completion. Expiry is explicit;
// an intentional retry submits a new import_id. Queue raw input is scrubbed at
// terminal state, with a database deadline sweep independent of Edge availability.
//
// URL content is untrusted. TCP pins a validated public address and TLS verifies
// the original hostname on that socket. Import Review checks current local hard
// dietary rules across ingredient names, slugs, amounts, and cooking instructions,
// independently of model parse confidence, and blocks saving conflicts.

import { z, ZodError } from 'zod';
import { FetchFailure, fetchPublicRecipeText } from '../_shared/recipe_url_fetch.ts';
import { AuthError, requireActiveAccount, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readAppUser } from '../_shared/identity.ts';
import { readFlags } from '../_shared/flags.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { AITextError, aiTextGenerate, textModelFor } from '../_shared/ai_text.ts';
import { computeCostUSD } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import {
  createLogger,
  type Logger,
  requestIdFrom,
  sanitizeErrorForLog,
} from '../_shared/logger.ts';
import { RecipeImportRequest, zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
  ipBucket,
} from '../_shared/rate_limiter.ts';
import { writeCache } from '../_shared/idempotency.ts';
import { incrementQuotaAtomic, refundQuota } from '../_shared/quota.ts';
import { computeCurrentPeriodStart, toIsoDate } from '../_shared/entitlements.ts';
import { findImportResult } from '../_shared/recipe_import_result.ts';

const FEATURE_KEY = 'recipe_import';
const MODEL = textModelFor('recipe_import');
const DEFAULT_ASYNC_THRESHOLD_BYTES = 8192;

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

  if (req.method !== 'POST' && req.method !== 'GET') {
    log.warn('method_not_allowed', { method: req.method });
    return jsonError(
      ErrorCode.METHOD_NOT_ALLOWED_01,
      405,
      { message: 'Method Not Allowed; use POST or GET.', allowed: ['POST', 'GET'] },
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
      return jsonError(ErrorCode.AUTH_01, 401, {
        message: 'Session expired or missing.',
        reason: err.reason,
      }, requestId);
    }
    log.error('auth_unexpected', err);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }

  const userLog = await createLogger(requestId, endpoint, claims.canonical_user_key);
  const client = createServiceClient();
  // A still-valid JWT cannot replay content after the account is banned,
  // removed, or merged. Apply the shared guard before either GET or POST replay.
  const accountError = await requireActiveAccount(client, claims.canonical_user_key, requestId);
  if (accountError) return accountError;

  // Result reads never fetch a source, consume quota, or admit a job.
  if (req.method === 'GET') {
    const id = z.string().uuid().safeParse(new URL(req.url).searchParams.get('import_id'));
    if (!id.success) {
      return jsonError(
        ErrorCode.VAL_01,
        400,
        { message: 'A valid import_id is required.' },
        requestId,
      );
    }
    try {
      return (await findImportResult(client, claims.canonical_user_key, id.data, requestId, true))!;
    } catch (err) {
      userLog.error('import_result_read_failed', err);
      return jsonError(ErrorCode.NET_01, 503, undefined, requestId);
    }
  }

  // ---- 2. Body validation
  let body: RecipeImportRequest;
  try {
    const raw = await req.text();
    body = RecipeImportRequest.parse(JSON.parse(raw));
    body.import_id = body.import_id.toLowerCase();
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

  // Replay accepted operations before any rate/quota/fetch work. A read
  // failure is not permission to create a duplicate accepted job.
  try {
    const existing = await findImportResult(
      client,
      claims.canonical_user_key,
      body.import_id,
      requestId,
    );
    if (existing) return existing;
  } catch (err) {
    userLog.error('import_replay_failed', err);
    return jsonError(ErrorCode.NET_01, 503, undefined, requestId);
  }

  // ---- 4. Rate limits (IP)
  const sourceIP = extractSourceIP(req);
  try {
    const ipRl = await checkAndIncrement(client, 'ip:recipe_import_daily', sourceIP);
    if (!ipRl.allowed) {
      userLog.warn('rate_limited', {
        scope: 'ip:recipe_import_daily',
        source_ip_bucket: await ipBucket(sourceIP),
      });
      return buildRate01Response(
        'ip:recipe_import_daily',
        ipRl.retry_after_seconds,
        ipRl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
    // SCA-396: fail-open is intentional — see ADR 0036.
    // Post-auth + billable; per-IP daily cap absorbs the abuse case.
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
    userLog.warn('flag_read_failed', { err: sanitizeErrorForLog(err) });
  }

  // ---- 6. User + quota (Free:2/mo, Premium/Pro:unlimited)
  const userRow = await readAppUser(client, claims.canonical_user_key);
  if (!userRow) {
    userLog.warn('user_row_missing');
    return jsonError(ErrorCode.AUTH_01, 401, {
      message: 'User not found; re-bootstrap.',
      reason: 'user_stale',
    }, requestId);
  }
  if (userRow.status === 'banned') {
    return jsonError(ErrorCode.BILL_01, 403, {
      message: 'Account is not eligible for Stir.',
      state: 'banned',
    }, requestId);
  }

  // ---- 7. Resolve raw content per source_type
  let rawContent: string;
  try {
    rawContent = await resolveRawContent(body, userLog);
  } catch (err) {
    const message = err instanceof FetchFailure ? err.message : 'Failed to fetch source content.';
    userLog.warn('source_fetch_failed', {
      source_type: body.source_type,
      err: sanitizeErrorForLog(err),
    });
    return jsonError(
      ErrorCode.IMPORT_01,
      502,
      { message, source_type: body.source_type },
      requestId,
    );
  }

  // ---- 8. Async threshold check
  const asyncThresholdBytes = await readAsyncThresholdBytes(client);
  const rawBytes = new TextEncoder().encode(rawContent).byteLength;
  const isAsync = rawBytes > asyncThresholdBytes;

  if (isAsync) {
    try {
      const { periodStart } = computeCurrentPeriodStart(new Date(userRow.created_at), new Date());
      const admission = await enqueueAsync(
        client,
        claims.canonical_user_key,
        body,
        rawContent,
        toIsoDate(periodStart),
      );
      if (admission.status === 'capped') {
        return jsonError(ErrorCode.RATE_01, 429, {
          message: "You've used all of this month's Recipe Imports for your plan.",
          scope: 'user:recipe_import_monthly',
          used: admission.used,
          cap: admission.cap,
        }, requestId);
      }
      if (admission.status === 'not_bootstrapped') {
        return jsonError(ErrorCode.VAL_01, 400, {
          message: 'Call /v1/session/bootstrap to refresh the current quota period.',
        }, requestId);
      }
      // The RPC serializes same-ID requests with debit+enqueue in one transaction.
      const accepted = await findImportResult(
        client,
        claims.canonical_user_key,
        body.import_id,
        requestId,
      );
      if (!accepted) throw new Error('accepted import missing');
      return accepted;
    } catch (err) {
      userLog.error('import_admission_failed', err);
      return jsonError(ErrorCode.NET_01, 503, undefined, requestId);
    }
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

  // ---- 9. Sync path — prompt + Gemini
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    await refundQuota(
      client,
      userLog,
      claims.canonical_user_key,
      'recipe_import',
      consumedPeriodStart,
    );
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
      const result = await aiTextGenerate({
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
      if (err instanceof AITextError && err.usage) {
        totalInputTokens += err.usage.inputTokens;
        totalOutputTokens += err.usage.outputTokens;
        totalLatencyMs += err.usage.latencyMs;
      }
      if (err instanceof AITextError && err.status >= 500) {
        userLog.warn('ai_upstream_error', { attempt: attempt + 1, status: err.status });
        if (attempt === 0) {
          retryCount++;
          continue;
        }
      } else {
        userLog.error('ai_call_failed', err);
        break;
      }
    }
  }

  const costUsd = computeCostUSD(MODEL, {
    textInputTokens: totalInputTokens,
    textOutputTokens: totalOutputTokens,
  });

  if (!recipe) {
    await refundQuota(
      client,
      userLog,
      claims.canonical_user_key,
      'recipe_import',
      consumedPeriodStart,
    );
    recordAIRequest(
      client,
      userLog,
      {
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
      },
      {
        trace_id: body.import_id,
        span_name: 'recipe_import',
        is_error: true,
        error_code: ErrorCode.IMPORT_01,
      },
    );
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

  recordAIRequest(
    client,
    userLog,
    {
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
    },
    {
      trace_id: body.import_id,
      span_name: 'recipe_import',
    },
  );

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
    await writeCache(
      client,
      claims.canonical_user_key,
      body.import_id,
      FEATURE_KEY,
      200,
      responseBody,
    );
  } catch (err) {
    userLog.warn('cache_write_failed', { err: sanitizeErrorForLog(err) });
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
      const html = await fetchPublicRecipeText(payload.url);
      const extracted = extractRecipeText(html);
      log.info('source_fetched', {
        // Host-only — paths/queries can carry session tokens, referral
        // tokens, or identify private-blog posts tied to the user
        // (SA3-11). The full URL is captured on the RecipeImport audit
        // row iOS-side; it doesn't need to land in operational logs.
        url_host: safeUrlHost(payload.url),
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

function safeUrlHost(raw: string): string {
  try {
    return new URL(raw).host;
  } catch {
    return '<unparseable>';
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

  // Strip noise blocks. Iterate until the output stabilizes so nested
  // occlusions like `<scr<script>ipt>alert()</script>ipt>` can't leave
  // a half-stripped payload. Cap at 8 passes so a pathological input
  // can't DoS the Edge Function.
  const NOISE_PATTERNS: RegExp[] = [
    /<script[\s\S]*?<\/script>/gi,
    /<style[\s\S]*?<\/style>/gi,
    /<noscript[\s\S]*?<\/noscript>/gi,
    /<template[\s\S]*?<\/template>/gi,
    /<!--[\s\S]*?-->/g,
  ];
  let stripped = html;
  for (let i = 0; i < 8; i++) {
    let next = stripped;
    for (const pattern of NOISE_PATTERNS) {
      next = next.replace(pattern, ' ');
    }
    if (next === stripped) break;
    stripped = next;
  }

  // Replace block-level tags with newlines for readability.
  stripped = stripped.replace(/<\/(p|div|section|article|li|h[1-6]|tr)>/gi, '\n');

  // Drop remaining tags.
  stripped = stripped.replace(/<[^>]+>/g, ' ');

  // Decode a minimal set of HTML entities. Iterate until stable so
  // `&amp;lt;` → `&lt;` → `<` chains don't leave encoded markers in
  // the output that a second user could re-decode later. Same 8-pass
  // DoS cap.
  for (let i = 0; i < 8; i++) {
    const before = stripped;
    stripped = stripped
      .replace(/&nbsp;/gi, ' ')
      .replace(/&amp;/gi, '&')
      .replace(/&lt;/gi, '<')
      .replace(/&gt;/gi, '>')
      .replace(/&quot;/gi, '"')
      .replace(/&#039;/gi, "'")
      .replace(/&#x27;/gi, "'")
      .replace(/&rsquo;/gi, '’')
      .replace(/&lsquo;/gi, '‘');
    if (stripped === before) break;
  }

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

async function readAsyncThresholdBytes(
  client: ReturnType<typeof createServiceClient>,
): Promise<number> {
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
  periodStart: string,
): Promise<{ status: string; used?: number; cap?: number }> {
  const payload = body.payload as unknown as { ocr_page_count?: number };
  const jobPayload: AsyncJobPayload = {
    import_id: body.import_id.toLowerCase(),
    source_type: body.source_type,
    raw_content: rawContent,
    ...(payload.ocr_page_count !== undefined ? { ocr_page_count: payload.ocr_page_count } : {}),
  };
  const { data, error } = await client.rpc('stir_enqueue_recipe_import', {
    p_canonical_user_key: canonicalUserKey,
    p_import_id: body.import_id,
    p_period_start: periodStart,
    p_payload: jobPayload,
  });
  if (error) throw error;
  if (!data || !['queued', 'existing', 'capped', 'not_bootstrapped'].includes(data.status)) {
    throw new Error('unexpected import admission response');
  }
  return data;
}
