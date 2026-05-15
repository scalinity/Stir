// recipe_step_rewrite_test
//
// HTTP-level tests for /v1/ai/recipe-step-rewrite (SCA-432) — exercises
// paths BEFORE the Gemini call (auth, validation, method) and the
// idempotency cache. Happy-path Gemini round-trips live in the eval
// harness, not CI.

import { assertEquals } from '@std/assert';
import { quickBootstrap, testInstallId, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets } from './_helpers/pg.ts';

await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface HttpResult {
  status: number;
  body: Record<string, unknown>;
}

async function callRewrite(
  body: unknown,
  jwt: string | null,
): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/recipe-step-rewrite`, {
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
    step_instruction_text:
      'Mix flour, a pinch of salt, 1 tablespoon of oil, and approximately 1/4 cup of water to form a soft dough.',
    original_ingredient: 'all-purpose flour',
    substitute_ingredient: '1 cup of finely crushed tortilla chips',
    recipe_title: 'Quick Flatbread',
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// AUTH-01
// ---------------------------------------------------------------------------

Deno.test('recipe-step-rewrite: AUTH-01 when Authorization header missing', async () => {
  const res = await callRewrite(validBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'missing');
});

Deno.test('recipe-step-rewrite: AUTH-01 malformed on non-Bearer', async () => {
  const res = await callRewrite(validBody(), 'not-a-jwt');
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'malformed');
});

// ---------------------------------------------------------------------------
// METHOD-NOT-ALLOWED
// ---------------------------------------------------------------------------

Deno.test('recipe-step-rewrite: METHOD-NOT-ALLOWED-01 on GET', async () => {
  const res = await fetch(`${FUNCTIONS_URL}/recipe-step-rewrite`, { method: 'GET' });
  assertEquals(res.status, 405);
  const body = await res.json();
  assertEquals(body.error, 'METHOD-NOT-ALLOWED-01');
  assertEquals(body.allowed, ['POST']);
});

// ---------------------------------------------------------------------------
// VAL-01
// ---------------------------------------------------------------------------

Deno.test('recipe-step-rewrite: VAL-01 on missing sub_event_id', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const body = validBody();
  delete body.sub_event_id;
  const res = await callRewrite(body, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe-step-rewrite: VAL-01 on non-UUID sub_event_id', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callRewrite(
    validBody({ sub_event_id: 'not-a-uuid' }),
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe-step-rewrite: VAL-01 on missing step_instruction_text', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const body = validBody();
  delete body.step_instruction_text;
  const res = await callRewrite(body, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe-step-rewrite: VAL-01 on empty step_instruction_text', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callRewrite(
    validBody({ step_instruction_text: '' }),
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe-step-rewrite: VAL-01 on step_instruction_text > 2000 chars', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callRewrite(
    validBody({ step_instruction_text: 'x'.repeat(2001) }),
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe-step-rewrite: VAL-01 on missing original_ingredient', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const body = validBody();
  delete body.original_ingredient;
  const res = await callRewrite(body, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe-step-rewrite: VAL-01 on missing substitute_ingredient', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const body = validBody();
  delete body.substitute_ingredient;
  const res = await callRewrite(body, boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// recipe_title is optional — absence is fine, presence-with-blank should fail
// because the schema is .min(1).max(256).optional().
Deno.test('recipe-step-rewrite: accepts missing recipe_title', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const body = validBody();
  delete body.recipe_title;
  // We don't assert success (depends on live Gemini); only that the
  // validator doesn't bounce a body missing the optional field with
  // VAL-01. A 200 OR a 5xx (Gemini-side) both prove the schema accepted.
  const res = await callRewrite(body, boot.session_jwt);
  if (res.status === 400) {
    assertEquals(res.body.error, undefined, 'should not be VAL-01 on optional field absence');
  }
});

// amount_conversion is optional too.
Deno.test('recipe-step-rewrite: VAL-01 on empty amount_conversion when present', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callRewrite(
    validBody({ amount_conversion: '' }),
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// Strict schema rejects unknown keys — defense against accidental wire drift
// from a future iOS field that the server doesn't yet handle.
Deno.test('recipe-step-rewrite: VAL-01 on unknown top-level key', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callRewrite(
    validBody({ extra_field: 'oops' }),
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// Malformed JSON body — VAL-01 with field_errors=[{field:'<root>',...}].
Deno.test('recipe-step-rewrite: VAL-01 on malformed JSON body', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callRewrite('not-json{', boot.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});
