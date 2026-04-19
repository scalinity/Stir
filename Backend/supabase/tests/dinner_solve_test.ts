// dinner_solve_test
//
// HTTP-level tests for /v1/ai/dinner-solve covering the paths that fail
// BEFORE the Gemini call (VAL-01, AUTH-01) + the quota path that would
// also fail pre-Gemini if we could set it up without actually running
// a solve. Happy-path gated on STIR_RUN_AI_INTEGRATION_TESTS=1.
//
// Quota exhaustion: we seed used_count = cap via the service-role
// client, then assert the handler returns RATE-01 before calling Gemini.

import { assertEquals, assertNotEquals } from '@std/assert';
import { quickBootstrap, testInstallId, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

// Kong overrides x-real-ip; clear ip:bootstrap_hourly + ip:dinner_solve_daily
// buckets at module load so tests don't trip RATE-01 on shared localhost.
await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface HttpResult {
  status: number;
  body: Record<string, unknown> | null;
  raw: string;
}

async function callDinnerSolve(
  body: unknown,
  jwt: string | null,
): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/dinner-solve`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const raw = await res.text();
  let parsed: Record<string, unknown> | null = null;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // non-JSON — e.g. SSE stream; leave parsed null
  }
  return { status: res.status, body: parsed, raw };
}

function validBody() {
  return {
    solve_request_id: crypto.randomUUID(),
    ingredients: [{ display_name: 'tomato' }],
    household_context: {
      servings: 2,
      dietary_rules: [],
      available_equipment: ['stovetop', 'oven'],
    },
  };
}

Deno.test('dinner-solve: AUTH-01 when Authorization header missing', async () => {
  const res = await callDinnerSolve(validBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body?.error, 'AUTH-01');
});

Deno.test('dinner-solve: METHOD-NOT-ALLOWED-01 on GET', async () => {
  const res = await fetch(`${FUNCTIONS_URL}/dinner-solve`, { method: 'GET' });
  assertEquals(res.status, 405);
  const body = await res.json();
  assertEquals(body.error, 'METHOD-NOT-ALLOWED-01');
  assertEquals(body.allowed, ['POST']);
});

Deno.test('dinner-solve: VAL-01 when ingredients missing', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callDinnerSolve(
    {
      solve_request_id: crypto.randomUUID(),
      household_context: { servings: 2, dietary_rules: [], available_equipment: [] },
    },
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
});

Deno.test('dinner-solve: VAL-01 when solve_request_id is not a UUID', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const bodyOut = { ...validBody(), solve_request_id: 'not-a-uuid' };
  const res = await callDinnerSolve(bodyOut, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
});

Deno.test('dinner-solve: RATE-01 monthly quota when used_count == cap', async () => {
  const installId = testInstallId();
  const boot = await quickBootstrap({ installation_id: installId });

  // Seed the user's dinner_solve counter at cap to simulate exhausted quota.
  const client = serviceClient();
  const { error } = await client
    .from('usage_counters')
    .update({ used_count: 6 })
    .eq('canonical_user_key', boot.canonical_user_key)
    .eq('feature_key', 'dinner_solve');
  if (error) throw error;

  const res = await callDinnerSolve(validBody(), boot.session_jwt);
  assertEquals(res.status, 429);
  assertEquals(res.body?.error, 'RATE-01');
  assertEquals(res.body?.scope, 'user:dinner_solve_monthly');
  assertEquals(res.body?.used, 6);
  assertEquals(res.body?.cap, 6);
});

Deno.test('dinner-solve: AUTH-01 when user_row missing (broken JWT with phantom sub)', async () => {
  // This user doesn't exist in app_users. Bootstrap a user, then manually
  // DELETE their app_users row and re-use the JWT.
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const client = serviceClient();
  const { error } = await client
    .from('app_users')
    .delete()
    .eq('canonical_user_key', boot.canonical_user_key);
  if (error) throw error;

  const res = await callDinnerSolve(validBody(), boot.session_jwt);
  assertEquals(res.status, 401);
  assertNotEquals(res.body?.error, 'VAL-01', 'missing user should surface as AUTH-01 not VAL-01');
  assertEquals(res.body?.error, 'AUTH-01');
});
