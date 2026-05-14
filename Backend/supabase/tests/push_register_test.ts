// push_register_test
//
// HTTP-level tests for /v1/push/register — AUTH-01, VAL-01 (apns_token
// regex, prefs shape, environment enum), and happy-path upsert that
// records apns_environment + notification_prefs_json on the install row.

import { assertEquals } from '@std/assert';
import {
  quickBootstrap,
  STUB_CLOUDKIT_WEB_AUTH_TOKEN,
  testCkRecord,
  testIPHeaders,
} from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface HttpResult {
  status: number;
  body: Record<string, unknown>;
}

async function callPushRegister(body: unknown, jwt: string | null): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/push-register`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

function hex64(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

function validBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    apns_token: hex64(),
    environment: 'sandbox',
    // SCA-322: schema requires all four prefs.
    notification_prefs: {
      import_completion: true,
      reactivation: false,
      cook_reminder: true,
      billing_grace: true,
    },
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// AUTH-01
// ---------------------------------------------------------------------------

Deno.test('push_register: AUTH-01 on missing Authorization', async () => {
  const res = await callPushRegister(validBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
});

// ---------------------------------------------------------------------------
// VAL-01
// ---------------------------------------------------------------------------

Deno.test('push_register: VAL-01 when apns_token is not 64 hex', async () => {
  const { session_jwt } = await quickBootstrap();
  const res = await callPushRegister(validBody({ apns_token: 'zzzz' }), session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('push_register: VAL-01 when environment is invalid', async () => {
  const { session_jwt } = await quickBootstrap();
  const res = await callPushRegister(validBody({ environment: 'staging' }), session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('push_register: VAL-01 when a notification_pref is not boolean', async () => {
  const { session_jwt } = await quickBootstrap();
  const res = await callPushRegister(
    validBody({
      notification_prefs: {
        import_completion: 'yes',
        reactivation: false,
        cook_reminder: true,
        billing_grace: true,
      },
    }),
    session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('push_register: VAL-01 when a notification_pref is missing (.strict)', async () => {
  // SCA-322: schema is .strict() — pre-fix users could omit fields
  // and silently default-True; post-fix every category must be
  // explicit so server reads consistent state.
  const { session_jwt } = await quickBootstrap();
  const res = await callPushRegister(
    validBody({
      notification_prefs: {
        import_completion: true,
        reactivation: true,
        // cook_reminder + billing_grace deliberately omitted
      },
    }),
    session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// Happy path — upsert persists on device_installations
// ---------------------------------------------------------------------------

Deno.test('push_register: happy path persists push_token + env + prefs', async () => {
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const token = hex64();
  const res = await callPushRegister(
    validBody({
      apns_token: token,
      environment: 'production',
      notification_prefs: {
        import_completion: true,
        reactivation: true,
        cook_reminder: true,
        billing_grace: true,
      },
    }),
    session_jwt,
  );
  assertEquals(res.status, 200);

  const client = serviceClient();
  const { data, error } = await client
    .from('device_installations')
    .select('push_token, apns_environment, notifications_enabled, notification_prefs_json')
    .eq('canonical_user_key', canonical_user_key)
    .order('last_seen_at', { ascending: false })
    .limit(1)
    .single<{
      push_token: string | null;
      apns_environment: string | null;
      notifications_enabled: boolean;
      notification_prefs_json: Record<string, boolean> | null;
    }>();
  assertEquals(error, null);
  assertEquals(data?.push_token, token);
  assertEquals(data?.apns_environment, 'production');
  assertEquals(data?.notifications_enabled, true);
  assertEquals(data?.notification_prefs_json?.import_completion, true);
  assertEquals(data?.notification_prefs_json?.reactivation, true);
});

// ---------------------------------------------------------------------------
// SCA-321 — multi-install isolation
// ---------------------------------------------------------------------------

Deno.test('push_register: multi-install — each install owns its own row', async () => {
  // Two iOS installs sharing the same CloudKit identity (one user,
  // two devices). Pre-fix the second POST clobbered whichever row
  // `last_seen_at DESC LIMIT 1` surfaced; post-fix each install
  // updates only its own `installation_id`-keyed row.
  //
  // SCA-349: use `testCkRecord()` helper — raw `crypto.randomUUID()`
  // produces a dashed 36-char string that fails `CK_RECORD_NAME_REGEX`
  // (`_` + 32 lowercase hex, no dashes).
  //
  // SCA-349: also pass `STUB_CLOUDKIT_WEB_AUTH_TOKEN` — without a
  // token the verifier returns `missing_web_auth_token` and strips
  // the CK claim, leaving both bootstraps on `install:<uuid>` keys
  // and the shared-identity assertion below cannot hold. With the
  // stub token + no `CLOUDKIT_API_TOKEN` in local env, the verifier
  // returns `verifier_unconfigured` (trust-mode) which preserves
  // record_name → canonical_user_key resolves to `ck:<record>` for
  // both installs. See `STUB_CLOUDKIT_WEB_AUTH_TOKEN` docstring.
  const ckRecordName = testCkRecord();
  const installA = crypto.randomUUID();
  const installB = crypto.randomUUID();

  const sessionA = await quickBootstrap({
    installation_id: installA,
    cloudkit_user_record_name: ckRecordName,
    cloudkit_web_auth_token: STUB_CLOUDKIT_WEB_AUTH_TOKEN,
  });
  const sessionB = await quickBootstrap({
    installation_id: installB,
    cloudkit_user_record_name: ckRecordName,
    cloudkit_web_auth_token: STUB_CLOUDKIT_WEB_AUTH_TOKEN,
  });
  // Both bootstraps land under the same canonical_user_key
  // (`ck:<recordName>`), so the legacy `canonical_user_key`-only SELECT
  // would have collapsed them.
  assertEquals(sessionA.canonical_user_key, sessionB.canonical_user_key);

  const tokenA = 'a'.repeat(64);
  const tokenB = 'b'.repeat(64);

  const resA = await callPushRegister(
    validBody({ apns_token: tokenA }),
    sessionA.session_jwt,
  );
  assertEquals(resA.status, 200);

  const resB = await callPushRegister(
    validBody({ apns_token: tokenB }),
    sessionB.session_jwt,
  );
  assertEquals(resB.status, 200);

  const client = serviceClient();
  const { data: rowA } = await client
    .from('device_installations')
    .select('push_token')
    .eq('installation_id', installA)
    .single<{ push_token: string | null }>();
  const { data: rowB } = await client
    .from('device_installations')
    .select('push_token')
    .eq('installation_id', installB)
    .single<{ push_token: string | null }>();

  assertEquals(rowA?.push_token, tokenA, 'install A keeps its own token');
  assertEquals(rowB?.push_token, tokenB, 'install B keeps its own token');
});

// ---------------------------------------------------------------------------
// SCA-353 — alias-forward race
// ---------------------------------------------------------------------------

Deno.test('push_register: alias-forwarded user — pre-alias JWT routes via merged_into', async () => {
  // Repro the SCA-353 race:
  //   1. User cold-launches WITHOUT CloudKit. Bootstrap mints a JWT
  //      bearing canonical_user_key = "install:<uuid>".
  //   2. Later, CloudKit identity surfaces. A second bootstrap with the
  //      same install_id + a CK record name triggers the identity-merge
  //      transaction, which rewrites device_installations.canonical_user_key
  //      from "install:*" to "ck:*" and sets app_users[install:*].merged_into
  //      to "ck:*".
  //   3. iOS still holds the FIRST JWT (claim key still "install:*").
  //      verifySessionJWT passes — it's a valid token — but a SELECT keyed
  //      on the raw claim canonical_user_key would miss the row.
  //   4. push-register must follow merged_into to find the row under its
  //      new canonical_user_key.
  const installId = crypto.randomUUID();

  const sessionInstallOnly = await quickBootstrap({ installation_id: installId });
  // session is keyed on install:<uuid>.
  const installKey = sessionInstallOnly.canonical_user_key;

  // CK arrives — second bootstrap with the same install_id triggers the
  // alias-forward transaction. CK record name must match the SCA-380
  // tightening (`_` + 32 lowercase hex chars), so strip UUID hyphens.
  // SCA-349 test seam: also pass `STUB_CLOUDKIT_WEB_AUTH_TOKEN` so the
  // CloudKit identity verifier exercises the `verifier_unconfigured` carve-out
  // and the record name resolves to `ck:*` instead of falling back to `install:*`.
  const ckRecordName = `_${crypto.randomUUID().replace(/-/g, '')}`;
  const sessionCK = await quickBootstrap({
    installation_id: installId,
    cloudkit_user_record_name: ckRecordName,
    cloudkit_web_auth_token: STUB_CLOUDKIT_WEB_AUTH_TOKEN,
  });
  // session now keyed on ck:<recordName>; install: row's
  // canonical_user_key was rewritten + app_users[install:*].merged_into = ck:*.
  const ckKey = sessionCK.canonical_user_key;
  // Sanity: the two keys MUST differ — that's the whole point of the
  // alias-forward.
  if (installKey === ckKey) {
    throw new Error(
      `test setup: install and CK keys should differ; got '${installKey}' twice`,
    );
  }

  // Use the OLD JWT (install:*) to POST push-register. The handler must
  // resolve via followMergedInto and write to the row that's now keyed
  // on ck:*.
  const tokenViaOldJwt = 'c'.repeat(64);
  const res = await callPushRegister(
    validBody({ apns_token: tokenViaOldJwt }),
    sessionInstallOnly.session_jwt,
  );
  assertEquals(res.status, 200, `pre-alias JWT should succeed; body=${JSON.stringify(res.body)}`);

  const client = serviceClient();
  const { data: row } = await client
    .from('device_installations')
    .select('push_token, canonical_user_key')
    .eq('installation_id', installId)
    .single<{ push_token: string | null; canonical_user_key: string }>();

  assertEquals(
    row?.push_token,
    tokenViaOldJwt,
    'pre-alias JWT wrote the new token to the post-alias row',
  );
  assertEquals(row?.canonical_user_key, ckKey, 'row is keyed on ck:* after the alias-forward');
});

// ---------------------------------------------------------------------------
// SCA-365 — additional push-register coverage
// ---------------------------------------------------------------------------

Deno.test('push_register: identical re-POST is idempotent (single row, last_seen_at advances)', async () => {
  // Per the iOS APNsRegistrationCoordinator design, a same-(token, prefs)
  // re-POST is expected to be a server-side no-op UPDATE. SCA-321
  // keyed the SELECT on installation_id; the second POST should write
  // to the SAME row.
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const token = hex64();

  const res1 = await callPushRegister(validBody({ apns_token: token }), session_jwt);
  assertEquals(res1.status, 200);

  // Capture last_seen_at after first POST.
  const client = serviceClient();
  const { data: firstRow } = await client
    .from('device_installations')
    .select('last_seen_at, installation_id')
    .eq('canonical_user_key', canonical_user_key)
    .single<{ last_seen_at: string; installation_id: string }>();
  const firstSeen = firstRow?.last_seen_at;

  // Wait a moment so last_seen_at can advance.
  await new Promise<void>((r) => setTimeout(r, 1100));

  const res2 = await callPushRegister(validBody({ apns_token: token }), session_jwt);
  assertEquals(res2.status, 200);

  // Assert: still exactly ONE row for this user; last_seen_at advanced.
  const { data: rows } = await client
    .from('device_installations')
    .select('installation_id, last_seen_at')
    .eq('canonical_user_key', canonical_user_key);
  assertEquals(rows?.length, 1, 'idempotent re-POST must NOT create a new row');
  if (rows && rows.length === 1) {
    const lastSeen = (rows[0] as { last_seen_at: string }).last_seen_at;
    if (firstSeen && lastSeen <= firstSeen) {
      throw new Error(`last_seen_at must advance: first=${firstSeen} second=${lastSeen}`);
    }
  }
});

Deno.test('push_register: VAL-01 when installation_id row is gone (user-deletion race)', async () => {
  // Repro the race: user-deletion worker runs between iOS holding a
  // valid JWT and the next push-register POST. The row vanishes; the
  // handler should emit VAL-01 with the spec-canonical 'session'
  // field_errors entry.
  const installId = crypto.randomUUID();
  const { session_jwt, canonical_user_key } = await quickBootstrap({
    installation_id: installId,
  });
  // Test-only: service-role delete to simulate the deletion worker.
  const client = serviceClient();
  await client
    .from('device_installations')
    .delete()
    .eq('installation_id', installId)
    .eq('canonical_user_key', canonical_user_key);

  const res = await callPushRegister(validBody(), session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
  // Spec-canonical field shape so iOS can branch on it.
  const fieldErrors = res.body.field_errors as Array<{ field: string }> | undefined;
  assertEquals(fieldErrors?.[0]?.field, 'session');
});

// ---------------------------------------------------------------------------
// SCA-392 — audit_log INSERT actually lands (the SCA-381 ship had every row
// drop with `22P02 invalid input syntax for type uuid` because actor_id was
// being passed a non-UUID canonical_user_key into a UUID column. writeAudit's
// non-fatal posture swallowed the error so SCA-381's entire observability
// surface emitted zero rows in prod. These tests pin the row landing.)
// ---------------------------------------------------------------------------

Deno.test('push_register: SCA-392 — auth_user_stale writes audit_log row (actor_id null, hashed key in after)', async () => {
  // Bootstrap a user, then service-role delete the app_users row so the
  // JWT verifies (signature + claims OK) but the user row is gone. The
  // handler hits the user_row_missing branch and writes an
  // `auth_user_stale` audit row.
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const client = serviceClient();
  await client.from('app_users').delete().eq('canonical_user_key', canonical_user_key);

  const res = await callPushRegister(validBody(), session_jwt);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'user_stale');

  // Audit row MUST exist — pre-SCA-392 this row silently dropped.
  const { data: rows, error } = await client
    .from('audit_log')
    .select('actor_id, target_id, action, after_json')
    .eq('action', 'auth_user_stale')
    .eq('target_id', canonical_user_key);
  if (error) throw new Error(`audit_log read failed: ${error.message}`);
  assertEquals(rows?.length, 1, 'SCA-392: audit_log row MUST land (pre-fix it dropped silently)');
  const row = rows![0] as {
    actor_id: string | null;
    target_id: string;
    action: string;
    after_json: { reason?: string; canonical_user_key_hash?: string };
  };
  assertEquals(row.actor_id, null, 'actor_id must be null (column is UUID; canonical_user_key is not)');
  assertEquals(row.target_id, canonical_user_key, 'target_id is TEXT and carries the unresolved key');
  assertEquals(row.after_json.reason, 'user_stale');
  // hashCanonicalKey is 16-char hex (4-byte truncated SHA-256).
  if (!row.after_json.canonical_user_key_hash || !/^[0-9a-f]{16}$/.test(row.after_json.canonical_user_key_hash)) {
    throw new Error(
      `expected 16-hex-char canonical_user_key_hash in after_json, got: ${
        JSON.stringify(row.after_json)
      }`,
    );
  }
});

Deno.test('push_register: SCA-392 — apns_environment_flipped writes audit_log row on env flip', async () => {
  // POST once with sandbox, then again with production. Audit row should
  // land with before/after env + hashed key; pre-fix this row silently
  // dropped on the UUID type mismatch.
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const token = hex64();
  const tokenB = hex64();

  const res1 = await callPushRegister(validBody({ apns_token: token, environment: 'sandbox' }), session_jwt);
  assertEquals(res1.status, 200);

  const res2 = await callPushRegister(
    validBody({ apns_token: tokenB, environment: 'production' }),
    session_jwt,
  );
  assertEquals(res2.status, 200);

  const client = serviceClient();
  // Identify the install_id this test wrote to (filter on the user).
  const { data: installRows } = await client
    .from('device_installations')
    .select('installation_id')
    .eq('canonical_user_key', canonical_user_key);
  assertEquals(installRows?.length, 1);
  const installId = (installRows![0] as { installation_id: string }).installation_id;

  const { data: rows, error } = await client
    .from('audit_log')
    .select('actor_id, target_id, action, before_json, after_json')
    .eq('action', 'apns_environment_flipped')
    .eq('target_id', installId);
  if (error) throw new Error(`audit_log read failed: ${error.message}`);
  assertEquals(rows?.length, 1, 'SCA-392: env-flip audit row MUST land (pre-fix it dropped silently)');
  const row = rows![0] as {
    actor_id: string | null;
    before_json: { apns_environment: string };
    after_json: { apns_environment: string; canonical_user_key_hash?: string };
  };
  assertEquals(row.actor_id, null);
  assertEquals(row.before_json.apns_environment, 'sandbox');
  assertEquals(row.after_json.apns_environment, 'production');
  if (!row.after_json.canonical_user_key_hash || !/^[0-9a-f]{16}$/.test(row.after_json.canonical_user_key_hash)) {
    throw new Error(`expected 16-hex-char hash in after_json: ${JSON.stringify(row.after_json)}`);
  }
});

Deno.test('push_register: SCA-392 — same-environment re-POST does NOT write a flip audit row', async () => {
  // Negative half: a same-(env) re-POST is the common case. The flip
  // detector must NOT fire on it.
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const r1 = await callPushRegister(validBody({ environment: 'sandbox' }), session_jwt);
  assertEquals(r1.status, 200);
  const r2 = await callPushRegister(validBody({ environment: 'sandbox' }), session_jwt);
  assertEquals(r2.status, 200);

  const client = serviceClient();
  const { data: installRows } = await client
    .from('device_installations')
    .select('installation_id')
    .eq('canonical_user_key', canonical_user_key);
  const installId = (installRows![0] as { installation_id: string }).installation_id;

  const { data: rows } = await client
    .from('audit_log')
    .select('id')
    .eq('action', 'apns_environment_flipped')
    .eq('target_id', installId);
  assertEquals(rows?.length, 0, 'same-env re-POST must NOT write a flip row');
});
