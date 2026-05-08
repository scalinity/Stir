// POST /v1/ops/flag-output — iOS user reports a bad AI output.
//
// Gate: iOS session JWT (verifySessionJWT via _shared/auth.ts). NOT admin.
//
// Request:
//   {
//     "feature_key": "dinner_solve"|"substitution"|"cook_turn"|"recipe_import"
//                    |"pantry_parse"|"grocery_generate"|"cook_mode_realtime",
//     "request_id":  UUID — original AI call id from ai_request_log,
//     "flag_reason": string (1..500 chars) — user-entered,
//     "context_snapshot": object? — feature-specific (recipe_plan_id,
//                                   step_index, etc.); max 4 KiB JSON
//   }
//
// Response:
//   200 { "ok": true, "flagged_output_id": "<uuid>", "dedup": false }
//   200 { "ok": true, "flagged_output_id": "<uuid>", "dedup": true }   // same
//        user already flagged this request_id — return existing id
//   400 VAL-01 on bad shape; 401 AUTH-01 on session; 403 voice/entitlement
//       errors never fire here (session JWT alone is enough)
//
// Dedup: atomic via UNIQUE (canonical_user_key_hash, request_id) + ON
// CONFLICT DO NOTHING (migration 20260424000002). First submission wins;
// concurrent duplicates collapse to a single row with no race window.
// Semantic is "forever" dedup — re-flagging the same AI call after the
// original flag is resolved carries no new information.
//
// Raw input/output snapshot: on insert, we copy ai_request_log cost metadata
// (non-sensitive) + ai_response_cache.response_body (the bad AI output).
// Both are owner-scoped (canonical_user_key) so a leaked request_id can't
// be used to pull another user's metadata into this user's flag record.
// If either lookup fails we still create the flag with NULL raw columns —
// partial is better than none for admin review.

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { hashCanonicalKey } from '../_shared/hashing.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { capturePosthogEvent } from '../_shared/posthog.ts';
import { zodToFieldErrors } from '../_shared/validation.ts';

const CONTEXT_SNAPSHOT_MAX_BYTES = 4096;

const FlagOutputRequest = z.object({
  feature_key: z.enum([
    'dinner_solve',
    'substitution',
    'cook_turn',
    'recipe_import',
    'pantry_parse',
    'grocery_generate',
    'cook_mode_realtime',
  ]),
  request_id: z.string().min(1).max(256),
  flag_reason: z.string().min(1).max(500),
  // W22 (SA1 W1): 4 KiB cap on serialized JSON. Pre-fix there was only a
  // docstring comment claiming "max 4 KiB"; nothing enforced it. Postgres
  // JSONB TOAST accepts up to ~1 GB, so a single abusive row could freeze
  // the admin browser tab on `<pre>{JSON.stringify(...)}</pre>`. Also SQL
  // CHECK added via ALTER TABLE in migration 20260424000005.
  context_snapshot: z
    .record(z.unknown())
    .refine((v) => JSON.stringify(v).length <= CONTEXT_SNAPSHOT_MAX_BYTES, {
      message: `context_snapshot exceeds ${CONTEXT_SNAPSHOT_MAX_BYTES}-byte JSON cap`,
    })
    .optional(),
}).strict();

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/ops/flag-output';
  const log = await createLogger(requestId, endpoint);

  if (req.method !== 'POST') {
    return jsonError(
      ErrorCode.METHOD_NOT_ALLOWED_01,
      405,
      { message: 'Method Not Allowed; use POST.', allowed: ['POST'] },
      requestId,
    );
  }

  // 1. Session JWT.
  let claims;
  try {
    claims = await verifySessionJWT(req);
  } catch (err) {
    if (err instanceof AuthError) {
      log.info('auth_reject', { reason: err.reason });
      return jsonError(
        ErrorCode.AUTH_01,
        401,
        { reason: err.reason, message: err.message },
        requestId,
      );
    }
    log.error('auth_unexpected', err);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }

  // 2. Body validation.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return jsonError(
      ErrorCode.VAL_01,
      400,
      { field_errors: [{ field: 'body', issue: 'request body must be JSON' }] },
      requestId,
    );
  }

  let parsed: z.infer<typeof FlagOutputRequest>;
  try {
    parsed = FlagOutputRequest.parse(body);
  } catch (err) {
    if (err instanceof ZodError) {
      return jsonError(
        ErrorCode.VAL_01,
        400,
        { field_errors: zodToFieldErrors(err) },
        requestId,
      );
    }
    throw err;
  }

  const userHash = await hashCanonicalKey(claims.canonical_user_key);
  const client = createServiceClient();

  // 3. Snapshot raw input/output from ai_request_log + ai_response_cache.
  // Both owner-scoped (SA2 W3): a leaked request_id can't pull another
  // user's metadata. Neither is required for the flag to land — best-effort.
  const [{ data: reqRow }, { data: cacheRow }] = await Promise.all([
    client
      .from('ai_request_log')
      .select(
        'feature_key, model, input_tokens, output_tokens, cost_usd, latency_ms, retry_count, created_at',
      )
      .eq('request_id', parsed.request_id)
      .eq('canonical_user_key', claims.canonical_user_key)
      .maybeSingle(),
    client
      .from('ai_response_cache')
      .select('response_body, status_code')
      .eq('canonical_user_key', claims.canonical_user_key)
      .eq('request_id', parsed.request_id)
      .maybeSingle(),
  ]);

  // 4. Atomic INSERT. UNIQUE(canonical_user_key_hash, request_id) from
  // migration 20260424000002 makes concurrent submissions safe. On
  // conflict, fetch the existing row's id and return dedup=true.
  const { data: inserted, error: insertErr } = await client
    .from('ops_flagged_outputs')
    .insert({
      canonical_user_key_hash: userHash,
      feature_key: parsed.feature_key,
      request_id: parsed.request_id,
      flagged_by: 'user',
      flag_reason: parsed.flag_reason,
      context_snapshot_json: parsed.context_snapshot ?? null,
      raw_input_json: reqRow ?? null,
      raw_output_json: cacheRow?.response_body ?? null,
    })
    .select('id')
    .single();

  if (insertErr?.code === '23505') {
    const { data: existing, error: selectErr } = await client
      .from('ops_flagged_outputs')
      .select('id')
      .eq('canonical_user_key_hash', userHash)
      .eq('request_id', parsed.request_id)
      .single();

    if (selectErr || !existing) {
      log.error('flag_dedup_lookup_failed', selectErr);
      return jsonError(
        ErrorCode.NET_01,
        500,
        { message: 'dedup conflict but existing row unreadable' },
        requestId,
      );
    }

    log.info('flag_dedup_hit', { existing_id: existing.id });
    return jsonOk({ ok: true, flagged_output_id: existing.id, dedup: true }, requestId);
  }

  if (insertErr || !inserted) {
    log.error('flag_insert_failed', insertErr);
    return jsonError(
      ErrorCode.NET_01,
      500,
      { message: insertErr?.message ?? 'insert failed' },
      requestId,
    );
  }

  log.info('flag_created', {
    flagged_output_id: inserted.id,
    feature_key: parsed.feature_key,
    had_cached_output: cacheRow !== null,
  });

  // SCA-62: emit ops_admin.flagged_outputs.created so the flag-rate
  // dashboard tile populates per-feature. Extends the ADR 0027
  // ops_admin.* surface namespace with a user-side counterpart.
  // distinct_id is the user's canonical-key hash (not the admin
  // hash that the ops-admin emits use) so user-cohort funnels work.
  try {
    capturePosthogEvent(log, {
      event: 'ops_admin.flagged_outputs.created',
      distinctId: userHash,
      properties: {
        request_id: requestId,
        actor_id: 'user',
        feature_key: parsed.feature_key,
        flagged_output_id: inserted.id,
        had_cached_output: cacheRow !== null,
      },
    });
  } catch (telemetryErr) {
    log.warn('posthog_emit_failed', {
      event: 'ops_admin.flagged_outputs.created',
      err: telemetryErr instanceof Error ? telemetryErr.message : String(telemetryErr),
    });
  }

  return jsonOk({ ok: true, flagged_output_id: inserted.id, dedup: false }, requestId);
});
