// POST /functions/v1/session-bootstrap
// Logical endpoint: POST /v1/session/bootstrap (spec §3).
//
// Body:
//   { installation_id: UUID,
//     cloudkit_user_record_name?: string,
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

import { createLogger, requestIdFrom } from '../_shared/logger.ts';
import {
  ErrorCode,
  jsonError,
  jsonOk,
} from '../_shared/errors.ts';
import { issueSessionJWT, type UserTier } from '../_shared/auth.ts';
import { SessionBootstrapRequest, zodToFieldErrors } from '../_shared/validation.ts';
import { createServiceClient } from '../_shared/db.ts';
import {
  type AppUserRow,
  aliasForward,
  followMergedInto,
  readAppUser,
  resolveCanonicalKey,
} from '../_shared/identity.ts';
import {
  ensureCurrentPeriodRows,
  ensureEntitlementRow,
  readEntitlement,
  readQuotasForWire,
} from '../_shared/entitlements.ts';
import { readFlags } from '../_shared/flags.ts';
import { ZodError } from 'zod';

Deno.serve(async (req) => {
  const requestId = requestIdFrom(req);
  const endpoint = '/v1/session/bootstrap';
  const log = await createLogger(requestId, endpoint);

  if (req.method !== 'POST') {
    log.warn('method_not_allowed', { method: req.method });
    return jsonError(
      ErrorCode.VAL_01,
      405,
      { message: 'Method Not Allowed; use POST.' },
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
  // 2. Resolve canonical key + scope logger to the user
  // -----------------------------------------------------------------------
  const resolution = resolveCanonicalKey(parsed);
  const userLog = await createLogger(requestId, endpoint, resolution.canonical_user_key);
  userLog.info('canonical_key_resolved', {
    source_type: resolution.source_type,
    has_cloudkit: Boolean(resolution.ck_canonical_key),
  });

  // -----------------------------------------------------------------------
  // 3. DB work — service-role client (bypasses RLS)
  // -----------------------------------------------------------------------
  const client = createServiceClient();

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
        // Race: a concurrent bootstrap may have inserted. Re-read.
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

    // 3b. Alias-forward check: winning key is ck: and an install: row
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

    // 3c. Banned check + merged-chain follow (one hop max).
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
    await ensureEntitlementRow(client, winningKey);
    const entitlement = await readEntitlement(client, winningKey);
    if (!entitlement) throw new Error('entitlement row missing after ensure');
    const tier: UserTier = entitlement.tier;

    const accountCreatedAt = new Date(userRow.created_at);
    const { periodStart, periodEnd } = await ensureCurrentPeriodRows(
      client,
      winningKey,
      tier,
      accountCreatedAt,
    );

    // 3f. Read quotas + flags for response.
    const quotas = await readQuotasForWire(client, winningKey, periodStart, periodEnd);
    const flags = await readFlags(client);

    // -----------------------------------------------------------------------
    // 4. Mint JWT + compose response
    // -----------------------------------------------------------------------
    const sessionJwt = await issueSessionJWT({
      canonical_user_key: winningKey,
      installation_id: parsed.installation_id,
      tier,
    });

    const voiceEnabled = tier !== 'free';
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
