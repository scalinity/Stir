// substitution_test
//
// HTTP-level tests for /v1/ai/substitution that exercise paths BEFORE
// the Gemini call — AUTH-01, VAL-01, METHOD-NOT-ALLOWED, idempotency
// cache replay. Live-Gemini happy-path tests are in the eval harness
// (Backend/evals/substitutions/) behind STIR_RUN_AI_EVALS=1 so they
// don't burn paid-tier credits on every CI run.

import { assertEquals } from '@std/assert';
import { quickBootstrap, testInstallId, testSourceIP } from './_helpers/factory.ts';
import { serviceClient } from './_helpers/pg.ts';

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface HttpResult {
  status: number;
  body: Record<string, unknown>;
}

async function callSubstitution(
  body: unknown,
  jwt: string | null,
): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    'x-forwarded-for': testSourceIP(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/substitution`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

function validBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    sub_event_id: crypto.randomUUID(),
    cooking_session_id: crypto.randomUUID(),
    recipe_plan_id: crypto.randomUUID(),
    missing_ingredient: { display_name: 'heavy cream' },
    user_problem: 'out of heavy cream',
    household_context: {
      dietary_rules: [],
      available_equipment: ['stovetop', 'skillet'],
      pantry_snapshot: [{ display_name: 'whole milk' }, { display_name: 'butter' }],
    },
    recipe_context: {
      title: 'Tomato Cream Pasta',
      current_step_number: 2,
      total_steps: 5,
      remaining_ingredients: [{ display_name: 'pasta' }, { display_name: 'garlic' }],
    },
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// AUTH-01
// ---------------------------------------------------------------------------

Deno.test('substitution: AUTH-01 when Authorization header missing', async () => {
  const res = await callSubstitution(validBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'missing');
});

Deno.test('substitution: AUTH-01 malformed on non-Bearer', async () => {
  const res = await callSubstitution(validBody(), 'not-a-jwt');
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'malformed');
});

// ---------------------------------------------------------------------------
// METHOD-NOT-ALLOWED
// ---------------------------------------------------------------------------

Deno.test('substitution: METHOD-NOT-ALLOWED-01 on GET', async () => {
  const res = await fetch(`${FUNCTIONS_URL}/substitution`, { method: 'GET' });
  assertEquals(res.status, 405);
  const body = await res.json();
  assertEquals(body.error, 'METHOD-NOT-ALLOWED-01');
  assertEquals(body.allowed, ['POST']);
});

// ---------------------------------------------------------------------------
// VAL-01
// ---------------------------------------------------------------------------

Deno.test('substitution: VAL-01 on missing sub_event_id', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const body = validBody();
  delete body.sub_event_id;
  const res = await callSubstitution(body, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('substitution: VAL-01 on non-UUID sub_event_id', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callSubstitution(
    validBody({ sub_event_id: 'not-a-uuid' }),
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('substitution: VAL-01 on user_problem exceeding 500 chars', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callSubstitution(
    validBody({ user_problem: 'x'.repeat(501) }),
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('substitution: VAL-01 on missing missing_ingredient', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const body = validBody();
  delete body.missing_ingredient;
  const res = await callSubstitution(body, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('substitution: VAL-01 on invalid JSON body', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await fetch(`${FUNCTIONS_URL}/substitution`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'authorization': `Bearer ${boot.session_jwt}`,
      'x-forwarded-for': testSourceIP(),
    },
    body: '{not-valid-json',
  });
  assertEquals(res.status, 400);
  const body = await res.json();
  assertEquals(body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// Idempotency cache
// ---------------------------------------------------------------------------

Deno.test('substitution: idempotency cache returns prior response for same sub_event_id', async () => {
  // Seed the ai_response_cache directly — sub_event_id in the request
  // must hit the cached row and return the cached body verbatim,
  // regardless of what Gemini would return (Gemini never gets called
  // on a cache hit).
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const admin = serviceClient();
  const subEventId = crypto.randomUUID();
  const cachedBody = {
    sub_event_id: subEventId,
    substitution_text: 'Use the pantry swap you already confirmed.',
    amount_conversion: null,
    constraint_safe: true,
    constraint_violation_reason: null,
    reasoning: 'Cached from a prior call.',
    confidence: 'high',
    prompt_version: '1.0.0',
    latency_ms: 123,
    retry_count: 0,
  };
  await admin.from('ai_response_cache').insert({
    request_id: subEventId,
    response_body: cachedBody,
    status_code: 200,
    feature_key: 'substitution',
  });

  const res = await callSubstitution(
    validBody({ sub_event_id: subEventId }),
    boot.session_jwt,
  );
  assertEquals(res.status, 200);
  assertEquals(res.body.substitution_text, cachedBody.substitution_text);
  assertEquals(res.body.reasoning, cachedBody.reasoning);
});
