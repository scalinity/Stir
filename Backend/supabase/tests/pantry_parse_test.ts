// pantry_parse_test
//
// HTTP-level tests for /v1/ai/pantry-parse that exercise paths BEFORE
// the Gemini call — VAL-01 validation, AUTH-01, ENT-MULTI-IMAGE-01.
// Happy-path integration tests are gated on STIR_RUN_AI_INTEGRATION_TESTS=1
// so CI runs don't burn the paid-tier budget.

import { assertEquals, assertNotEquals } from '@std/assert';
import { quickBootstrap, testInstallId, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

/**
 * SCA-36 W17: helper for the happy-path multi-image test. Bootstraps
 * a Free user, upserts entitlement_snapshots → tier=pro, then re-
 * bootstraps so the returned JWT carries `tier: 'pro'`. The handler
 * resolves tier from the JWT, not from a per-request DB lookup, so
 * the re-bootstrap is required for the entitlement gate to see Pro.
 *
 * Bumps the rate-limit cap by clearing buckets via clearRateLimitBuckets()
 * — caller is expected to have done that at module load.
 */
async function quickBootstrapPro(): Promise<{
  session_jwt: string;
  canonical_user_key: string;
}> {
  const installId = testInstallId();
  const initial = await quickBootstrap({ installation_id: installId });
  const client = serviceClient();
  const { error } = await client
    .from('entitlement_snapshots')
    .upsert({
      canonical_user_key: initial.canonical_user_key,
      tier: 'pro',
      billing_state: 'active',
      is_trial: false,
      expires_at: '2026-12-31T23:59:59Z',
      raw_webhook_payload: {},
    });
  if (error) throw new Error(`failed to seed Pro entitlement: ${error.message}`);
  const reBoot = await quickBootstrap({ installation_id: installId });
  if (reBoot.entitlements.tier !== 'pro') {
    throw new Error(
      `expected tier=pro after re-bootstrap, got tier=${reBoot.entitlements.tier}`,
    );
  }
  return {
    session_jwt: reBoot.session_jwt,
    canonical_user_key: reBoot.canonical_user_key,
  };
}

// Kong overrides x-real-ip; clear ip:bootstrap_hourly + ip:pantry_parse_daily
// buckets at module load so tests don't trip RATE-01 on shared localhost.
await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface HttpResult {
  status: number;
  body: Record<string, unknown>;
}

async function callPantryParse(
  body: unknown,
  jwt: string | null,
): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/pantry-parse`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

Deno.test('pantry-parse: AUTH-01 when Authorization header missing', async () => {
  const res = await callPantryParse({ client_request_id: crypto.randomUUID() }, null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'missing');
});

Deno.test('pantry-parse: AUTH-01 malformed when header is not Bearer', async () => {
  const res = await callPantryParse(
    { client_request_id: crypto.randomUUID() },
    'not-a-real-token',
  );
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'malformed');
});

Deno.test('pantry-parse: METHOD-NOT-ALLOWED-01 on GET', async () => {
  const res = await fetch(`${FUNCTIONS_URL}/pantry-parse`, { method: 'GET' });
  assertEquals(res.status, 405);
  const body = await res.json();
  assertEquals(body.error, 'METHOD-NOT-ALLOWED-01');
  assertEquals(body.allowed, ['POST']);
});

Deno.test('pantry-parse: VAL-01 on missing client_request_id', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse({}, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: VAL-01 on non-UUID client_request_id', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse({
    client_request_id: 'not-a-uuid',
    image_base64: 'A'.repeat(200),
    image_mime_type: 'image/jpeg',
  }, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: VAL-01 on unsupported MIME', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
    image_base64: 'A'.repeat(200),
    image_mime_type: 'image/tiff',
  }, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: ENT-MULTI-IMAGE-01 on Free tier when sending images[]', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  // Fresh user is Free tier; multi-image array should be blocked at the
  // entitlement gate BEFORE any image-byte validation runs.
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
    images: [
      { base64: 'A'.repeat(200), mime_type: 'image/jpeg' },
      { base64: 'A'.repeat(200), mime_type: 'image/jpeg' },
    ],
  }, boot.session_jwt);
  assertEquals(res.status, 403);
  assertEquals(res.body.error, 'ENT-MULTI-IMAGE-01');
  assertEquals(res.body.current_tier, 'free');
});

Deno.test('pantry-parse: VAL-01 when neither image_base64 nor images[] is provided', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
  }, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: VAL-01 when both image_base64 AND images[] are provided', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
    image_base64: 'A'.repeat(200),
    image_mime_type: 'image/jpeg',
    images: [
      { base64: 'A'.repeat(200), mime_type: 'image/jpeg' },
      { base64: 'A'.repeat(200), mime_type: 'image/jpeg' },
    ],
  }, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: VAL-01 when images.length exceeds the 4-photo cap', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
    images: Array.from({ length: 5 }, () => ({
      base64: 'A'.repeat(200),
      mime_type: 'image/jpeg',
    })),
  }, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: VAL-01 when extra unknown field included (strict mode)', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  // SCA-36 W8: legacy clients sending the dropped `image_count` field
  // get VAL-01 from `.strict()` rather than a checksum-mismatch error.
  // No iOS client today sends this field; the test pins the strict
  // rejection so a future legacy-client regression surfaces clearly.
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
    image_base64: 'A'.repeat(200),
    image_mime_type: 'image/jpeg',
    image_count: 1,
  }, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: VAL-01 on invalid JSON body', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse('not json', boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('pantry-parse: Pro tier passes entitlement gate on multi-image (SCA-36 W17)', async () => {
  // Happy-path coverage for the multi-image entitlement gate. We don't
  // need real magic-byte JPEGs to assert this — the fact that the
  // entitlement check (handler step 5) is BEFORE image validation
  // (step 5a) means a Pro user with bad bytes lands on
  // image_validation_failed (VAL-01 with field path images[N]), NOT on
  // ENT-MULTI-IMAGE-01. The previous test corpus only asserted the
  // denial side; this pins the allow side.
  const boot = await quickBootstrapPro();
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
    images: [
      { base64: 'A'.repeat(200), mime_type: 'image/jpeg' },
      { base64: 'A'.repeat(200), mime_type: 'image/jpeg' },
    ],
  }, boot.session_jwt);
  assertEquals(res.status, 400, 'Pro tier should not be tier-blocked');
  assertEquals(res.body.error, 'VAL-01');
  assertNotEquals(
    res.body.error,
    'ENT-MULTI-IMAGE-01',
    'Pro tier must pass the entitlement gate to image validation',
  );
  // Field path should localize to the first image so dashboards can
  // surface which photo failed.
  const fieldErrors = res.body.field_errors as Array<{ field: string; issue: string }> | undefined;
  if (Array.isArray(fieldErrors) && fieldErrors.length > 0) {
    const firstField = fieldErrors[0]?.field ?? '';
    if (!firstField.startsWith('images[')) {
      throw new Error(`expected images[N] field path, got '${firstField}'`);
    }
  }
});

Deno.test('prompt_versions: exactly one is_default per feature_key (SCA-36 S18)', async () => {
  // Migration-invariant test. The SCA-36 hardening of
  // 20260506000001_seed_prompt_versions_v1_1_pantry_parse_multi.sql
  // re-asserts the "exactly one is_default per feature_key" invariant
  // via UPDATE ... is_default = (version = '1.1.0'). This test pins
  // that invariant across all feature keys so a future migration
  // that demotes-without-promoting (the original bug class) surfaces
  // immediately.
  const client = serviceClient();
  const { data, error } = await client
    .from('prompt_versions')
    .select('feature_key, is_default');
  if (error) throw new Error(`prompt_versions read failed: ${error.message}`);
  const defaultsByFeature = new Map<string, number>();
  for (const row of data ?? []) {
    if ((row as { is_default: boolean }).is_default) {
      const key = (row as { feature_key: string }).feature_key;
      defaultsByFeature.set(key, (defaultsByFeature.get(key) ?? 0) + 1);
    }
  }
  for (const [feature, count] of defaultsByFeature) {
    assertEquals(
      count,
      1,
      `feature_key='${feature}' has ${count} is_default=TRUE rows; expected exactly 1`,
    );
  }
});
