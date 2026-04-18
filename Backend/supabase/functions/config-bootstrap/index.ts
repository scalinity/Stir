// GET /functions/v1/config-bootstrap
// Logical endpoint: GET /v1/config/bootstrap (spec §3).
//
// Auth: session JWT from /v1/session/bootstrap.
//
// Response: bootstrap's shape minus session fields, plus prompts[]:
//   { entitlements: { ... same structure as bootstrap ... },
//     feature_flags: [...],
//     prompts: [{ feature_key, version, provider_model,
//                 schema_hash, is_default, is_enabled }] }
//
// Used by iOS on foreground-after-TTL or entitlement change to refresh
// flags, quotas, prompt versions, and billing_state hints without
// re-minting a JWT. Bootstrap is re-called only when the JWT itself
// expires (24h).

import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import { AuthError, verifySessionJWT } from '../_shared/auth.ts';
import {
  ErrorCode,
  jsonError,
  jsonOk,
} from '../_shared/errors.ts';
import { createServiceClient } from '../_shared/db.ts';
import { readAppUser } from '../_shared/identity.ts';
import {
  computeCurrentPeriodStart,
  readEntitlement,
  readQuotasForWire,
  toIsoDate,
} from '../_shared/entitlements.ts';
import { readFlags } from '../_shared/flags.ts';

interface PromptRow {
  feature_key: string;
  version: string;
  provider_model: string;
  schema_hash: string;
  is_default: boolean;
  is_enabled: boolean;
}

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/config/bootstrap';
  const log = await createLogger(requestId, endpoint);

  if (req.method !== 'GET') {
    log.warn('method_not_allowed', { method: req.method });
    return jsonError(
      ErrorCode.VAL_01,
      405,
      { message: 'Method Not Allowed; use GET.' },
      requestId,
    );
  }

  const started = performance.now();
  log.info('request_start');

  // -----------------------------------------------------------------------
  // 1. Verify JWT
  // -----------------------------------------------------------------------
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

  // -----------------------------------------------------------------------
  // 2. Read entitlement + quotas + flags + prompts
  // -----------------------------------------------------------------------
  const client = createServiceClient();

  try {
    const userRow = await readAppUser(client, claims.canonical_user_key);
    if (!userRow) {
      userLog.warn('user_row_missing');
      return jsonError(
        ErrorCode.AUTH_01,
        401,
        {
          message: 'Session references unknown user; re-bootstrap required.',
          reason: 'signature_invalid',
        },
        requestId,
      );
    }
    if (userRow.status === 'banned') {
      userLog.warn('banned_user_blocked');
      return jsonError(
        ErrorCode.BILL_01,
        403,
        { message: 'Account is not eligible for Stir.', state: 'banned' },
        requestId,
      );
    }

    // merged_into is a TERMINAL user state — the JWT would be stale; re-bootstrap.
    if (userRow.merged_into != null) {
      userLog.info('merged_user_re_bootstrap_required');
      return jsonError(
        ErrorCode.AUTH_01,
        401,
        {
          message: 'User identity was merged; re-bootstrap required.',
          reason: 'signature_invalid',
        },
        requestId,
      );
    }

    const entitlement = await readEntitlement(client, claims.canonical_user_key);
    if (!entitlement) throw new Error('entitlement row missing for authed user');

    const accountCreatedAt = new Date(userRow.created_at);
    const { periodStart, periodEnd } = computeCurrentPeriodStart(accountCreatedAt);

    const [quotas, flags, promptsResult] = await Promise.all([
      readQuotasForWire(client, claims.canonical_user_key, periodStart, periodEnd),
      readFlags(client),
      client
        .from('prompt_versions')
        .select('feature_key, version, provider_model, schema_hash, is_default, is_enabled')
        .eq('is_default', true),
    ]);

    if (promptsResult.error) throw promptsResult.error;
    const prompts = (promptsResult.data ?? []) as PromptRow[];

    const voiceEnabled = entitlement.tier !== 'free';
    const billingRetryBanner = entitlement.billing_state === 'grace';

    const body = {
      entitlements: {
        tier: entitlement.tier,
        billing_state: entitlement.billing_state,
        is_trial: entitlement.is_trial,
        expires_at: entitlement.expires_at,
        voice_enabled: voiceEnabled,
        billing_retry_banner: billingRetryBanner,
        quotas,
      },
      feature_flags: flags,
      prompts,
    };

    userLog.info('request_complete', {
      status: 200,
      latency_ms: Math.round(performance.now() - started),
      tier: entitlement.tier,
      period_end: toIsoDate(periodEnd),
    });
    return jsonOk(body, requestId);
  } catch (err) {
    userLog.error('internal_error', err, {
      latency_ms: Math.round(performance.now() - started),
    });
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }
});
