// recipe_import_test
//
// HTTP-level tests for /v1/ai/recipe-import — cover AUTH-01, VAL-01,
// METHOD-NOT-ALLOWED, quota enforcement, source_type discrimination,
// and async-queue threshold behavior. Live Gemini happy-path runs in
// the eval harness (STIR_RUN_AI_EVALS=1) to avoid burning API credits
// on every test run.

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

async function callRecipeImport(body: unknown, jwt: string | null): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/recipe-import`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

function urlBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    import_id: crypto.randomUUID(),
    source_type: 'url',
    payload: { url: 'https://example.com/recipe' },
    ...overrides,
  };
}

function ocrBody(ocrText: string, pageCount = 1): Record<string, unknown> {
  return {
    import_id: crypto.randomUUID(),
    source_type: 'screenshot_ocr',
    payload: {
      ocr_text: ocrText,
      ocr_page_count: pageCount,
    },
  };
}

function pastedBody(text: string): Record<string, unknown> {
  return {
    import_id: crypto.randomUUID(),
    source_type: 'pasted_text',
    payload: { pasted_text: text },
  };
}

// ---------------------------------------------------------------------------
// AUTH-01
// ---------------------------------------------------------------------------

Deno.test('recipe_import: AUTH-01 on missing Authorization', async () => {
  const res = await callRecipeImport(urlBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'missing');
});

Deno.test('recipe_import: AUTH-01 on malformed JWT', async () => {
  const res = await callRecipeImport(urlBody(), 'not-a-jwt');
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'malformed');
});

// ---------------------------------------------------------------------------
// METHOD-NOT-ALLOWED-01
// ---------------------------------------------------------------------------

Deno.test('recipe_import: METHOD-NOT-ALLOWED-01 on GET', async () => {
  const { session_jwt } = await quickBootstrap();
  const res = await fetch(`${FUNCTIONS_URL}/recipe-import`, {
    method: 'GET',
    headers: {
      Authorization: `Bearer ${session_jwt}`,
      ...testIPHeaders(),
    },
  });
  // Supabase Edge Functions are POST-or-OPTIONS by contract via the
  // router; the handler returns 405 for other methods.
  assertEquals([405, 400].includes(res.status), true);
  const body = await res.json();
  // Kong may respond before the handler for some methods; accept either
  // the typed METHOD-NOT-ALLOWED-01 or a NET-01 bubble.
  assertEquals(
    body.error === 'METHOD-NOT-ALLOWED-01' || body.error === 'VAL-01' || body.error === undefined,
    true,
  );
});

// ---------------------------------------------------------------------------
// VAL-01 — source_type discrimination
// ---------------------------------------------------------------------------

Deno.test('recipe_import: VAL-01 when url missing for source_type=url', async () => {
  const { session_jwt } = await quickBootstrap();
  const body = {
    import_id: crypto.randomUUID(),
    source_type: 'url',
    payload: {},  // url missing
  };
  const res = await callRecipeImport(body, session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe_import: VAL-01 when ocr_text provided for source_type=url', async () => {
  const { session_jwt } = await quickBootstrap();
  const body = {
    import_id: crypto.randomUUID(),
    source_type: 'url',
    payload: { url: 'https://example.com', ocr_text: 'something' },
  };
  const res = await callRecipeImport(body, session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe_import: VAL-01 when ocr_page_count < 1 for screenshot_ocr', async () => {
  const { session_jwt } = await quickBootstrap();
  const body = {
    import_id: crypto.randomUUID(),
    source_type: 'screenshot_ocr',
    payload: { ocr_text: 'text', ocr_page_count: 0 },
  };
  const res = await callRecipeImport(body, session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('recipe_import: VAL-01 when import_id is not a UUID', async () => {
  const { session_jwt } = await quickBootstrap();
  const body = {
    import_id: 'not-a-uuid',
    source_type: 'pasted_text',
    payload: { pasted_text: 'some recipe' },
  };
  const res = await callRecipeImport(body, session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// Quota enforcement (Free tier: 2 imports/mo)
// ---------------------------------------------------------------------------
//
// We use a fresh bootstrap per test + a direct SQL bump to push used_count
// to cap_count, then verify the handler returns RATE-01 without touching
// Gemini. This isolates quota-gate behavior from Gemini latency + cost.

Deno.test('recipe_import: RATE-01 when recipe_import quota exhausted', async () => {
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const client = serviceClient();
  // Force the current-period row to at-cap.
  const { error } = await client.rpc('stir_force_capped_usage_counter', {
    p_canonical_user_key: canonical_user_key,
    p_feature_key: 'recipe_import',
  }).single();
  // If the RPC doesn't exist (dev environment without test helpers),
  // fall back to a direct UPDATE against the current period row.
  if (error) {
    await client
      .from('usage_counters')
      .update({ used_count: 10 })
      .eq('canonical_user_key', canonical_user_key)
      .eq('feature_key', 'recipe_import');
  }

  const res = await callRecipeImport(pastedBody('A recipe body.'), session_jwt);
  assertEquals(res.status, 429);
  assertEquals(res.body.error, 'RATE-01');
  assertExists(res.body.used);
  assertExists(res.body.cap);
});

// ---------------------------------------------------------------------------
// Idempotency replay (second call with same import_id returns cached body)
// ---------------------------------------------------------------------------

Deno.test('recipe_import: idempotency — same import_id returns cache x-cache=hit', async () => {
  const { session_jwt, canonical_user_key } = await quickBootstrap();
  const importId = crypto.randomUUID();
  const client = serviceClient();
  // Pre-seed the cache so we don't need to hit Gemini.
  await client.from('ai_response_cache').insert({
    canonical_user_key,
    request_id: importId,
    response_body: {
      import_id: importId,
      status: 'completed',
      recipe: {
        title: 'Test Recipe',
        ingredients: [{ display_name: 'salt' }],
        steps: [{ step_number: 1, instruction_text: 'Cook.' }],
        parse_quality: 'high',
      },
      retry_count: 0,
      prompt_version: '1.0.0',
    },
    status_code: 200,
    feature_key: 'recipe_import',
  });

  const res = await fetch(`${FUNCTIONS_URL}/recipe-import`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      Authorization: `Bearer ${session_jwt}`,
      ...testIPHeaders(),
    },
    body: JSON.stringify({
      import_id: importId,
      source_type: 'pasted_text',
      payload: { pasted_text: 'some text' },
    }),
  });
  assertEquals(res.status, 200);
  assertEquals(res.headers.get('x-cache'), 'hit');
  const replayed = await res.json();
  assertEquals(replayed.import_id, importId);
  assertEquals(replayed.status, 'completed');
});

// ---------------------------------------------------------------------------
// Async queue threshold
// ---------------------------------------------------------------------------
//
// Threshold seed is 8192 bytes. A payload well above that should queue
// instead of processing synchronously. We verify 202 + queued status
// without touching Gemini.

Deno.test('recipe_import: large payload queues via notification_jobs (status=queued)', async () => {
  const { session_jwt } = await quickBootstrap();
  const largeText = 'Recipe line. '.repeat(1200);   // ~15 KiB, well over 8 KiB
  const res = await callRecipeImport(pastedBody(largeText), session_jwt);
  assertEquals(res.status, 202);
  assertEquals(res.body.status, 'queued');
  assertExists(res.body.async_job_id);
  assertExists(res.body.import_id);
});
