// POST /functions/v1/session-bootstrap
// Logical endpoint: POST /v1/session/bootstrap (spec §3).
//
// Body:
//   { installation_id: UUID,
//     cloudkit_user_record_name?: string,
//     cloudkit_web_auth_token?: string,
//     build: string,
//     os_version: string }
//
// Response: Round 3 shape — see plan file §"Session-bootstrap response"
//   { session_jwt, canonical_user_key, is_new_user,
//     entitlements: { tier, billing_state, is_trial, expires_at,
//                     voice_enabled, billing_retry_banner, quotas[] },
//     feature_flags: [{ key, value, is_enabled, rollout_pct }] }
//
// Handler flow:
//   1. Request-id + entry log.
//   2. Zod-validate body → 400 VAL-01 on fail.
//   3. Resolve canonical key (install:<uuid> or ck:<record>).
//   4. Load/insert app_users; if aliasing (new ck winning over existing
//      install row), call stir_alias_forward RPC (atomic, see migration 11).
//   5. Follow merged_into (one hop); if banned, 403 BILL-01; halt.
//   6. Upsert device_installations; ensure entitlement + current-period usage rows.
//   7. Read entitlements + quotas + flags.
//   8. issueSessionJWT and return 200.

import { createLogger, requestIdFrom, sanitizeErrorForLog } from '../_shared/logger.ts';
import { ErrorCode, jsonError, jsonOk } from '../_shared/errors.ts';
import { issueSessionJWT, type UserTier } from '../_shared/auth.ts';
import { SessionBootstrapRequest, zodToFieldErrors } from '../_shared/validation.ts';
import { createServiceClient } from '../_shared/db.ts';
import {
  aliasForward,
  type AppUserRow,
  followMergedInto,
  readAppUser,
  resolveCanonicalKey,
} from '../_shared/identity.ts';
import {
  effectiveTier,
  effectiveVoiceEnabled,
  ensureCurrentPeriodRows,
  ensureEntitlementRow,
  readQuotasForWire,
  standingPantryCap,
} from '../_shared/entitlements.ts';
import { readFlags } from '../_shared/flags.ts';
import {
  buildRate01Response,
  checkAndIncrement,
  extractSourceIP,
  ipBucket,
} from '../_shared/rate_limiter.ts';
import { capturePosthogEvent } from '../_shared/posthog.ts';
import { hashCanonicalKey } from '../_shared/hashing.ts';
import { ZodError } from 'zod';
import {
  bodyWithVerifiedCloudKitOnly,
  verifyCloudKitIdentity,
} from '../_shared/cloudkit_identity.ts';

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/session/bootstrap';
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

  // -----------------------------------------------------------------------
  // 1. Parse + validate body
  // -----------------------------------------------------------------------
  let parsed;
  try {
    const body = await req.json();
    parsed = SessionBootstrapRequest.parse(body);
  } catch (err) {
    if (err instanceof ZodError) {
      const fieldErrors = zodToFieldErrors(err);
      log.warn('validation_failed', { field_errors: fieldErrors });
      return jsonError(
        ErrorCode.VAL_01,
        400,
        {
          message: 'Request body failed validation.',
          field_errors: fieldErrors,
        },
        requestId,
      );
    }
    // Body wasn't valid JSON at all.
    log.warn('body_parse_failed', { err: err instanceof Error ? err.message : String(err) });
    return jsonError(
      ErrorCode.VAL_01,
      400,
      {
        message: 'Request body must be JSON.',
        field_errors: [{ field: '<root>', issue: 'not valid JSON' }],
      },
      requestId,
    );
  }

  // -----------------------------------------------------------------------
  // 2a. IP rate limit (SCA-247 / C4 from /review-5: this gate now runs
  // BEFORE the CloudKit verifier, not after).
  // -----------------------------------------------------------------------
  // 20 bootstraps per hour per source IP. Stops synthetic-install DoS +
  // JWT-farming. Pre-C4 ordering ran AFTER the verifier so the 429 path
  // could log against a user-scoped logger; the cost was that an
  // attacker with valid-looking CK record names could drive 20 outbound
  // calls to api.apple-cloudkit.com per IP/hr at our cost before any
  // cap fired (and Apple-side stalls cascaded into bootstrap latency
  // for everyone behind that IP). Reordering means the 429 logs against
  // request-id only — acceptable because we don't trust the canonical
  // key claim until the verifier confirms it anyway.
  const client = createServiceClient();
  const sourceIP = extractSourceIP(req);
  try {
    const rl = await checkAndIncrement(client, 'ip:bootstrap_hourly', sourceIP);
    if (!rl.allowed) {
      log.warn('rate_limited', {
        scope: 'ip:bootstrap_hourly',
        source_ip_bucket: await ipBucket(sourceIP),
      });
      return buildRate01Response(
        'ip:bootstrap_hourly',
        rl.retry_after_seconds,
        rl.reset_at,
        requestId,
      );
    }
  } catch (err) {
    // Fail open — rate limiter DB glitch shouldn't block a legitimate
    // first-install from ever reaching the app. Log + continue.
    log.warn('rate_limiter_failed', { err: sanitizeErrorForLog(err) });
  }

  // -----------------------------------------------------------------------
  // 2b. Verify CloudKit claim, then resolve canonical key + scope logger
  // -----------------------------------------------------------------------
  const cloudKitVerification = await verifyCloudKitIdentity(parsed);
  const identityBody = bodyWithVerifiedCloudKitOnly(parsed, cloudKitVerification);
  const resolution = resolveCanonicalKey(identityBody);
  const userLog = await createLogger(requestId, endpoint, resolution.canonical_user_key);
  userLog.info('canonical_key_resolved', {
    source_type: resolution.source_type,
    has_cloudkit: Boolean(resolution.ck_canonical_key),
    cloudkit_verification: cloudKitVerification.reason,
    cloudkit_upstream_status: cloudKitVerification.upstreamStatus,
  });
  // SCA-245 (C2 from /review-5): elevate `verifier_unconfigured` to
  // warn so a misconfigured prod is loud in dashboards. Until the
  // CLOUDKIT_API_TOKEN secret is set + session-bootstrap is
  // redeployed, every CK-claiming bootstrap silently runs in
  // rollout-trust mode (claim preserved, token stripped).
  if (cloudKitVerification.reason === 'verifier_unconfigured') {
    userLog.warn('cloudkit_verifier_unconfigured', {
      source_type: resolution.source_type,
    });
  }

  try {
    let isNewUser = false;
    let aliasPerformed = false;

    // 3a. Ensure the winning app_users row exists.
    let userRow = await readAppUser(client, resolution.canonical_user_key);
    if (!userRow) {
      const insert = await client.from('app_users').insert({
        canonical_user_key: resolution.canonical_user_key,
        current_install_id: parsed.installation_id,
        revenuecat_app_user_id: resolution.canonical_user_key,
        source_type: resolution.source_type,
        status: 'active',
      }).select().single();
      if (insert.error) {
        // Only treat duplicate-key (Postgres SQLSTATE 23505) as the
        // concurrent-bootstrap race worth recovering from. Anything else
        // (FK violation, serialization failure, network blip) is a real
        // problem — surface it rather than masking with a re-read that
        // might happen to succeed because a different code path inserted
        // a row with different attributes.
        const pgCode = (insert.error as { code?: string }).code;
        if (pgCode !== '23505') throw insert.error;
        userRow = await readAppUser(client, resolution.canonical_user_key);
        if (!userRow) throw insert.error;
      } else {
        userRow = insert.data as AppUserRow;
        isNewUser = true;
      }
    } else {
      // Row existed — update last_seen_at + current_install_id for liveness.
      const { error } = await client
        .from('app_users')
        .update({
          last_seen_at: new Date().toISOString(),
          current_install_id: parsed.installation_id,
        })
        .eq('canonical_user_key', resolution.canonical_user_key);
      if (error) throw error;
    }

    // 3b. Status gates — run BEFORE alias-forward so a banned winning row
    //     can't have install-scoped data merged into it, and a merged-forward
    //     winning row resolves to its terminal identity first.
    //
    //     Security invariant (SA2 review): alias-forward is a mutation that
    //     moves usage counters, AI logs, device rows, and (possibly) an
    //     entitlement into the winning CK row. If we ran alias-forward
    //     before the banned check, we'd leak the install user's quota
    //     snapshot + ai_request_log history into a banned account (making
    //     unban ambiguous) and permanently merge the install row into a
    //     dead end. Status resolution belongs first.
    if (userRow.status === 'banned') {
      userLog.warn('banned_user_blocked');
      return jsonError(
        ErrorCode.BILL_01,
        403,
        { message: 'Account is not eligible for Stir.', state: 'banned' },
        requestId,
      );
    }
    if (userRow.merged_into != null) {
      userRow = await followMergedInto(client, userRow);
      // followMergedInto already bans nested chains; banned terminal is
      // also re-checked here defensively.
      if (userRow.status === 'banned') {
        userLog.warn('banned_user_blocked_post_merge');
        return jsonError(
          ErrorCode.BILL_01,
          403,
          { message: 'Account is not eligible for Stir.', state: 'banned' },
          requestId,
        );
      }
    }

    // 3c. Alias-forward check: winning key is ck: and an install: row
    //     for the same installation still exists active → merge.
    if (
      resolution.source_type === 'cloudkit' &&
      resolution.ck_canonical_key &&
      resolution.install_canonical_key !== resolution.canonical_user_key
    ) {
      const installRow = await readAppUser(client, resolution.install_canonical_key);
      if (installRow && installRow.status === 'active') {
        userLog.info('alias_forward_begin', {
          install: resolution.install_canonical_key,
          ck: resolution.ck_canonical_key,
        });
        const merge = await aliasForward(
          client,
          resolution.install_canonical_key,
          resolution.ck_canonical_key,
        );
        aliasPerformed = merge.alias_performed;
        userLog.info('alias_forward_complete', {
          usage_rows_merged: merge.usage_rows_merged,
          entitlement_row_discarded: merge.entitlement_row_discarded,
          ai_log_rows_rewritten: merge.ai_log_rows_rewritten,
          device_rows_rewritten: merge.device_rows_rewritten,
        });
      }
    }

    const winningKey = userRow.canonical_user_key;

    // 3d. Upsert device_installations.
    const { error: devErr } = await client.from('device_installations').upsert(
      {
        installation_id: parsed.installation_id,
        canonical_user_key: winningKey,
        build: parsed.build,
        os_version: parsed.os_version,
        last_seen_at: new Date().toISOString(),
      },
      { onConflict: 'installation_id' },
    );
    if (devErr) throw devErr;

    // 3e. Ensure entitlement + current-period usage rows.
    //
    // `entitlement.tier` is the raw RevenueCat column; when billing_state is
    // 'none' or 'expired' the user's *effective* tier is Free regardless of
    // what RevenueCat remembers. Effective tier drives both cap snapshots and
    // the JWT `tier` claim so downstream quota checks and feature gates can't
    // be fooled by a stale premium row on an expired subscription.
    const entitlement = await ensureEntitlementRow(client, winningKey);
    const tier: UserTier = effectiveTier(entitlement);

    const accountCreatedAt = new Date(userRow.created_at);
    const { periodStart, periodEnd } = await ensureCurrentPeriodRows(
      client,
      winningKey,
      tier,
      accountCreatedAt,
    );

    // 3f. Read quotas + flags for response.
    const quotas = await readQuotasForWire(client, winningKey, periodStart, periodEnd);
    const flags = await readFlags(client, userLog);

    // -----------------------------------------------------------------------
    // 4. Mint JWT + compose response
    // -----------------------------------------------------------------------
    const sessionJwt = await issueSessionJWT({
      canonical_user_key: winningKey,
      installation_id: parsed.installation_id,
      tier,
    });

    const voiceEnabled = effectiveVoiceEnabled(entitlement);
    const billingRetryBanner = entitlement.billing_state === 'grace';

    const body = {
      session_jwt: sessionJwt,
      canonical_user_key: winningKey,
      is_new_user: isNewUser && !aliasPerformed,
      entitlements: {
        tier,
        billing_state: entitlement.billing_state,
        is_trial: entitlement.is_trial,
        expires_at: entitlement.expires_at,
        voice_enabled: voiceEnabled,
        billing_retry_banner: billingRetryBanner,
        // SCA-100: see config-bootstrap for the rationale. Both
        // bootstrap endpoints carry this field so a fresh JWT mint
        // (24h cache miss) gets the same shape as a foreground refresh.
        standing_pantry_cap: standingPantryCap(entitlement),
        quotas,
      },
      feature_flags: flags,
    };

    userLog.info('request_complete', {
      status: 200,
      latency_ms: Math.round(performance.now() - started),
      is_new_user: body.is_new_user,
      alias_performed: aliasPerformed,
      tier,
    });

    // SCA-62: emit identity-state events from the server. iOS-side
    // entitlement_state_changed runs on next foreground only — this
    // is the immediate-truth signal for the bootstrap dashboard tile.
    try {
      const distinctIdHash = await hashCanonicalKey(winningKey);
      if (body.is_new_user) {
        capturePosthogEvent(userLog, {
          event: 'app_users_bootstrapped',
          distinctId: distinctIdHash,
          properties: {
            request_id: requestId,
            actor_id: 'system:server',
            has_cloudkit_record: resolution.source_type === 'cloudkit',
            tier,
          },
        });
      }
      if (aliasPerformed) {
        capturePosthogEvent(userLog, {
          event: 'app_users_merged',
          distinctId: distinctIdHash,
          properties: {
            request_id: requestId,
            actor_id: 'system:server',
            tier,
          },
        });
      }
    } catch (telemetryErr) {
      // Telemetry failure must not fail the request. Logged at warn
      // so ops can spot patterns without paging.
      userLog.warn('posthog_emit_failed', {
        err: telemetryErr instanceof Error ? telemetryErr.message : String(telemetryErr),
      });
    }

    return jsonOk(body, requestId);
  } catch (err) {
    userLog.error('internal_error', err, {
      latency_ms: Math.round(performance.now() - started),
    });
    return jsonError(
      ErrorCode.NET_01,
      500,
      {
        message: 'Internal error during session bootstrap.',
      },
      requestId,
    );
  }
});
