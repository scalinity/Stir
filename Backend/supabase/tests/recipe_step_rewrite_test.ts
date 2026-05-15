// recipe_step_rewrite_test
//
// HTTP-level tests for /v1/ai/recipe-step-rewrite (SCA-432) — exercises
// paths BEFORE the Gemini call (auth, validation, method) and the
// idempotency cache. Happy-path Gemini round-trips live in the eval
// harness, not CI.

import { assertEquals, assertNotEquals } from '@std/assert';
import { quickBootstrap, testInstallId, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

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

// ---------------------------------------------------------------------------
// SCA-432 review-fix regression: cache-namespacing
// ---------------------------------------------------------------------------
//
// The accept flow calls /v1/ai/substitution then /v1/ai/recipe-step-rewrite
// with the SAME sub_event_id. `ai_response_cache`'s PK is (canonical_user_key,
// request_id) — feature_key is NOT part of the key (migration
// 20260418000024). Without namespacing, rewrite's readCache would hit
// substitution's body and iOS would decode it as a RecipeStepRewriteResponse
// (missing `rewritten_text`) and the rewrite would never land.
//
// This test seeds the cache with a fake substitution-shaped body under the
// bare sub_event_id, then calls recipe-step-rewrite with that sub_event_id.
// If the handler is correctly namespaced, the readCache miss falls through
// to the Gemini call (which we don't mock — but the response shape, not the
// content, is what we assert: rewritten_text vs substitution_text).
Deno.test(
  "recipe-step-rewrite: does NOT replay substitution's cache body under shared sub_event_id",
  async () => {
    const boot = await quickBootstrap({ installation_id: testInstallId() });
    const subEventId = crypto.randomUUID();
    // Seed the cache with a substitution-shaped body under the BARE
    // sub_event_id (mimicking what /v1/ai/substitution would write).
    const sb = serviceClient();
    const { error: seedErr } = await sb.from('ai_response_cache').insert({
      canonical_user_key: boot.canonical_user_key,
      request_id: subEventId,
      response_body: {
        sub_event_id: subEventId,
        substitution_text: 'POISON: should not surface as rewritten_text',
        amount_conversion: null,
        constraint_safe: true,
        constraint_violation_reason: null,
        reasoning: 'cache-poison test',
        confidence: 'high',
        prompt_version: 'test-1.0.0',
        latency_ms: 1,
        retry_count: 0,
      },
      status_code: 200,
      feature_key: 'substitution',
    });
    if (seedErr) throw seedErr;

    const res = await callRewrite(validBody({ sub_event_id: subEventId }), boot.session_jwt);
    // The substitution-shaped body would carry `substitution_text`. The
    // rewrite path either returns `rewritten_text` (happy path) or a
    // 502/AI-02 (Gemini failure / no_active_prompt) — either way, the
    // poison string must NOT appear on the wire.
    assertNotEquals(res.body.substitution_text, 'POISON: should not surface as rewritten_text');
    // And we should never see substitution-only keys leak through.
    assertEquals(
      res.body.substitution_text,
      undefined,
      'substitution_text on the rewrite wire body means the cache namespacing is broken',
    );
    assertEquals(
      res.body.constraint_safe,
      undefined,
      'constraint_safe on the rewrite wire body means the cache namespacing is broken',
    );
  },
);
