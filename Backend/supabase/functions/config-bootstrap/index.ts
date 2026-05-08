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
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { createServiceClient } from '../_shared/db.ts';
import { readAppUser } from '../_shared/identity.ts';
import {
  computeCurrentPeriodStart,
  effectiveTier,
  effectiveVoiceEnabled,
  ensureCurrentPeriodRows,
  MissingQuotaRowError,
  readEntitlement,
  readQuotasForWire,
  standingPantryCap,
  toIsoDate,
} from '../_shared/entitlements.ts';
import type { QuotaWire } from '../_shared/entitlements.ts';
import { readFlags } from '../_shared/flags.ts';
import type { PromptWireRow } from '../_shared/prompt_versions.ts';

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

    // Read-first, seed-on-miss. Previous implementation unconditionally
    // upserted the current-period rows on every call (foreground refresh
    // fires on every scenePhase .active). That's a write on ~99.9% of
    // calls where the period hasn't rolled over — wasted IOPS + latency
    // on a hot path.
    //
    // New shape: compute period window locally, attempt to read quotas
    // directly, and only seed rows on the rollover edge (signaled by
    // readQuotasForWire throwing `MissingQuotaRowError`). All other
    // reads — flags, prompts — run in parallel with the initial quota
    // read for the common (non-rollover) case.
    const accountCreatedAt = new Date(userRow.created_at);
    const { periodStart, periodEnd } = computeCurrentPeriodStart(accountCreatedAt);

    const quotasReadPromise = readQuotasForWire(
      client,
      claims.canonical_user_key,
      periodStart,
      periodEnd,
    ).catch((err: unknown) => err);
    const flagsPromise = readFlags(client, userLog);
    const promptsPromiseRaw = client
      .from('prompt_versions')
      .select('feature_key, version, provider_model, schema_hash, is_default, is_enabled')
      .eq('is_default', true);

    const [quotasReadResult, flags, promptsResult] = await Promise.all([
      quotasReadPromise,
      flagsPromise,
      promptsPromiseRaw,
    ]);

    let quotas: QuotaWire[];
    if (quotasReadResult instanceof MissingQuotaRowError) {
      // Rollover edge: the user crossed their monthly anchor day inside
      // the JWT TTL window and the new period's rows don't exist yet.
      // Seed them now (effective tier determines cap snapshot) and
      // re-read. This is the only path that writes.
      userLog.info('period_rollover_seed', {
        missing_features: quotasReadResult.missingFeatureKeys,
        period_start: toIsoDate(periodStart),
      });
      await ensureCurrentPeriodRows(
        client,
        claims.canonical_user_key,
        tier,
        accountCreatedAt,
      );
      quotas = await readQuotasForWire(
        client,
        claims.canonical_user_key,
        periodStart,
        periodEnd,
      );
    } else if (quotasReadResult instanceof Error) {
      // Some other DB error — bubble to the outer catch.
      throw quotasReadResult;
    } else {
      // Common path: quotas present; no write needed.
      quotas = quotasReadResult;
    }

    if (promptsResult.error) throw promptsResult.error;
    const prompts = (promptsResult.data ?? []) as PromptWireRow[];

    // Warn when an expected feature_key has no default prompt row — a bad
    // canary rollout can leave a feature silently without a prompt, and the
    // runtime error would be far from the root cause.
    const expectedFeatureKeys = [
      'pantry_parse',
      'dinner_solve',
      'cook_turn',
      'cook_mode_realtime',
      'substitution',
      'recipe_import',
      'grocery_generate',
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
        // SCA-100: standing-pantry-cap value table moved server-side.
        // iOS reads this off the wire instead of computing from
        // `Tier.rememberedPantryCap`, so future cap changes ship without
        // an iOS release. `standingPantryCap` routes through
        // `effectiveTier` so a stale RevenueCat row with
        // `billing_state = expired` correctly demotes to Free's cap.
        standing_pantry_cap: standingPantryCap(entitlement),
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
