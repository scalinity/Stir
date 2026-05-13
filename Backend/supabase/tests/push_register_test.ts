// push_register_test
//
// HTTP-level tests for /v1/push/register — AUTH-01, VAL-01 (apns_token
// regex, prefs shape, environment enum), and happy-path upsert that
// records apns_environment + notification_prefs_json on the install row.

import { assertEquals } from '@std/assert';
import { quickBootstrap, testIPHeaders } from './_helpers/factory.ts';
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
  const ckRecordName = `_${crypto.randomUUID()}`;
  const installA = crypto.randomUUID();
  const installB = crypto.randomUUID();

  const sessionA = await quickBootstrap({
    installation_id: installA,
    cloudkit_user_record_name: ckRecordName,
  });
  const sessionB = await quickBootstrap({
    installation_id: installB,
    cloudkit_user_record_name: ckRecordName,
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
  // alias-forward transaction.
  const ckRecordName = `_${crypto.randomUUID()}`;
  const sessionCK = await quickBootstrap({
    installation_id: installId,
    cloudkit_user_record_name: ckRecordName,
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
