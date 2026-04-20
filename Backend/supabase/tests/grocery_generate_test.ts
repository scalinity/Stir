// grocery_generate_test
//
// HTTP-level tests for /v1/ai/grocery-generate — AUTH-01, VAL-01, METHOD,
// idempotency replay. grocery_generate is unmetered across all tiers, so
// there's no quota-gate test. Live Gemini happy-path runs in the eval
// harness.

import { assertEquals, assertExists } from '@std/assert';
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

async function callGroceryGenerate(body: unknown, jwt: string | null): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/grocery-generate`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

function validBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    source_id: crypto.randomUUID(),
    source_type: 'recipe',
    ingredients_needed: [
      { display_name: 'chicken thighs', amount_text: '1.5 lbs' },
      { display_name: 'olive oil', amount_text: '2 tbsp' },
      { display_name: 'garlic', amount_text: '4 cloves' },
    ],
    pantry_snapshot: [
      { display_name: 'olive oil' },
      { display_name: 'salt' },
    ],
    recipe_title: 'Garlic Roasted Chicken Thighs',
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// AUTH-01
// ---------------------------------------------------------------------------

Deno.test('grocery_generate: AUTH-01 on missing Authorization', async () => {
  const res = await callGroceryGenerate(validBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'missing');
});

// ---------------------------------------------------------------------------
// VAL-01
// ---------------------------------------------------------------------------

Deno.test('grocery_generate: VAL-01 when source_id is not a UUID', async () => {
  const { session_jwt } = await quickBootstrap();
  const res = await callGroceryGenerate(validBody({ source_id: 'not-a-uuid' }), session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('grocery_generate: VAL-01 when ingredients_needed is empty', async () => {
  const { session_jwt } = await quickBootstrap();
  const res = await callGroceryGenerate(validBody({ ingredients_needed: [] }), session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('grocery_generate: VAL-01 when source_type is invalid', async () => {
  const { session_jwt } = await quickBootstrap();
  const res = await callGroceryGenerate(validBody({ source_type: 'banana' }), session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// Idempotency replay
// ---------------------------------------------------------------------------

Deno.test('grocery_generate: idempotency — same source_id returns cache', async () => {
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const sourceId = crypto.randomUUID();
  const client = serviceClient();
  await client.from('ai_response_cache').insert({
    canonical_user_key,
    request_id: sourceId,
    response_body: {
      source_id: sourceId,
      source_type: 'recipe',
      missing_items: [
        {
          display_name: 'chicken thighs',
          amount_text: '1.5 lbs',
          canonical_slug: null,
          grocery_category: 'meat',
          priority: 'high',
        },
      ],
      already_have: [{ display_name: 'olive oil' }],
      total_item_count: 1,
      prompt_version: '1.0.0',
      retry_count: 0,
    },
    status_code: 200,
    feature_key: 'grocery_generate',
  });

  const res = await fetch(`${FUNCTIONS_URL}/grocery-generate`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      Authorization: `Bearer ${session_jwt}`,
      ...testIPHeaders(),
    },
    body: JSON.stringify(validBody({ source_id: sourceId })),
  });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get('x-cache'), 'hit');
  const body = await res.json();
  assertEquals(Array.isArray(body.missing_items), true);
  // priority field is required on every missing_items row per spec §4.17.
  for (const item of body.missing_items as Array<{ priority?: string }>) {
    assertExists(item.priority);
  }
});
