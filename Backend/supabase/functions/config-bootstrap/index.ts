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
  effectiveTier,
  effectiveVoiceEnabled,
  ensureCurrentPeriodRows,
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
      ErrorCode.METHOD_NOT_ALLOWED_01,
      405,
      { message: 'Method Not Allowed; use GET.', allowed: ['GET'] },
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
      // JWT was validly signed by us but its canonical_user_key no longer
      // resolves — almost always a data-reset during development; in prod
      // implies tampering or an out-of-band row deletion. Either way iOS
      // should silently re-bootstrap. reason=user_stale routes to `info`
      // severity on the log pipeline so this doesn't pollute the Sentry
      // signature_invalid alert channel.
      userLog.info('user_row_missing');
      return jsonError(
        ErrorCode.AUTH_01,
        401,
        {
          message: 'Session references unknown user; re-bootstrap required.',
          reason: 'user_stale',
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

    // merged_into is a TERMINAL user state — the JWT's canonical_user_key
    // was alias-forwarded to another row, so the JWT is valid but points at
    // a stale identity. reason=user_stale: iOS silently re-bootstraps, and
    // the log pipeline keeps this out of the signature_invalid alert channel.
    if (userRow.merged_into != null) {
      userLog.info('merged_user_re_bootstrap_required');
      return jsonError(
        ErrorCode.AUTH_01,
        401,
        {
          message: 'User identity was merged; re-bootstrap required.',
          reason: 'user_stale',
        },
        requestId,
      );
    }

    const entitlement = await readEntitlement(client, claims.canonical_user_key);
    if (!entitlement) throw new Error('entitlement row missing for authed user');

    // `tier` on the wire is the *effective* tier: Free whenever billing_state
    // is 'none' or 'expired'. Voice is gated identically on iOS, but we also
    // need the tier column to match so iOS quota UI + paywall copy reflect
    // the user's actual entitlement, not a stale RevenueCat column.
    const tier = effectiveTier(entitlement);
    const voiceEnabled = effectiveVoiceEnabled(entitlement);
    const billingRetryBanner = entitlement.billing_state === 'grace';

    // Ensure current-period usage_counters exist BEFORE reading quotas. The
    // user's period rolls over on `app_users.created_at` day-of-month; when
    // that boundary is crossed inside the 24h JWT TTL window, this endpoint
    // would otherwise query rows that don't exist yet and return {used:0,
    // cap:0} for every feature — which iOS reads as "quota exhausted" and
    // gates every metered feature. Idempotent upsert, same path as
    // session-bootstrap step 3e.
    const accountCreatedAt = new Date(userRow.created_at);
    const { periodStart, periodEnd } = await ensureCurrentPeriodRows(
      client, claims.canonical_user_key, tier, accountCreatedAt,
    );

    const [quotas, flags, promptsResult] = await Promise.all([
      readQuotasForWire(client, claims.canonical_user_key, periodStart, periodEnd),
      readFlags(client, userLog),
      client
        .from('prompt_versions')
        .select('feature_key, version, provider_model, schema_hash, is_default, is_enabled')
        .eq('is_default', true),
    ]);

    if (promptsResult.error) throw promptsResult.error;
    const prompts = (promptsResult.data ?? []) as PromptRow[];

    // Warn when an expected feature_key has no default prompt row — a bad
    // canary rollout can leave a feature silently without a prompt, and the
    // runtime error would be far from the root cause.
    const expectedFeatureKeys = [
      'pantry_parse', 'dinner_solve', 'cook_turn', 'cook_mode_realtime',
      'substitution', 'recipe_import', 'grocery_generate',
    ] as const;
    const seenKeys = new Set(prompts.map((p) => p.feature_key));
    for (const expected of expectedFeatureKeys) {
      if (!seenKeys.has(expected)) {
        userLog.warn('prompt_default_missing', { feature_key: expected });
      }
    }

    const body = {
      entitlements: {
        tier,
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
      tier,
      raw_tier: entitlement.tier,
      period_end: toIsoDate(periodEnd),
    });
    // Entitlement state must never be cached by intermediaries (CDN,
    // proxy) — stale entitlements are the worst kind of UX bug: iOS
    // shows features as unlocked/locked based on a snapshot that doesn't
    // reflect the user's actual subscription. `no-store` is stricter than
    // `no-cache` and prevents even a conditional revalidation request.
    return jsonOk(body, requestId, 200, { 'cache-control': 'no-store' });
  } catch (err) {
    userLog.error('internal_error', err, {
      latency_ms: Math.round(performance.now() - started),
    });
    return jsonError(ErrorCode.NET_01, 500, undefined, requestId);
  }
});
