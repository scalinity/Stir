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

// Leftovers mode (step 7): the same endpoint accepts a context_hint +
// leftovers_items. Validation here covers the refine guard rails.
Deno.test('dinner-solve: VAL-01 when context_hint=leftovers but leftovers_items missing', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callDinnerSolve(
    { ...validBody(), context_hint: 'leftovers' },
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
});

Deno.test('dinner-solve: VAL-01 when leftovers_items provided but context_hint!=leftovers', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callDinnerSolve(
    { ...validBody(), leftovers_items: [{ display_name: 'chili' }] },
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
});

Deno.test('dinner-solve: VAL-01 when context_hint=leftovers with empty leftovers_items', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const res = await callDinnerSolve(
    { ...validBody(), context_hint: 'leftovers', leftovers_items: [] },
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
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

// ---------------------------------------------------------------------------
// SCA-44 — feedback_summary (preference-memory digest)
// ---------------------------------------------------------------------------
//
// .strict() Zod on DinnerSolveRequest means the field MUST be declared
// or new clients sending it 400. These tests pin the schema contract
// from the wire side so an iOS DTO drift surfaces as a backend test
// failure, not a runtime VAL-01 dashboard alert.

function validFeedbackSummary() {
  return {
    recent_meal_count: 1,
    window_days: 30,
    recent_meals: [{
      title: 'Tomato Pasta',
      rating: 4,
      workload: 'easy',
      taste: 'good',
      spice_level: 'medium',
      would_repeat: true,
      cooked_days_ago: 3,
    }],
    aggregates: null,
    disliked_meals: [],
    highlight_notes: [],
  };
}

Deno.test('dinner-solve: well-formed feedback_summary parses (RATE-01 not VAL-01)', async () => {
  // Cap the quota so the request progresses past validation but stops
  // before the Gemini call. RATE-01 proves the body shape parsed.
  const installId = testInstallId();
  const boot = await quickBootstrap({ installation_id: installId });
  const client = serviceClient();
  const { error } = await client
    .from('usage_counters')
    .update({ used_count: 6 })
    .eq('canonical_user_key', boot.canonical_user_key)
    .eq('feature_key', 'dinner_solve');
  if (error) throw error;

  const res = await callDinnerSolve(
    { ...validBody(), feedback_summary: validFeedbackSummary() },
    boot.session_jwt,
  );
  assertEquals(res.status, 429);
  assertEquals(res.body?.error, 'RATE-01', 'feedback_summary should NOT trip VAL-01');
});

Deno.test('dinner-solve: VAL-01 when feedback_summary.recent_meals[].taste is unknown enum', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const fs = validFeedbackSummary();
  // 'hated' is not in the enum (loved | good | ok | bad).
  fs.recent_meals[0]!.taste = 'hated'; // SCA-280 typecheck fix: validFeedbackSummary guarantees ≥1 entry; non-null assertion satisfies noUncheckedIndexedAccess.
  const res = await callDinnerSolve(
    { ...validBody(), feedback_summary: fs },
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
});

Deno.test('dinner-solve: VAL-01 when feedback_summary.recent_meals exceeds 10 entries', async () => {
  const boot = await quickBootstrap({ installation_id: testInstallId() });
  const fs = validFeedbackSummary();
  // Pad to 11 entries — schema max is 10 (mirrors iOS recentMealsCap=10).
  const oneEntry = fs.recent_meals[0]!; // SCA-280 typecheck fix: validFeedbackSummary guarantees ≥1 entry.
  fs.recent_meals = Array.from({ length: 11 }, (_, i) => ({
    ...oneEntry,
    title: `Meal ${i}`,
  }));
  const res = await callDinnerSolve(
    { ...validBody(), feedback_summary: fs },
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
});

Deno.test('dinner-solve: kill switch — preference_memory_enabled=false still parses populated feedback_summary', async () => {
  // Regression guard for the kill-switch path. The handler reads the
  // flag and conditionally nullifies feedback_json; a future refactor
  // could silently drop the gate. We can't observe the rendered prompt
  // from here, but driving the request past validation + flag-read all
  // the way to RATE-01 proves the handler reached renderPrompt without
  // crashing on the populated feedback_summary path while the flag
  // forced the loop OFF.
  const installId = testInstallId();
  const boot = await quickBootstrap({ installation_id: installId });
  const client = serviceClient();

  // Cap quota so the request stops at RATE-01 before Gemini.
  {
    const { error } = await client
      .from('usage_counters')
      .update({ used_count: 6 })
      .eq('canonical_user_key', boot.canonical_user_key)
      .eq('feature_key', 'dinner_solve');
    if (error) throw error;
  }

  // Force the kill switch OFF for this assertion. Restore at the end
  // so other tests / runs see the migration default.
  const flipFlag = async (value: boolean) => {
    const { error } = await client
      .from('feature_flags')
      .update({ payload_json: { value } })
      .eq('key', 'preference_memory_enabled');
    if (error) throw error;
  };
  await flipFlag(false);
  try {
    const res = await callDinnerSolve(
      { ...validBody(), feedback_summary: validFeedbackSummary() },
      boot.session_jwt,
    );
    assertEquals(
      res.status, 429,
      'handler must reach RATE-01 even when kill switch is off and feedback is populated',
    );
    assertEquals(res.body?.error, 'RATE-01');
  } finally {
    await flipFlag(true);
  }
});

// SCA-68: leftovers prompt-routing audit — pin the wire-shape contract
// the iOS DinnerSolveRequest.LeftoversItem ships against, the
// canary picker's eligibility mechanics, and the prompt_version
// emission contract. The negative-case Zod tests above (lines
// 123-151) already cover the refine guard rails; these positive-case
// + boundary tests pin the snake_case key names + cap behavior so a
// future drift on either side surfaces here, not in production
// analytics.

Deno.test('dinner-solve: leftovers wire-shape — fully-populated LeftoversItem (canonical_slug + approximate_amount_text) parses (RATE-01 not VAL-01)', async () => {
  const installId = testInstallId();
  const boot = await quickBootstrap({ installation_id: installId });

  // Seed quota at cap so we hit RATE-01 instead of paying for a real
  // Gemini call. RATE-01 fires AFTER Zod parse, so reaching it proves
  // the leftovers wire shape passed validation. Same trick as line
  // 198's `well-formed feedback_summary parses` test.
  const client = serviceClient();
  const { error } = await client
    .from('usage_counters')
    .update({ used_count: 6 })
    .eq('canonical_user_key', boot.canonical_user_key)
    .eq('feature_key', 'dinner_solve');
  if (error) throw error;

  const res = await callDinnerSolve(
    {
      ...validBody(),
      context_hint: 'leftovers',
      leftovers_items: [
        {
          // All three iOS fields populated — exercises the optional
          // canonical_slug + approximate_amount_text path. Snake-case
          // end-to-end: iOS DTO encodes via CodingKeys, backend Zod
          // expects exactly these keys.
          display_name: 'Cooked salmon',
          canonical_slug: 'salmon',
          approximate_amount_text: '~6 oz',
        },
      ],
    },
    boot.session_jwt,
  );
  assertEquals(
    res.status, 429,
    'fully-populated leftovers request must pass Zod and reach RATE-01',
  );
  assertEquals(res.body?.error, 'RATE-01');
});

Deno.test('dinner-solve: leftovers wire-shape — display_name-only LeftoversItem (both optionals omitted) parses', async () => {
  const installId = testInstallId();
  const boot = await quickBootstrap({ installation_id: installId });

  const client = serviceClient();
  const { error } = await client
    .from('usage_counters')
    .update({ used_count: 6 })
    .eq('canonical_user_key', boot.canonical_user_key)
    .eq('feature_key', 'dinner_solve');
  if (error) throw error;

  const res = await callDinnerSolve(
    {
      ...validBody(),
      context_hint: 'leftovers',
      leftovers_items: [{ display_name: 'leftover rice' }],
    },
    boot.session_jwt,
  );
  assertEquals(
    res.status, 429,
    'display_name-only LeftoversItem must parse — canonical_slug + approximate_amount_text are optional',
  );
  assertEquals(res.body?.error, 'RATE-01');
});

Deno.test('dinner-solve: leftovers cap — 20 items parse, 21 reject', async () => {
  const installId = testInstallId();
  const boot = await quickBootstrap({ installation_id: installId });

  const client = serviceClient();
  const { error } = await client
    .from('usage_counters')
    .update({ used_count: 6 })
    .eq('canonical_user_key', boot.canonical_user_key)
    .eq('feature_key', 'dinner_solve');
  if (error) throw error;

  const twenty = Array.from({ length: 20 }, (_, i) => ({
    display_name: `leftover ${i + 1}`,
  }));
  const passing = await callDinnerSolve(
    { ...validBody(), context_hint: 'leftovers', leftovers_items: twenty },
    boot.session_jwt,
  );
  assertEquals(passing.status, 429, '20 leftovers_items at the cap must parse');
  assertEquals(passing.body?.error, 'RATE-01');

  const twentyOne = [...twenty, { display_name: 'leftover 21' }];
  const failing = await callDinnerSolve(
    { ...validBody(), context_hint: 'leftovers', leftovers_items: twentyOne },
    boot.session_jwt,
  );
  assertEquals(failing.status, 400, '21 leftovers_items exceeds the cap');
  assertEquals(failing.body?.error, 'VAL-01');
});

Deno.test('dinner-solve: leftovers wire-shape — extra unknown field on LeftoversItem rejects (.strict() schema)', async () => {
  // Defends against silent wire-protocol drift where iOS adds a new
  // field but doesn't update the backend schema — Zod's `.strict()`
  // on LeftoversItem rejects unknown keys at the boundary so the
  // mismatch surfaces as VAL-01, not silent data-loss.
  const installId = testInstallId();
  const boot = await quickBootstrap({ installation_id: installId });

  const res = await callDinnerSolve(
    {
      ...validBody(),
      context_hint: 'leftovers',
      // deno-lint-ignore no-explicit-any
      leftovers_items: [{ display_name: 'salmon', unknown_future_field: 'x' } as any],
    },
    boot.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body?.error, 'VAL-01');
});
