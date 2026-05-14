// POST /functions/v1/push-register
// Logical endpoint: POST /v1/push/register (spec §3).
//
// Upserts APNs token + notification prefs on the calling install's
// `device_installations` row (keyed on `installation_id` from the
// session JWT). iOS calls:
//   - on first token grant after UNUserNotificationCenter.requestAuthorization
//   - on every prefs-change in Settings → Notifications
//   - on token refresh (apns rotates tokens periodically)
//
// Idempotency: reposts with the same (installation_id, environment,
// apns_token, prefs) are a no-op UPDATE on the matching row. No new
// rows created for duplicate registrations.
//
// SCA-321: pre-fix this selected by `canonical_user_key` ordered by
// `last_seen_at DESC LIMIT 1`. Multi-install users (one CK identity
// across two iPhones) had Device B's POST clobber whichever row
// `last_seen_at` happened to surface, leaving the other install's
// row with a stale token. Now keyed on `installation_id` (still
// AND-filtered by `canonical_user_key` as a belt-and-suspenders
// guard against a hypothetical cross-user install_id mint).
//
// Used by:
//   - pgmq-dispatch → APNs send for recipe_import_async completion (step 7)
//   - step 8 reactivation campaigns (reactivation_notification_opened)
//   - step 5 trial reminder push (wired via RC entitlement webhook)

import { ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { followMergedInto, readAppUser } from '../_shared/identity.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { PushRegisterRequest, zodToFieldErrors } from '../_shared/validation.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
} from '../_shared/rate_limiter.ts';
import { writeAudit } from '../_shared/audit.ts';
import { hashCanonicalKey } from '../_shared/hashing.ts';

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/push/register';
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
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }
  const userLog = await createLogger(requestId, endpoint, claims.canonical_user_key);

  // ---- Body
  let body: PushRegisterRequest;
  try {
    const raw = await req.text();
    body = PushRegisterRequest.parse(JSON.parse(raw));
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

  // ---- Rate limit (IP)
  const sourceIP = extractSourceIP(req);
  try {
    const ipRl = await checkAndIncrement(client, 'ip:push_register_hourly', sourceIP);
    if (!ipRl.allowed) {
      userLog.warn('rate_limited', { scope: 'ip:push_register_hourly' });
      return buildRate01Response(
        'ip:push_register_hourly',
        ipRl.retry_after_seconds,
        ipRl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
  }

  // ---- User guard
  const userRow = await readAppUser(client, claims.canonical_user_key);
  if (!userRow) {
    userLog.warn('user_row_missing');
    // SCA-381: audit a user_stale rejection. JWT verified but the
    // claim's canonical_user_key no longer resolves to a row — could
    // be (a) row hard-deleted (shouldn't happen; status='banned' is
    // the soft-delete path), (b) identity-merge in flight where the
    // alias-forward landed but the JWT was minted seconds before,
    // (c) test fixture cleanup raced with a real session. SREs grep
    // `action='auth_user_stale'` to scope (a) vs (b)/(c) noise.
    // SCA-392: `audit_log.actor_id` is `UUID REFERENCES auth.users(id)`;
    // the canonical_user_key shapes (`ck:<recordName>` /
    // `install:<uuid>`) are NOT UUIDs and Postgres rejected every
    // prior INSERT with `22P02 invalid input syntax for type uuid`,
    // silently swallowed by writeAudit's non-fatal posture — every
    // row dropped from SCA-381 ship to merge. Hash the key into
    // `after_json` (matches the _shared/hashing.ts log invariant)
    // and pass null for `actor_id` (matches every other writeAudit
    // call site in the codebase: real auth.users.id UUID or null).
    await writeAudit(client, userLog, {
      actor_id: null,
      actor_email: null,
      action: 'auth_user_stale',
      target_table: 'app_users',
      target_id: claims.canonical_user_key,
      after: {
        endpoint: '/v1/push/register',
        reason: 'user_stale',
        canonical_user_key_hash: await hashCanonicalKey(claims.canonical_user_key),
      },
      request_id: requestId,
    });
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

  // ---- Resolve the post-alias canonical_user_key. SCA-353: bootstrap's
  // identity-merge transaction (20260419000012_alias_forward_advisory_lock)
  // rewrites `device_installations.canonical_user_key` from
  // `install:<uuid>` to `ck:<userRecordName>` when CK identity arrives.
  // The JWT minted BEFORE that flip still carries the install:* claim;
  // its `verifySessionJWT` check passes until expiry (~24h). Filtering
  // the row by the raw claim key would miss the row that's now keyed
  // on ck:* and emit a misleading VAL-01 "Call bootstrap first" even
  // though bootstrap already ran. Chase the merge chain (matches the
  // _shared/auth.ts:191-226 reauth-check pattern); use the terminal
  // row's key for the AND-filter.
  const targetUser = await followMergedInto(client, userRow);
  const resolvedKey = targetUser.canonical_user_key;

  // ---- Upsert: target the calling install's device_installation row
  // and attach/update the apns token + prefs. SCA-321: previously this
  // selected by `canonical_user_key + ORDER BY last_seen_at DESC LIMIT
  // 1`, which clobbered cross-device tokens for multi-install users
  // (CK identity migrates across two iPhones; Device B's POST would
  // overwrite Device A's row by `last_seen_at`, leaving Device A with
  // a stale token but pgmq-dispatch reading it as current). The JWT
  // already carries the calling install's `installation_id`; key the
  // SELECT (and the UPDATE) on it directly so each install owns its
  // own device_installations row.
  // SCA-381: also fetch the prior `apns_environment` so an env flip
  // (sandbox → production or vice versa on the SAME install) writes
  // an audit_log row. Env flips are unusual — the legitimate path is
  // a TestFlight install graduating to App Store, but a sustained
  // rate of unintended flips signals a misconfigured Debug→Release
  // build path on prod devices.
  const { data: installRow, error: installReadErr } = await client
    .from('device_installations')
    .select('installation_id, push_token, notifications_enabled, apns_environment')
    .eq('installation_id', claims.installation_id)
    .eq('canonical_user_key', resolvedKey)
    .maybeSingle<{
      installation_id: string;
      push_token: string | null;
      notifications_enabled: boolean | null;
      apns_environment: string | null;
    }>();
  if (installReadErr) {
    userLog.error('install_read_failed', installReadErr);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }
  if (!installRow) {
    userLog.warn('no_install_row');
    return jsonError(
      ErrorCode.VAL_01,
      400,
      {
        message: 'No device_installation row. Call /v1/session/bootstrap first.',
        field_errors: [{ field: 'session', issue: 'device_installations row missing' }],
      },
      requestId,
    );
  }

  const { error: updErr } = await client
    .from('device_installations')
    .update({
      push_token: body.apns_token,
      apns_environment: body.environment,
      // Derived from submitted prefs — true iff at least one category
      // is enabled. Hardcoding `true` here (pre-fix) silently clobbered
      // user opt-outs for every future push path reading this column
      // (step-8 reactivation campaigns, ops dashboards). notification_
      // prefs_json remains the per-category source of truth; the
      // boolean is a cheap "any push at all?" index.
      // SCA-322: derive via `Object.values().some(Boolean)` so adding
      // a new category to the schema auto-includes it instead of
      // silently OR-rotting against the old enum.
      notifications_enabled: Object.values(body.notification_prefs).some(Boolean),
      notification_prefs_json: body.notification_prefs,
      last_seen_at: new Date().toISOString(),
    })
    .eq('installation_id', installRow.installation_id);
  if (updErr) {
    userLog.error('install_update_failed', updErr);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }

  // SCA-381: env flip on the SAME install is unusual — TestFlight →
  // App Store graduation is the legitimate case, but a sustained
  // rate of unintended flips signals a misconfigured Debug→Release
  // build path on prod devices. Audit row is permanent (counts only
  // — canonical_user_key hashed, no token/pref content) so SREs can
  // grep `apns_environment_flipped` and join with
  // `device_installations` to understand cohort behavior.
  // SCA-392: see auth_user_stale call site above for the actor_id
  // type-mismatch fix. Same shape: null actor_id + hashed key in
  // `after_json` so the row actually lands.
  if (
    installRow.apns_environment !== null &&
    installRow.apns_environment !== body.environment
  ) {
    await writeAudit(client, userLog, {
      actor_id: null,
      actor_email: null,
      action: 'apns_environment_flipped',
      target_table: 'device_installations',
      target_id: installRow.installation_id,
      before: { apns_environment: installRow.apns_environment },
      after: {
        apns_environment: body.environment,
        canonical_user_key_hash: await hashCanonicalKey(claims.canonical_user_key),
      },
      request_id: requestId,
    });
  }

  userLog.info('push_registered', {
    installation_id: installRow.installation_id,
    environment: body.environment,
    token_rotated: installRow.push_token !== body.apns_token,
    prefs: body.notification_prefs,
  });

  return jsonOk(
    { installation_id: installRow.installation_id, environment: body.environment },
    requestId,
    200,
  );
});
