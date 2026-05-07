// POST /functions/v1/grocery-generate
// Logical endpoint: POST /v1/ai/grocery-generate (spec §3).
//
// Diffs recipe ingredients against the user's CloudKit pantry snapshot
// (iOS-supplied — backend doesn't mirror user content per §3 invariant)
// and returns a grouped, prioritized grocery list. Unmetered across all
// tiers — cost is logged to ai_request_log but no usage_counter.
//
// Model: gemini-3.1-flash-lite-preview (cheap, p95 <1.5s).
// Output contract: every missing_item carries `priority` per spec §4.17
// (GroceryItem.priority is required); default 'normal' enforced post-model.
//
// Idempotency: source_id = RecipePlan UUID (or CookingSession UUID for
// session-scoped groceries). Same idempotency_cache pattern as other
// /v1/ai/* handlers — 10-min TTL.

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readAppUser } from '../_shared/identity.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiError, geminiGenerate, GeminiModel } from '../_shared/gemini.ts';
import { computeCostUSD } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import { createLogger, requestIdFrom, sanitizeErrorForLog } from '../_shared/logger.ts';
import { GroceryGenerateRequest, zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
} from '../_shared/rate_limiter.ts';
import { readCache, responseFromCache, writeCache } from '../_shared/idempotency.ts';

const FEATURE_KEY = 'grocery_generate';
const MODEL = GeminiModel.FlashLite;

// -----------------------------------------------------------------------------
// Gemini output schema (matches prompt v1.0.0 grocery_generate output)
// -----------------------------------------------------------------------------

const GROCERY_RESPONSE_SCHEMA: Record<string, unknown> = {
  type: 'OBJECT',
  properties: {
    missing_items: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          display_name: { type: 'STRING' },
          amount_text: { type: 'STRING', nullable: true },
          canonical_slug: { type: 'STRING', nullable: true },
          grocery_category: {
            type: 'STRING',
            enum: ['produce', 'dairy', 'meat', 'pantry', 'frozen', 'other'],
          },
          priority: { type: 'STRING', enum: ['normal', 'low', 'high'] },
        },
        required: ['display_name', 'grocery_category', 'priority'],
      },
    },
    already_have: {
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        properties: {
          display_name: { type: 'STRING' },
          canonical_slug: { type: 'STRING', nullable: true },
        },
        required: ['display_name'],
      },
    },
    total_item_count: { type: 'INTEGER' },
  },
  required: ['missing_items', 'already_have', 'total_item_count'],
};

const GroceryItemOutSchema = z.object({
  display_name: z.string().min(1).max(128),
  amount_text: z.string().max(256).nullable().optional(),
  canonical_slug: z.string().max(128).nullable().optional(),
  grocery_category: z.enum(['produce', 'dairy', 'meat', 'pantry', 'frozen', 'other']),
  priority: z.enum(['normal', 'low', 'high']).default('normal'),
});

const GroceryAlreadyHaveSchema = z.object({
  display_name: z.string().min(1).max(128),
  canonical_slug: z.string().max(128).nullable().optional(),
});

const GroceryOutputSchema = z.object({
  missing_items: z.array(GroceryItemOutSchema).max(200),
  already_have: z.array(GroceryAlreadyHaveSchema).max(500),
  total_item_count: z.number().int().min(0),
});

type GroceryOutput = z.infer<typeof GroceryOutputSchema>;

interface GroceryResponse extends GroceryOutput {
  source_id: string;
  source_type: 'recipe' | 'session' | 'leftovers';
  prompt_version: string;
  retry_count: number;
}

// -----------------------------------------------------------------------------
// Entry
// -----------------------------------------------------------------------------

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ai/grocery-generate';
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

  // ---- Auth
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

  // ---- Body
  let body: GroceryGenerateRequest;
  try {
    const raw = await req.text();
    body = GroceryGenerateRequest.parse(JSON.parse(raw));
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

  // ---- Idempotency
  try {
    const hit = await readCache(client, claims.canonical_user_key, body.source_id);
    if (hit) {
      userLog.info('cache_replay', { age_seconds: hit.age_seconds });
      return responseFromCache(hit, requestId);
    }
  } catch (err) {
    userLog.warn('cache_read_failed', { err: sanitizeErrorForLog(err) });
  }

  // ---- Rate limit (IP)
  const sourceIP = extractSourceIP(req);
  try {
    const ipRl = await checkAndIncrement(client, 'ip:grocery_generate_daily', sourceIP);
    if (!ipRl.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:grocery_generate_daily' });
      return buildRate01Response(
        'ip:grocery_generate_daily',
        ipRl.retry_after_seconds,
        ipRl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
  }

  // ---- User status (banned guard; no quota — unmetered feature)
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

  // ---- Prompt
  const activePrompt = await readActivePrompt(client, FEATURE_KEY);
  if (!activePrompt) {
    userLog.error('no_active_prompt', new Error(`no active ${FEATURE_KEY} prompt`));
    return jsonError(ErrorCode.AI_01, 500, undefined, requestId);
  }

  const rendered = renderPrompt(activePrompt.template_blob, {
    ingredients_needed_json: body.ingredients_needed,
    pantry_snapshot_json: body.pantry_snapshot,
  }, {
    // Both keys carry user/model-supplied display names + amount text.
    // Wrap in USER_DATA markers to defeat prompt-injection from a
    // pantry scan ("IGNORE PRIOR INSTRUCTIONS…") or a rogue recipe
    // ingredient. Matches cook-turn + substitution + dinner-solve.
    untrusted: new Set([
      'ingredients_needed_json',
      'pantry_snapshot_json',
    ]),
  });

  // ---- Gemini (one retry on 5xx/schema)
  let output: GroceryOutput | null = null;
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
        userText: 'Generate the grocery diff as structured JSON.',
        thinkingLevel: 'minimal',
        responseSchema: GROCERY_RESPONSE_SCHEMA,
        maxOutputTokens: 2048,
        promptVersion: activePrompt.version,
      });
      totalInputTokens += result.inputTokens;
      totalOutputTokens += result.outputTokens;
      totalLatencyMs += result.latencyMs;
      try {
        output = GroceryOutputSchema.parse(JSON.parse(result.text));
        break;
      } catch (schemaErr) {
        lastErr = schemaErr;
        userLog.warn('grocery_schema_invalid', { attempt: attempt + 1, err: String(schemaErr) });
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

  if (!output) {
    recordAIRequest(
      client,
      userLog,
      {
        request_id: body.source_id,
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
        trace_id: body.source_id,
        span_name: 'grocery_generate',
        is_error: true,
        error_code: ErrorCode.AI_01,
      },
    );
    userLog.error('grocery_failed_upstream', lastErr, { retry_count: retryCount });
    return jsonError(
      ErrorCode.AI_01,
      502,
      { message: 'Grocery generation is temporarily unavailable. Try again shortly.' },
      requestId,
    );
  }

  // ---- Post-model dedupe by canonical_slug or normalized display_name.
  // Merging two entries keeps the HIGHER priority and concatenates amount
  // text ("about X / Y"). Grocery category wins by first-seen since they
  // should match when slugs match.
  const deduped = dedupeMissingItems(output.missing_items);

  const responseBody: GroceryResponse = {
    source_id: body.source_id,
    source_type: body.source_type,
    missing_items: deduped,
    already_have: output.already_have,
    total_item_count: deduped.length,
    prompt_version: activePrompt.version,
    retry_count: retryCount,
  };

  recordAIRequest(
    client,
    userLog,
    {
      request_id: body.source_id,
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
      trace_id: body.source_id,
      span_name: 'grocery_generate',
    },
  );

  try {
    await writeCache(
      client,
      claims.canonical_user_key,
      body.source_id,
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
    missing_count: deduped.length,
    already_have_count: output.already_have.length,
    retry_count: retryCount,
    cost_usd: costUsd,
  });

  return jsonOk(responseBody, requestId, 200);
});

// -----------------------------------------------------------------------------
// Dedupe helper
// -----------------------------------------------------------------------------

type MissingItem = GroceryOutput['missing_items'][number];

function dedupeMissingItems(items: MissingItem[]): MissingItem[] {
  const priorityRank: Record<'high' | 'normal' | 'low', number> = {
    high: 2,
    normal: 1,
    low: 0,
  };
  const out: MissingItem[] = [];
  const indexByKey = new Map<string, number>();

  for (const item of items) {
    const key = item.canonical_slug?.toLowerCase().trim() ||
      normalizeForMatch(item.display_name);
    const existingIdx = indexByKey.get(key);
    if (existingIdx === undefined) {
      indexByKey.set(key, out.length);
      out.push({ ...item, priority: item.priority ?? 'normal' });
      continue;
    }
    const existing = out[existingIdx]!;
    // Merge: keep higher priority, combine amount text.
    if (priorityRank[item.priority ?? 'normal'] > priorityRank[existing.priority]) {
      existing.priority = item.priority ?? 'normal';
    }
    if (item.amount_text && existing.amount_text && item.amount_text !== existing.amount_text) {
      existing.amount_text = `${existing.amount_text} + ${item.amount_text}`;
    } else if (item.amount_text && !existing.amount_text) {
      existing.amount_text = item.amount_text;
    }
    // Prefer a non-null canonical_slug if one side carried it.
    if (!existing.canonical_slug && item.canonical_slug) {
      existing.canonical_slug = item.canonical_slug;
    }
  }
  return out;
}

/** Cheap singular/plural + case normalization for display-name matching. */
function normalizeForMatch(name: string): string {
  const lowered = name.toLowerCase().trim().replace(/\s+/g, ' ');
  if (lowered.endsWith('ies') && lowered.length > 4) {
    return lowered.slice(0, -3) + 'y';
  }
  if (lowered.endsWith('es') && lowered.length > 3 && !lowered.endsWith('ees')) {
    return lowered.slice(0, -2);
  }
  if (lowered.endsWith('s') && lowered.length > 2 && !lowered.endsWith('ss')) {
    return lowered.slice(0, -1);
  }
  return lowered;
}
