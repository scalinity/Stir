// POST /functions/v1/push-register
// Logical endpoint: POST /v1/push/register (spec §3).
//
// Upserts APNs token + notification prefs on the caller's most recent
// `device_installations` row. iOS calls:
//   - on first token grant after UNUserNotificationCenter.requestAuthorization
//   - on every prefs-change in Settings → Notifications
//   - on token refresh (apns rotates tokens periodically)
//
// Idempotency: reposts with the same (canonical_user_key, environment,
// apns_token, prefs) are a no-op UPDATE on the matching row. No new rows
// created for duplicate registrations.
//
// Used by:
//   - pgmq-dispatch → APNs send for recipe_import_async completion (step 7)
//   - step 8 reactivation campaigns (reactivation_notification_opened)
//   - step 5 trial reminder push (wired via RC entitlement webhook)

import { ZodError } from 'zod';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import { createServiceClient } from '../_shared/db.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { readAppUser } from '../_shared/identity.ts';
import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { PushRegisterRequest, zodToFieldErrors } from '../_shared/validation.ts';
import { buildRate01Response, checkAndIncrement, extractSourceIP } from '../_shared/rate_limiter.ts';

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
      return jsonError(ErrorCode.AUTH_01, 401, { message: 'Session expired or missing.', reason: err.reason }, requestId);
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
      { message: 'Request body is not valid JSON.', field_errors: [{ field: '<root>', issue: 'invalid JSON' }] },
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
      return buildRate01Response('ip:push_register_hourly', ipRl.retry_after_seconds, ipRl.reset_at, requestId);
    }
  } catch (err) {
    userLog.error('rate_limiter_failed', err);
  }

  // ---- User guard
  const userRow = await readAppUser(client, claims.canonical_user_key);
  if (!userRow) {
    userLog.warn('user_row_missing');
    return jsonError(ErrorCode.AUTH_01, 401, { message: 'User not found; re-bootstrap.', reason: 'user_stale' }, requestId);
  }
  if (userRow.status === 'banned') {
    return jsonError(ErrorCode.BILL_01, 403, { message: 'Account is not eligible for Stir.', state: 'banned' }, requestId);
  }

  // ---- Upsert: find the most recent device_installation for this user
  // and attach/update the apns token + prefs. If no install row exists
  // (should be impossible after bootstrap), return VAL-01.
  const { data: installRow, error: installReadErr } = await client
    .from('device_installations')
    .select('installation_id, push_token, notifications_enabled')
    .eq('canonical_user_key', claims.canonical_user_key)
    .order('last_seen_at', { ascending: false })
    .limit(1)
    .maybeSingle<{
      installation_id: string;
      push_token: string | null;
      notifications_enabled: boolean | null;
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
      notifications_enabled:
        body.notification_prefs.import_completion ||
        body.notification_prefs.reactivation ||
        body.notification_prefs.trial_reminder,
      notification_prefs_json: body.notification_prefs,
      last_seen_at: new Date().toISOString(),
    })
    .eq('installation_id', installRow.installation_id);
  if (updErr) {
    userLog.error('install_update_failed', updErr);
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
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
