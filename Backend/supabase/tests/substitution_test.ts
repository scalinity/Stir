// substitution_test
//
// HTTP-level tests for /v1/ai/substitution that exercise paths BEFORE
// the Gemini call — AUTH-01, VAL-01, METHOD-NOT-ALLOWED, idempotency
// cache replay. Live-Gemini happy-path tests are in the eval harness
// (Backend/evals/substitutions/) behind STIR_RUN_AI_EVALS=1 so they
// don't burn paid-tier credits on every CI run.

import { assertEquals } from '@std/assert';
import { quickBootstrap, testInstallId, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

// Kong overrides x-real-ip; clear ip:bootstrap_hourly + ip:substitution_daily
// buckets at module load so tests don't trip RATE-01 on shared localhost.
await clearRateLimitBuckets();

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
    ...testIPHeaders(),
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
      ...testIPHeaders(),
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

Deno.test('substitution: idempotency cache returns prior response for same (user, sub_event_id)', async () => {
  // Seed the ai_response_cache directly — sub_event_id in the request
  // must hit the cached row and return the cached body verbatim,
  // regardless of what Gemini would return (Gemini never gets called
  // on a cache hit). Seed with the SAME canonical_user_key the
  // bootstrap minted so the user-scoped read matches.
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
    canonical_user_key: boot.canonical_user_key,
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

Deno.test('substitution: SA2-01 — cached response for user A is NOT replayed for user B on same sub_event_id', async () => {
  // Seed a cache row under user A, then send the SAME sub_event_id as user
  // B. User B's lookup must miss (different canonical_user_key), so the
  // handler must NOT return A's cached body. The request will proceed past
  // the cache and try to call Gemini — in this no-key test harness that
  // trips the 'no active prompt' guard or an upstream error, but the key
  // assertion is simply that B's response body does NOT match A's cached
  // substitution_text / reasoning.
  const bootA = await quickBootstrap({ installation_id: testInstallId() });
  const bootB = await quickBootstrap({ installation_id: testInstallId() });
  const admin = serviceClient();
  const sharedSubEventId = crypto.randomUUID();
  const userACachedBody = {
    sub_event_id: sharedSubEventId,
    substitution_text: "USER A'S SECRET RECIPE NAME",
    amount_conversion: null,
    constraint_safe: true,
    constraint_violation_reason: null,
    reasoning: "User A's reasoning that must never leak to user B.",
    confidence: 'high',
    prompt_version: '1.0.0',
    latency_ms: 100,
    retry_count: 0,
  };
  await admin.from('ai_response_cache').insert({
    canonical_user_key: bootA.canonical_user_key,
    request_id: sharedSubEventId,
    response_body: userACachedBody,
    status_code: 200,
    feature_key: 'substitution',
  });

  const res = await callSubstitution(
    validBody({ sub_event_id: sharedSubEventId }),
    bootB.session_jwt,
  );
  // The exact response depends on downstream state (Gemini key, prompt
  // rows), but under no circumstance should B see A's cached body.
  if (res.status === 200) {
    // If handler returned a 200, it must NOT be A's cached body.
    if (
      res.body.substitution_text === userACachedBody.substitution_text ||
      res.body.reasoning === userACachedBody.reasoning
    ) {
      throw new Error(
        "SA2-01 REGRESSION: user B received user A's cached substitution response",
      );
    }
  }
  // Any non-200 (e.g. AI-01 / AI-02 from missing Gemini key in test env)
  // is fine here — the point is that the cache replay did NOT occur.
});
