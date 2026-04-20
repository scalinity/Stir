// cook_turn_test
//
// HTTP-level tests for /v1/ai/cook-turn. Like realtime_session_test.ts,
// covers paths that exercise auth / validation / entitlement without
// requiring a real Gemini round-trip (happy-path eval is in the eval
// harness, not CI).

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

async function callCookTurn(
  body: unknown,
  jwt: string | null,
  method: string = 'POST',
): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const init: RequestInit = { method, headers };
  if (method !== 'GET' && body !== undefined) {
    init.body = typeof body === 'string' ? body : JSON.stringify(body);
  }
  const res = await fetch(`${FUNCTIONS_URL}/cook-turn`, init);
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

function validBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    client_request_id: crypto.randomUUID(),
    cooking_session_id: crypto.randomUUID(),
    recipe_plan_id: crypto.randomUUID(),
    current_step_number: 1,
    transcript: 'how hot should the oil be',
    recipe_context: {
      title: 'Tomato Cream Pasta',
      servings: 2,
      estimated_minutes: 20,
      total_steps: 5,
      current_step_text: 'Heat olive oil in a skillet over medium heat.',
      current_step_timer_seconds: 120,
      remaining_ingredients: [{ display_name: 'pasta' }],
    },
    household_context: {
      dietary_rules: [],
      available_equipment: ['stovetop', 'skillet'],
      pantry_snapshot: [{ display_name: 'olive oil' }],
    },
    ...overrides,
  };
}

async function promoteToPremium(canonicalKey: string): Promise<void> {
  const client = serviceClient();
  const { error } = await client.from('entitlement_snapshots').upsert({
    canonical_user_key: canonicalKey,
    tier: 'premium',
    billing_state: 'active',
    is_trial: false,
    expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  }, { onConflict: 'canonical_user_key' });
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// AUTH-01
// ---------------------------------------------------------------------------

Deno.test('cook-turn: AUTH-01 when Authorization header missing', async () => {
  const res = await callCookTurn(validBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'missing');
});

Deno.test('cook-turn: AUTH-01 malformed on non-Bearer', async () => {
  const res = await callCookTurn(validBody(), 'not-a-jwt');
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'malformed');
});

// ---------------------------------------------------------------------------
// METHOD-NOT-ALLOWED-01
// ---------------------------------------------------------------------------

Deno.test('cook-turn: METHOD-NOT-ALLOWED-01 on GET', async () => {
  const bs = await quickBootstrap();
  const res = await callCookTurn(undefined, bs.session_jwt, 'GET');
  assertEquals(res.status, 405);
  assertEquals(res.body.error, 'METHOD-NOT-ALLOWED-01');
});

// ---------------------------------------------------------------------------
// VAL-01
// ---------------------------------------------------------------------------

Deno.test('cook-turn: VAL-01 on missing transcript', async () => {
  const bs = await quickBootstrap();
  const body = validBody();
  delete body.transcript;
  const res = await callCookTurn(body, bs.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('cook-turn: VAL-01 on transcript exceeding 500 chars', async () => {
  const bs = await quickBootstrap();
  const res = await callCookTurn(validBody({ transcript: 'a'.repeat(501) }), bs.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('cook-turn: VAL-01 on non-UUID client_request_id', async () => {
  const bs = await quickBootstrap();
  const res = await callCookTurn(validBody({ client_request_id: 'not-a-uuid' }), bs.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('cook-turn: VAL-01 on invalid JSON body', async () => {
  const bs = await quickBootstrap();
  const res = await callCookTurn('{not json', bs.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// ENT-VOICE-01 — cook-turn is the voice fallback; still Premium+ only
// ---------------------------------------------------------------------------

Deno.test('cook-turn: ENT-VOICE-01 on Free user', async () => {
  const bs = await quickBootstrap();
  const res = await callCookTurn(validBody(), bs.session_jwt);
  assertEquals(res.status, 403);
  assertEquals(res.body.error, 'ENT-VOICE-01');
  assertEquals(res.body.tier, 'free');
});

// ---------------------------------------------------------------------------
// Premium reaches Gemini (502 AI-01 on placeholder key, proves pre-Gemini
// logic OK). Skipped on the integration-test path.
// ---------------------------------------------------------------------------

Deno.test('cook-turn: Premium user reaches Gemini call (502 AI-01 on placeholder key)', async () => {
  if (Deno.env.get('STIR_RUN_AI_INTEGRATION_TESTS') === '1') return;
  const bs = await quickBootstrap();
  await promoteToPremium(bs.canonical_user_key);
  const res = await callCookTurn(validBody(), bs.session_jwt);
  assertEquals(res.status, 502);
  assertEquals(res.body.error, 'AI-01');
});
