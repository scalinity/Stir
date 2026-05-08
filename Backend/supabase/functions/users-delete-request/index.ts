// POST /functions/v1/users-delete-request
// Logical endpoint: POST /v1/users/delete-request (SCA-61, spec §7.2)
//
// Idempotent insert into deletion_requests on (canonical_user_key).
// Returns the existing row id when a non-terminal request already
// exists for the user, or creates a new pending row when not.
//
// Privacy contract: this endpoint accepts the request without
// requiring proof-of-intent beyond the session JWT itself. iOS
// surfaces a two-step type-to-confirm UI before calling — server-side
// rate limit at 1/hour/user prevents accidental flood from a buggy
// client.
//
// Compliance: per Privacy Policy §7.2, the 30-day fulfillment SLA
// starts at requested_at. Ops triage on state=failed kicks in at
// 7-day-old pending → 24-hour-old failed escalation. This handler
// only enqueues; fulfillment is downstream (pgmq-dispatch consumer +
// ops-admin approval flow).

import { z, ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { hashCanonicalKey } from '../_shared/hashing.ts';
import { readAppUser } from '../_shared/identity.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { capturePosthogEvent } from '../_shared/posthog.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
} from '../_shared/rate_limiter.ts';

// Empty body — auth gates the request.
const RequestSchema = z.object({}).strict();

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/users/delete-request';
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
    return jsonError(ErrorCode.INTERNAL_01, 500, undefined, requestId);
  }
  const userLog = await createLogger(requestId, endpoint, claims.canonical_user_key);

  // ---- Body (optional / empty)
  try {
    const raw = await req.text();
    if (raw.length > 0) {
      RequestSchema.parse(JSON.parse(raw));
    }
  } catch (err) {
    if (err instanceof ZodError) {
      return jsonError(
        ErrorCode.VAL_01,
        400,
        { message: 'Request body must be empty or {}.', field_errors: [] },
        requestId,
      );
    }
    return jsonError(
      ErrorCode.VAL_01,
      400,
      { message: 'Request body is not valid JSON.', field_errors: [] },
      requestId,
    );
  }

  const client = createServiceClient();

  // ---- Rate limit (per IP — defense against a runaway client).
  //
  // Fail-open is intentional: if the rate-limiter RPC errors (Postgres
  // sick, rate_limit_buckets table glitch), we proceed into the deletion
  // path rather than blocking a privacy-rights submission. The downstream
  // unique partial index `uq_deletion_requests_in_flight` serializes
  // concurrent submits at the DB layer, and the JWT auth gate above
  // bounds the attack surface to authenticated users — so the worst
  // case from fail-open is one extra row written, not unbounded flood.
  // CR3-02 / CA1-W4 from the multi-agent code review.
  const sourceIP = extractSourceIP(req);
  try {
    const ipRl = await checkAndIncrement(client, 'ip:users_delete_request_hourly', sourceIP);
    if (!ipRl.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:users_delete_request_hourly' });
      return buildRate01Response(
        'ip:users_delete_request_hourly',
        ipRl.retry_after_seconds,
        ipRl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    // Fail-open per the comment block above. Log at error so the
    // dashboard surfaces RPC-level rate-limiter failures.
    userLog.error('rate_limiter_failed', err);
  }

  // ---- User guard
  const userRow = await readAppUser(client, claims.canonical_user_key);
  if (!userRow) {
    userLog.warn('user_row_missing');
    return jsonError(ErrorCode.AUTH_01, 401, {
      message: 'User not found; re-bootstrap.',
      reason: 'user_stale',
    }, requestId);
  }

  // ---- Idempotent insert: return existing pending/approved/processing row.
  //
  // CA1-01: include `failed` in the existing-row probe so a user who
  // re-submits after a fulfillment-worker failure gets back the prior
  // failure_reason + preserves the original SLA clock (requested_at)
  // instead of accumulating a duplicate audit row. Admins still see the
  // failed history in `deletion_requests.list` ordered by requested_at
  // DESC.
  const userHash = await hashCanonicalKey(claims.canonical_user_key);
  const { data: existing, error: existingErr } = await client
    .from('deletion_requests')
    .select('id, state, requested_at, failure_reason')
    .eq('canonical_user_key', claims.canonical_user_key)
    .in('state', ['pending', 'approved', 'processing', 'failed'])
    .order('requested_at', { ascending: false })
    .limit(1)
    .maybeSingle<
      { id: string; state: string; requested_at: string; failure_reason: string | null }
    >();

  if (existingErr) {
    userLog.error('existing_lookup_failed', existingErr);
    return jsonError(ErrorCode.INTERNAL_01, 500, undefined, requestId);
  }

  if (existing) {
    userLog.info('deletion_request_idempotent_hit', {
      id: existing.id,
      state: existing.state,
    });
    return jsonOk(
      {
        deletion_request_id: existing.id,
        state: existing.state,
        requested_at: existing.requested_at,
        failure_reason: existing.failure_reason,
        idempotent: true,
      },
      requestId,
      200,
    );
  }

  const { data: inserted, error: insertErr } = await client
    .from('deletion_requests')
    .insert({
      canonical_user_key: claims.canonical_user_key,
      canonical_user_key_hash: userHash,
      state: 'pending',
    })
    .select('id, state, requested_at')
    .single<{ id: string; state: string; requested_at: string }>();

  if (insertErr || !inserted) {
    // CA2-02: detect the unique-partial-index race. Two concurrent POSTs
    // from the same user can both miss the SELECT-existing probe above
    // (TOCTOU window) and race the INSERT. Postgres returns 23505 →
    // PostgREST surfaces code "23505". Re-fetch the winning row instead
    // of returning 500, which would otherwise trigger iOS retry-up-to-3
    // and burn Sentry noise on a self-healing path.
    if (insertErr && (insertErr as { code?: string }).code === '23505') {
      userLog.info('deletion_request_insert_race_resolved');
      const { data: winning, error: winningErr } = await client
        .from('deletion_requests')
        .select('id, state, requested_at, failure_reason')
        .eq('canonical_user_key', claims.canonical_user_key)
        .in('state', ['pending', 'approved', 'processing'])
        .maybeSingle<
          { id: string; state: string; requested_at: string; failure_reason: string | null }
        >();

      if (winning && !winningErr) {
        return jsonOk(
          {
            deletion_request_id: winning.id,
            state: winning.state,
            requested_at: winning.requested_at,
            failure_reason: winning.failure_reason,
            idempotent: true,
          },
          requestId,
          200,
        );
      }
      // Race-recovery lookup itself failed — fall through to 500.
      userLog.error('deletion_request_race_recovery_failed', winningErr);
    }
    userLog.error('deletion_request_insert_failed', insertErr);
    return jsonError(ErrorCode.INTERNAL_01, 500, undefined, requestId);
  }

  userLog.info('deletion_request_created', {
    id: inserted.id,
    state: inserted.state,
  });

  // PostHog: identity-funnel + admin-dashboard signal. Does not include
  // any PII — distinct_id is the hashed user key (matches SCA-62
  // session-bootstrap pattern).
  try {
    capturePosthogEvent(userLog, {
      event: 'deletion_request_submitted',
      distinctId: userHash,
      properties: {
        request_id: requestId,
        actor_id: 'user',
        deletion_request_id: inserted.id,
      },
    });
  } catch (telemetryErr) {
    userLog.warn('posthog_emit_failed', {
      event: 'deletion_request_submitted',
      err: telemetryErr instanceof Error ? telemetryErr.message : String(telemetryErr),
    });
  }

  return jsonOk(
    {
      deletion_request_id: inserted.id,
      state: inserted.state,
      requested_at: inserted.requested_at,
      idempotent: false,
    },
    requestId,
    201,
  );
});
