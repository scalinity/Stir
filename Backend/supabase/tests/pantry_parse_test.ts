// pantry_parse_test
//
// HTTP-level tests for /v1/ai/pantry-parse that exercise paths BEFORE
// the Gemini call — VAL-01 validation, AUTH-01, ENT-MULTI-IMAGE-01.
// Happy-path integration tests are gated on STIR_RUN_AI_INTEGRATION_TESTS=1
// so CI runs don't burn the paid-tier budget.

import { assertEquals } from '@std/assert';
import { quickBootstrap, testInstallId, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets } from './_helpers/pg.ts';

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

Deno.test('pantry-parse: ENT-MULTI-IMAGE-01 when image_count>1 on Free tier', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  // Fresh user is Free tier; image_count=2 should be blocked.
  const res = await callPantryParse({
    client_request_id: crypto.randomUUID(),
    image_base64: 'A'.repeat(200),
    image_mime_type: 'image/jpeg',
    image_count: 2,
  }, boot.session_jwt);
  assertEquals(res.status, 403);
  assertEquals(res.body.error, 'ENT-MULTI-IMAGE-01');
  assertEquals(res.body.current_tier, 'free');
});

Deno.test('pantry-parse: VAL-01 on invalid JSON body', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callPantryParse('not json', boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});
