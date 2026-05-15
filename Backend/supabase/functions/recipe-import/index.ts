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
import { GeminiError, geminiGenerate, GeminiModel } from '../_shared/gemini.ts';
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
import { readCache, responseFromCache, writeCache } from '../_shared/idempotency.ts';
import { incrementQuotaAtomic, refundQuota } from '../_shared/quota.ts';

const FEATURE_KEY = 'recipe_import';
const MODEL = GeminiModel.FlashLite;
const DEFAULT_ASYNC_THRESHOLD_BYTES = 8192;
const URL_FETCH_TIMEOUT_MS = 10_000;
const URL_FETCH_MAX_BYTES = 2 * 1024 * 1024; // 2 MB
const URL_FETCH_USER_AGENT = 'StirBot/1.0 (+https://getstir.app)';

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
      return jsonError(ErrorCode.AUTH_01, 401, {
        message: 'Session expired or missing.',
        reason: err.reason,
      }, requestId);
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
      {
        message: 'Request body is not valid JSON.',
        field_errors: [{ field: '<root>', issue: 'invalid JSON' }],
      },
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
    userLog.warn('cache_read_failed', { err: sanitizeErrorForLog(err) });
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
    await refundQuota(
      client,
      userLog,
      claims.canonical_user_key,
      'recipe_import',
      consumedPeriodStart,
    );
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
      prompt_version: '1.0.0', // best-effort; worker records real version on completion
      async_job_id: jobId,
    };
    userLog.info('queued_async', { job_id: jobId, raw_bytes: rawBytes });
    return jsonOk(queuedBody, requestId, 202);
  }

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

async function fetchUrlText(url: string): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), URL_FETCH_TIMEOUT_MS);
  try {
    // Walk redirects manually — `redirect: 'follow'` would skip
    // per-hop SSRF re-validation and let a Location: http://10.0.0.1/
    // (or a DNS rebind on the second hop) bypass the initial guard.
    let currentUrl = url;
    let response: Response | null = null;
    for (let hop = 0; hop <= URL_FETCH_MAX_REDIRECTS; hop++) {
      await assertUrlIsPublic(currentUrl);
      const r = await fetch(currentUrl, {
        method: 'GET',
        redirect: 'manual',
        signal: controller.signal,
        headers: {
          'user-agent': URL_FETCH_USER_AGENT,
          'accept': 'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
          'accept-language': 'en-US,en;q=0.9',
        },
      });
      if (r.status >= 300 && r.status < 400) {
        const location = r.headers.get('location');
        if (!location) {
          throw new FetchFailure(`redirect ${r.status} with no location`);
        }
        // Resolve relative Locations against the current URL.
        currentUrl = new URL(location, currentUrl).toString();
        // Drain + close the redirect response so the connection can
        // be reused.
        await r.body?.cancel();
        continue;
      }
      response = r;
      break;
    }
    if (!response) {
      throw new FetchFailure(`too many redirects (>${URL_FETCH_MAX_REDIRECTS})`);
    }
    if (!response.ok) {
      throw new FetchFailure(`upstream ${response.status}`);
    }
    const contentType = response.headers.get('content-type') ?? '';
    if (
      !contentType.includes('text/') && !contentType.includes('json') &&
      !contentType.includes('xml')
    ) {
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
    if ((err as Error).name === 'AbortError') {
      throw new FetchFailure(`timeout after ${URL_FETCH_TIMEOUT_MS}ms`);
    }
    throw new FetchFailure(`fetch failed: ${(err as Error).message}`);
  } finally {
    clearTimeout(timeout);
  }
}

const URL_FETCH_MAX_REDIRECTS = 5;

/**
 * SSRF guard — blocks anything that isn't a public http(s) URL.
 *
 * Checks:
 *   1. Scheme allow-list: http/https only.
 *   2. No userinfo (prevents `http://attacker@target/` smuggling).
 *   3. Hostname resolves to a public IP — blocks RFC-1918, loopback,
 *      link-local (169.254 = AWS IMDS, GCP metadata), CGNAT, multicast,
 *      IPv4-mapped IPv6, ULA. Runs on EVERY hop via `redirect: 'manual'`,
 *      so a DNS rebind or Location redirect can't bypass the initial
 *      check. (CWE-918, CWE-601.)
 */
async function assertUrlIsPublic(raw: string): Promise<void> {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new FetchFailure('invalid url');
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new FetchFailure(`scheme not allowed: ${parsed.protocol}`);
  }
  if (parsed.username || parsed.password) {
    throw new FetchFailure('userinfo in url not allowed');
  }
  const hostname = parsed.hostname.toLowerCase();
  if (!hostname) {
    throw new FetchFailure('empty hostname');
  }
  // Reject bracketed IPv6 literals + localhost aliases eagerly.
  if (hostname === 'localhost' || hostname === 'ip6-localhost' || hostname === 'ip6-loopback') {
    throw new FetchFailure(`blocked hostname: ${hostname}`);
  }
  // Resolve A + AAAA records. An unresolvable host is harmless-to-us
  // (fetch would error anyway), but we treat it as a block so the
  // error is typed + logged here rather than surfacing as a generic
  // fetch failure.
  const ips = await resolveAllIps(hostname);
  if (ips.length === 0) {
    throw new FetchFailure(`hostname did not resolve: ${hostname}`);
  }
  for (const ip of ips) {
    if (isPrivateIp(ip)) {
      throw new FetchFailure(`blocked private ip: ${ip}`);
    }
  }
}

async function resolveAllIps(hostname: string): Promise<string[]> {
  // If the hostname is already an IP literal, Deno.resolveDns throws;
  // short-circuit by returning it directly so the range check runs.
  if (isIpLiteral(hostname)) return [hostname];
  const out: string[] = [];
  for (const type of ['A', 'AAAA'] as const) {
    try {
      const records = await Deno.resolveDns(hostname, type);
      out.push(...records);
    } catch {
      // Record type absent is normal; keep the other type's records.
    }
  }
  return out;
}

function isIpLiteral(s: string): boolean {
  // IPv4 dotted-quad or IPv6 (including brackets).
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(s)) return true;
  const stripped = s.startsWith('[') && s.endsWith(']') ? s.slice(1, -1) : s;
  return stripped.includes(':');
}

function isPrivateIp(ip: string): boolean {
  // IPv4 dotted-quad — cover loopback, RFC1918, link-local, CGNAT,
  // multicast, class-E, and the any-host 0.0.0.0.
  const v4 = ip.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const [a, b] = v4.slice(1, 3).map((n) => parseInt(n, 10));
    if (a === 10) return true; // 10/8
    if (a === 127) return true; // loopback
    if (a === 0) return true; // 0/8
    if (a === 169 && b === 254) return true; // link-local (IMDS)
    if (a === 172 && b >= 16 && b <= 31) return true; // 172.16/12
    if (a === 192 && b === 168) return true; // 192.168/16
    if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT 100.64/10
    if (a === 192 && b === 0 && v4[3] === '0') return true; // 192.0.0/24 IETF
    if (a === 192 && b === 0 && v4[3] === '2') return true; // 192.0.2/24 TEST-NET-1
    if (a === 198 && (b === 18 || b === 19)) return true; // 198.18/15 benchmark
    if (a === 198 && b === 51) return true; // 198.51.100/24
    if (a === 203 && b === 0) return true; // 203.0.113/24
    if (a >= 224) return true; // 224+ multicast + reserved
    return false;
  }
  // IPv6 — normalize lower + strip zone id. Block loopback (::1), unspec
  // (::), ULA fc00::/7, link-local fe80::/10, multicast ff00::/8, and
  // IPv4-mapped ::ffff:a.b.c.d / IPv4-compat ::a.b.c.d.
  const v6 = ip.toLowerCase().split('%')[0];
  if (v6 === '::1' || v6 === '::') return true;
  if (v6.startsWith('fc') || v6.startsWith('fd')) return true; // ULA fc00::/7
  if (
    v6.startsWith('fe8') || v6.startsWith('fe9') || v6.startsWith('fea') || v6.startsWith('feb')
  ) return true; // fe80::/10
  if (v6.startsWith('ff')) return true; // multicast
  // IPv4-mapped / IPv4-compat: ::ffff:x.y.z.w or ::x.y.z.w — extract the v4 tail.
  const mapped = v6.match(/^::(?:ffff:)?(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (mapped) return isPrivateIp(mapped[1]);
  return false;
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
