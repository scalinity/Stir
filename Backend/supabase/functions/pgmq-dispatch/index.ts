// POST /functions/v1/pgmq-dispatch
// Invoked by pg_cron every 30s (and ops `stir_pgmq_dispatch_trigger_once()`).
//
// Claims up to N pending notification_jobs rows using SELECT ... FOR UPDATE
// SKIP LOCKED, processes each according to its `kind`, and flips state to
// completed|failed. Each tick handles at most CLAIM_LIMIT jobs to bound
// per-invocation runtime within Supabase's Edge Function timeout (150s).
//
// Authorization (SA2-Medium fix, 2026-05-04): `verify_jwt = false` keeps Kong
// out of the path, but the handler now requires an `X-Stir-Cron-Secret` header
// matching `STIR_PGMQ_DISPATCH_SECRET` (constant-time compare). pg_cron sets
// the header via vault-backed config (migration 20260504000001). If the env
// var is unset on the function side (local dev / first deploy), the gate
// degrades to a once-per-isolate warn and accepts the call — matches the
// LOG_IP_SALT pattern. In production the secret MUST be set; the function
// will reject every unauthenticated request once it is.
//
// Supported kinds in step 7:
//   - recipe_import_async: runs gemini-3.1-flash-lite-preview against the
//     queued raw_content, writes result to ai_response_cache keyed on
//     (canonical_user_key, import_id), sends APNs completion push.
//   - push_send: (step 8 placeholder; not triggered in step 7)
//
// Failure handling: attempt_count < 3 → state stays 'pending' (with updated
// scheduled_at back-off); attempt_count == 3 → 'failed' + error_message.

import { z } from 'zod';
import { createServiceClient } from '../_shared/db.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readActivePrompt, renderPrompt } from '../_shared/prompt_versions.ts';
import { GeminiError, geminiGenerate, GeminiModel } from '../_shared/gemini.ts';
import { computeCostUSD } from '../_shared/ai_request_log.ts';
import { recordAIRequest } from '../_shared/ai_observability.ts';
import { writeCache } from '../_shared/idempotency.ts';
import { processPushSend, validatePushEnvironment } from './push_send.ts';

const CLAIM_LIMIT = 10; // one tick handles at most 10 jobs (bumped 3→10 2026-04-23)
const MAX_ATTEMPTS = 3;
const RETRY_BACKOFF_SECONDS = [60, 300, 900]; // 1m, 5m, 15m
const STUCK_JOB_TIMEOUT_MINUTES = 5; // processing → pending re-queue threshold
const RECIPE_IMPORT_FEATURE_KEY = 'recipe_import';
const MODEL = GeminiModel.FlashLite;

// Shared-secret gate (SA2-Medium fix). Read once at module load.
const PGMQ_DISPATCH_SECRET = Deno.env.get('STIR_PGMQ_DISPATCH_SECRET') ?? '';
let warnedMissingSecret = false;

/** Constant-time string compare; both inputs MUST be the same byte length. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  const aBytes = new TextEncoder().encode(a);
  const bBytes = new TextEncoder().encode(b);
  let diff = 0;
  for (let i = 0; i < aBytes.length; i++) diff |= aBytes[i]! ^ bBytes[i]!;
  return diff === 0;
}

// -----------------------------------------------------------------------------
// Recipe-import output schema (copy of recipe-import/index.ts's ImportedRecipeSchema)
// -----------------------------------------------------------------------------

const RECIPE_RESPONSE_SCHEMA: Record<string, unknown> = {
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

// -----------------------------------------------------------------------------
// Types shared with recipe-import/index.ts AsyncJobPayload
// -----------------------------------------------------------------------------

interface RecipeImportAsyncPayload {
  import_id: string;
  source_type: 'url' | 'share_sheet' | 'screenshot_ocr' | 'pasted_text';
  raw_content: string;
  original_url?: string;
  ocr_page_count?: number;
}

// SA1-Medium fix: defense-in-depth schema validation symmetric to push_send.
// The recipe-import endpoint is the only writer today, but any future writer
// (ops script, new feature) bypassing this gate would feed untyped fields
// straight into the Gemini prompt with no signal. UUID/length/enum bounds
// match the recipe-import insert site.
const RecipeImportAsyncPayloadSchema = z.object({
  import_id: z.string().uuid(),
  source_type: z.enum(['url', 'share_sheet', 'screenshot_ocr', 'pasted_text']),
  raw_content: z.string().min(1).max(120_000),
  original_url: z.string().url().max(2048).optional(),
  ocr_page_count: z.number().int().min(0).max(50).optional(),
});

interface ClaimedJob {
  id: string;
  canonical_user_key: string;
  kind: 'recipe_import_async' | 'push_send';
  state: 'pending' | 'processing' | 'completed' | 'failed';
  attempt_count: number;
  payload_json: unknown;
}

// -----------------------------------------------------------------------------
// Entry
// -----------------------------------------------------------------------------

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ops/pgmq-dispatch';
  const log = await createLogger(requestId, endpoint);

  if (req.method !== 'POST' && req.method !== 'GET') {
    return jsonError(
      ErrorCode.METHOD_NOT_ALLOWED_01,
      405,
      { allowed: ['POST', 'GET'] },
      requestId,
    );
  }

  // SA2-Medium gate. If the env var is configured, require a matching header.
  // If unset, log a once-per-isolate warning and accept (dev/transition mode).
  if (PGMQ_DISPATCH_SECRET) {
    const provided = req.headers.get('x-stir-cron-secret') ?? '';
    if (!timingSafeEqual(provided, PGMQ_DISPATCH_SECRET)) {
      log.warn('pgmq_dispatch_secret_mismatch', {
        has_header: provided.length > 0,
      });
      return jsonError(
        ErrorCode.AUTH_01,
        401,
        {
          reason: 'signature_invalid' as never,
          message: 'Missing or invalid pgmq-dispatch shared secret.',
        },
        requestId,
      );
    }
  } else if (!warnedMissingSecret) {
    warnedMissingSecret = true;
    console.warn(
      'pgmq-dispatch: STIR_PGMQ_DISPATCH_SECRET unset — accepting unauthenticated invocations. Set the secret before exposing this function publicly.',
    );
  }

  const started = performance.now();
  const client = createServiceClient();

  // ---- Reclaim sweep: flip stuck 'processing' rows back to 'pending'.
  // If a prior tick crashed (OOM, 150s timeout, pod restart) mid-batch,
  // rows stay wedged in 'processing' forever. Rare in practice but
  // essential for queue liveness (CA2-4).
  //
  // Two-part sweep (review C11 fix), now extracted to a SQL stored proc
  // (SCA-125) so direct-DB tests can exercise the contract without going
  // through the edge-runtime HTTP path:
  //   Part A: attempt_count < MAX_ATTEMPTS → back to 'pending' for retry.
  //   Part B: attempt_count >= MAX_ATTEMPTS → dead-letter to 'failed'.
  //           Pre-fix, these rows were permanently wedged because the
  //           reclaim filter excluded them ("NOT attempt_count < MAX").
  //           They had burned their retry budget before the crash that
  //           left them in processing; the correct posture is terminal
  //           failure, not another retry attempt.
  try {
    const { data: sweepResult, error: sweepErr } = await client.rpc('stir_pgmq_reclaim_sweep', {
      p_stale_minutes: STUCK_JOB_TIMEOUT_MINUTES,
      p_max_attempts: MAX_ATTEMPTS,
    });
    if (sweepErr) {
      log.warn('reclaim_sweep_failed', { err: sweepErr.message });
    } else if (sweepResult) {
      const summary = sweepResult as {
        reclaimed_count?: number;
        dead_lettered_count?: number;
      };
      if ((summary.reclaimed_count ?? 0) > 0) {
        log.info('stuck_jobs_reclaimed', { count: summary.reclaimed_count });
      }
      if ((summary.dead_lettered_count ?? 0) > 0) {
        log.warn('stuck_jobs_dead_lettered', { count: summary.dead_lettered_count });
      }
    }
  } catch (err) {
    // Never fatal — the claim below still runs.
    log.warn('reclaim_unexpected', { err: err instanceof Error ? err.message : String(err) });
  }

  // ---- Claim up to CLAIM_LIMIT pending jobs atomically.
  const { data: claimedRows, error: claimErr } = await client.rpc(
    'stir_claim_pending_jobs',
    { p_limit: CLAIM_LIMIT },
  );
  if (claimErr) {
    log.error('claim_failed', claimErr);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }

  const claimed: ClaimedJob[] = Array.isArray(claimedRows) ? claimedRows : [];
  if (claimed.length === 0) {
    return jsonOk({ claimed: 0, processed: 0, elapsed_ms: 0 }, requestId);
  }

  log.info('claimed_jobs', { count: claimed.length });

  const results: Array<{ job_id: string; kind: string; status: 'completed' | 'failed' | 'retry' }> =
    [];

  for (const job of claimed) {
    try {
      if (job.kind === 'recipe_import_async') {
        await processRecipeImportAsync(client, job, log);
        results.push({ job_id: job.id, kind: job.kind, status: 'completed' });
      } else if (job.kind === 'push_send') {
        await processPushSend(client, job, log);
        results.push({ job_id: job.id, kind: job.kind, status: 'completed' });
      } else {
        await markJobFailed(client, job.id, `unknown kind: ${String(job.kind)}`);
        results.push({ job_id: job.id, kind: job.kind, status: 'failed' });
      }
    } catch (err) {
      const nextAttempt = job.attempt_count + 1;
      const msg = err instanceof Error ? err.message : String(err);
      if (nextAttempt >= MAX_ATTEMPTS) {
        await markJobFailed(client, job.id, msg.slice(0, 1024));
        results.push({ job_id: job.id, kind: job.kind, status: 'failed' });
        log.warn('job_failed_terminal', { job_id: job.id, attempt: nextAttempt, err: msg });
      } else {
        const backoff = RETRY_BACKOFF_SECONDS[job.attempt_count] ??
          RETRY_BACKOFF_SECONDS[RETRY_BACKOFF_SECONDS.length - 1]!;
        await scheduleJobRetry(client, job.id, backoff, msg.slice(0, 1024));
        results.push({ job_id: job.id, kind: job.kind, status: 'retry' });
        log.warn('job_failed_retry', {
          job_id: job.id,
          attempt: nextAttempt,
          backoff_sec: backoff,
          err: msg,
        });
      }
    }
  }

  const elapsedMs = Math.round(performance.now() - started);
  log.info('tick_complete', {
    claimed: claimed.length,
    processed: results.length,
    elapsed_ms: elapsedMs,
  });

  return jsonOk({
    claimed: claimed.length,
    processed: results.length,
    results,
    elapsed_ms: elapsedMs,
  }, requestId);
});

// -----------------------------------------------------------------------------
// recipe_import_async processor
// -----------------------------------------------------------------------------

async function processRecipeImportAsync(
  client: ReturnType<typeof createServiceClient>,
  job: ClaimedJob,
  log: Awaited<ReturnType<typeof createLogger>>,
): Promise<void> {
  // SA1-Medium fix: Zod-validate the payload before it reaches the Gemini
  // prompt. Catches a malformed row inserted by a future writer; surfaces
  // a typed error in logs instead of crashing inside renderPrompt.
  const parsed = RecipeImportAsyncPayloadSchema.safeParse(job.payload_json);
  if (!parsed.success) {
    log.warn('recipe_import_async_payload_invalid', {
      job_id: job.id,
      issues: parsed.error.issues.map((i) => ({ path: i.path.join('.'), code: i.code })),
    });
    throw new Error(
      'invalid recipe_import_async payload (see recipe_import_async_payload_invalid log)',
    );
  }
  const payload: RecipeImportAsyncPayload = parsed.data;

  const activePrompt = await readActivePrompt(client, RECIPE_IMPORT_FEATURE_KEY);
  if (!activePrompt) {
    throw new Error(`no active ${RECIPE_IMPORT_FEATURE_KEY} prompt`);
  }

  const rendered = renderPrompt(
    activePrompt.template_blob,
    { source_type: payload.source_type, raw_content: payload.raw_content },
    { untrusted: new Set(['raw_content']) },
  );

  let recipe: z.infer<typeof ImportedRecipeSchema> | null = null;
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
        responseSchema: RECIPE_RESPONSE_SCHEMA,
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
        if (attempt === 0) {
          retryCount++;
          continue;
        }
      }
    } catch (err) {
      lastErr = err;
      if (err instanceof GeminiError && err.status >= 500) {
        if (attempt === 0) {
          retryCount++;
          continue;
        }
      } else {
        break;
      }
    }
  }

  const costUsd = computeCostUSD(MODEL, {
    textInputTokens: totalInputTokens,
    textOutputTokens: totalOutputTokens,
  });

  const userLog = await createLogger(
    job.id,
    '/v1/ops/pgmq-dispatch:recipe_import',
    job.canonical_user_key,
  );

  recordAIRequest(
    client,
    userLog,
    {
      request_id: payload.import_id,
      canonical_user_key: job.canonical_user_key,
      feature_key: RECIPE_IMPORT_FEATURE_KEY,
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
      trace_id: payload.import_id,
      span_name: 'recipe_import_async',
      is_error: !recipe,
      // Matches the synchronous recipe-import handler's choice so the
      // PostHog error-rate filter `$ai_is_error = true AND $ai_error =
      // 'IMPORT-01'` sees both paths. Pre-2026-04-24 this field was
      // missing and async import failures dropped out of the filter.
      error_code: !recipe ? ErrorCode.IMPORT_01 : undefined,
    },
  );

  if (!recipe) {
    throw new Error(
      `recipe normalization failed: ${
        lastErr instanceof Error ? lastErr.message : String(lastErr)
      }`,
    );
  }

  const responseBody = {
    import_id: payload.import_id,
    status: 'completed' as const,
    recipe,
    retry_count: retryCount,
    prompt_version: activePrompt.version,
    async_job_id: job.id,
  };

  // Write to ai_response_cache — the iOS client's next POST with the same
  // import_id will hit this cache and return instantly.
  await writeCache(
    client,
    job.canonical_user_key,
    payload.import_id,
    RECIPE_IMPORT_FEATURE_KEY,
    200,
    responseBody,
  );

  // Mark job completed.
  const { error: markErr } = await client
    .from('notification_jobs')
    .update({
      state: 'completed',
      processed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', job.id);
  if (markErr) {
    log.warn('job_mark_complete_failed', { job_id: job.id, err: String(markErr) });
    // Non-fatal — next tick will see state='processing' and may re-try. The
    // idempotency cache write above means the user gets the correct result
    // regardless.
  }

  // APNs push: check whether this install has opted into import_completion.
  await maybeSendImportCompletionPush(client, job.canonical_user_key, payload.import_id, log);
}

// -----------------------------------------------------------------------------
// APNs push (import completion)
// -----------------------------------------------------------------------------
//
// Step 7 includes the control plane (read prefs, decide to send) but defers
// the actual APNs send implementation to step 8's push-scheduler function.
// That keeps the dispatch path testable now without pulling in APNs signing
// or the jose JWT-for-APNs dance. In step 7 we simply log what WOULD have
// been sent and insert a `push_send` notification_jobs row as a TODO; step 8
// picks those up.

async function maybeSendImportCompletionPush(
  client: ReturnType<typeof createServiceClient>,
  canonicalUserKey: string,
  importId: string,
  log: Awaited<ReturnType<typeof createLogger>>,
): Promise<void> {
  const { data: installRow, error } = await client
    .from('device_installations')
    .select('push_token, apns_environment, notifications_enabled, notification_prefs_json')
    .eq('canonical_user_key', canonicalUserKey)
    .not('push_token', 'is', null)
    .order('last_seen_at', { ascending: false })
    .limit(1)
    .maybeSingle<{
      push_token: string | null;
      apns_environment: string | null;
      notifications_enabled: boolean | null;
      notification_prefs_json: { import_completion?: boolean } | null;
    }>();
  if (error || !installRow) {
    // SA3-M1 (CWE-200): never emit raw canonical_user_key (or partial
    // prefix). The log line's `request_id` + `endpoint` make it
    // locatable; the per-user join is via the canonical_key_hash field
    // that createLogger attaches automatically when the user-scoped
    // logger is in use. Don't add a `_hint` field.
    log.info('no_push_install_for_user');
    return;
  }
  if (
    installRow.notifications_enabled !== true ||
    installRow.notification_prefs_json?.import_completion !== true
  ) {
    log.info('push_opted_out', { category: 'import_completion' });
    return;
  }
  // SCA-296 C1: PushSendPayloadSchema.environment is z.enum(['production',
  // 'sandbox']) — a null/unexpected apns_environment passes the enqueue
  // (notification_jobs.payload_json is jsonb, no shape check) but burns
  // MAX_ATTEMPTS=3 attempts inside processPushSend's Zod validation and
  // dead-letters the row. Net: a real user push silently dropped because
  // a column we control was never populated. Guard at enqueue time.
  const env = validatePushEnvironment(installRow.apns_environment);
  if (!env) {
    log.warn('push_env_missing', {
      category: 'import_completion',
      apns_environment: installRow.apns_environment,
    });
    return;
  }
  // Queue the APNs send as its own job (step 8 will implement the sender).
  const { error: insErr } = await client
    .from('notification_jobs')
    .insert({
      canonical_user_key: canonicalUserKey,
      kind: 'push_send',
      state: 'pending',
      payload_json: {
        template: 'import_completion',
        title: 'Recipe ready',
        body: 'Your imported recipe is ready to cook.',
        deep_link: `stir://import/${importId}`,
        apns_token: installRow.push_token,
        environment: env,
      },
    });
  if (insErr) {
    log.warn('push_job_insert_failed', { err: String(insErr) });
  }
}

// SCA-296 C1: narrow nullable apns_environment to the z.enum the downstream
// PushSendPayloadSchema accepts. Returns null if the value isn't a valid
// APNs environment so callers can skip enqueue + log a typed warning
// instead of poisoning notification_jobs with a row that will burn
// MAX_ATTEMPTS retries before dead-lettering. Kept inline to this module
// (not pushed to _shared/) because the same shape lives in
// revenuecat-webhook and the two call sites differ enough on logging
// context that a shared helper would obscure the intent — duplicate the
// 4-line guard at each site when the second one lands.
// (helper relocated to ./push_send.ts so tests can import without
// triggering the top-level Deno.serve in this module.)

// -----------------------------------------------------------------------------
// Job state helpers
// -----------------------------------------------------------------------------

async function markJobFailed(
  client: ReturnType<typeof createServiceClient>,
  jobId: string,
  errorMessage: string,
): Promise<void> {
  await client
    .from('notification_jobs')
    .update({
      state: 'failed',
      processed_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
      error_message: errorMessage,
    })
    .eq('id', jobId);
}

async function scheduleJobRetry(
  client: ReturnType<typeof createServiceClient>,
  jobId: string,
  backoffSeconds: number,
  errorMessage: string,
): Promise<void> {
  const retryAt = new Date(Date.now() + backoffSeconds * 1000).toISOString();
  await client
    .from('notification_jobs')
    .update({
      state: 'pending',
      scheduled_at: retryAt,
      updated_at: new Date().toISOString(),
      error_message: errorMessage,
    })
    .eq('id', jobId);
}

// -----------------------------------------------------------------------------
// push_send processor (step 8 — reactivation + import_completion pushes)
// -----------------------------------------------------------------------------
//
// Extracted to ./push_send.ts (SCA-115) so integration tests can call
// processPushSend directly with a mock APNs sender, without triggering
// Deno.serve() via this module's top-level. Behavior is unchanged.
