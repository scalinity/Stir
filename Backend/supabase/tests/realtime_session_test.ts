// realtime_session_test
//
// HTTP-level tests for /v1/ai/realtime-session. Covers paths that exercise
// our auth / validation / entitlement / kill-switch / quota logic WITHOUT
// requiring a successful Gemini Live mint — those are gated behind
// STIR_RUN_AI_INTEGRATION_TESTS since the mint needs a real paid-tier
// legacy-format GEMINI_API_KEY (CLAUDE.md sharp-edges #17 + #18).
//
// On a local env with the placeholder key (25-char shorthand), the final
// mint step returns 502 AI-01; tests that drive the full flow assert the
// 502 as a proxy for "all pre-mint logic worked."

import { assertEquals } from '@std/assert';
import { quickBootstrap, testIPHeaders } from './_helpers/factory.ts';
import {
  validHouseholdContext,
  validRealtimeRecipeContext,
} from './_helpers/fixtures/realtime_recipe_context.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

// Kong overrides x-real-ip; clear rate buckets so bootstrap doesn't trip
// ip:bootstrap_hourly inside this file's test suite.
await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface HttpResult {
  status: number;
  body: Record<string, unknown>;
}

async function callRealtimeSession(
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
  const res = await fetch(`${FUNCTIONS_URL}/realtime-session`, init);
  const parsed = await res.json();
  return { status: res.status, body: parsed };
}

function validBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    client_request_id: crypto.randomUUID(),
    cooking_session_id: crypto.randomUUID(),
    recipe_plan_id: crypto.randomUUID(),
    current_step_number: 1,
    // SCA-147: shared `RealtimeRecipeContext` + `HouseholdContext`
    // sub-shapes live in `_helpers/fixtures/realtime_recipe_context.ts`
    // — same source as `cook_turn_test.ts`'s validBody so a schema
    // tighten doesn't drift independently across both files.
    recipe_context: validRealtimeRecipeContext(),
    household_context: validHouseholdContext(),
    ...overrides,
  };
}

/** Promote an existing bootstrapped user to Premium with a fresh voice
 * quota of (used=0, cap=20). Skips the RevenueCat webhook round-trip —
 * direct SQL is faster for tests. */
async function promoteToPremiumWithVoiceQuota(canonicalKey: string): Promise<void> {
  const client = serviceClient();
  const { error: entErr } = await client.from('entitlement_snapshots').upsert({
    canonical_user_key: canonicalKey,
    tier: 'premium',
    billing_state: 'active',
    is_trial: false,
    expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
    updated_at: new Date().toISOString(),
  }, { onConflict: 'canonical_user_key' });
  if (entErr) throw entErr;
  // Cap refresh: voice_cook_session was snapshotted at cap=0 during
  // free-tier bootstrap; bump to 20 so the happy-path quota check passes.
  const { error: quotaErr } = await client
    .from('usage_counters')
    .update({ cap_count: 20, updated_at: new Date().toISOString() })
    .eq('canonical_user_key', canonicalKey)
    .eq('feature_key', 'voice_cook_session');
  if (quotaErr) throw quotaErr;
}

async function setDisableCookRealtimeFlag(enabled: boolean): Promise<void> {
  const client = serviceClient();
  // The flag's "active" semantics is is_enabled=true AND payload_json.value=true.
  // readFlags() returns payload_json as `value` on the wire.
  const { error } = await client
    .from('feature_flags')
    .update({
      is_enabled: enabled,
      payload_json: { value: enabled },
      updated_at: new Date().toISOString(),
    })
    .eq('key', 'disable_cook_realtime');
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// AUTH-01
// ---------------------------------------------------------------------------

Deno.test('realtime-session: AUTH-01 when Authorization header missing', async () => {
  const res = await callRealtimeSession(validBody(), null);
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'missing');
});

Deno.test('realtime-session: AUTH-01 malformed on non-Bearer', async () => {
  const res = await callRealtimeSession(validBody(), 'not-a-jwt');
  assertEquals(res.status, 401);
  assertEquals(res.body.error, 'AUTH-01');
  assertEquals(res.body.reason, 'malformed');
});

// ---------------------------------------------------------------------------
// METHOD-NOT-ALLOWED-01
// ---------------------------------------------------------------------------

Deno.test('realtime-session: METHOD-NOT-ALLOWED-01 on GET', async () => {
  const bs = await quickBootstrap();
  const res = await callRealtimeSession(undefined, bs.session_jwt, 'GET');
  assertEquals(res.status, 405);
  assertEquals(res.body.error, 'METHOD-NOT-ALLOWED-01');
});

// ---------------------------------------------------------------------------
// VAL-01
// ---------------------------------------------------------------------------

Deno.test('realtime-session: VAL-01 on missing client_request_id', async () => {
  const bs = await quickBootstrap();
  const body = validBody();
  delete body.client_request_id;
  const res = await callRealtimeSession(body, bs.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('realtime-session: VAL-01 on non-UUID cooking_session_id', async () => {
  const bs = await quickBootstrap();
  const res = await callRealtimeSession(
    validBody({ cooking_session_id: 'not-a-uuid' }),
    bs.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('realtime-session: VAL-01 on current_step_number=0 (min is 1)', async () => {
  const bs = await quickBootstrap();
  const res = await callRealtimeSession(
    validBody({ current_step_number: 0 }),
    bs.session_jwt,
  );
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

Deno.test('realtime-session: VAL-01 on invalid JSON body', async () => {
  const bs = await quickBootstrap();
  const res = await callRealtimeSession('{not json', bs.session_jwt);
  assertEquals(res.status, 400);
  assertEquals(res.body.error, 'VAL-01');
});

// ---------------------------------------------------------------------------
// ENT-VOICE-01 (voice is Premium+ only)
// ---------------------------------------------------------------------------

Deno.test('realtime-session: ENT-VOICE-01 on Free user', async () => {
  const bs = await quickBootstrap();
  const res = await callRealtimeSession(validBody(), bs.session_jwt);
  assertEquals(res.status, 403);
  assertEquals(res.body.error, 'ENT-VOICE-01');
  assertEquals(res.body.tier, 'free');
});

// ---------------------------------------------------------------------------
// AI-VOICE-01 (disable_cook_realtime kill switch)
// ---------------------------------------------------------------------------

Deno.test('realtime-session: AI-VOICE-01 on disable_cook_realtime flag enabled', async () => {
  try {
    await setDisableCookRealtimeFlag(true);
    const bs = await quickBootstrap();
    await promoteToPremiumWithVoiceQuota(bs.canonical_user_key);
    const res = await callRealtimeSession(validBody(), bs.session_jwt);
    assertEquals(res.status, 503);
    assertEquals(res.body.error, 'AI-VOICE-01');
  } finally {
    await setDisableCookRealtimeFlag(false);
  }
});

// ---------------------------------------------------------------------------
// RATE-01 (voice quota capped)
// ---------------------------------------------------------------------------

Deno.test('realtime-session: RATE-01 when voice_cook_session cap reached', async () => {
  const bs = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(bs.canonical_user_key);
  // Exhaust the quota by setting used_count = cap_count.
  const client = serviceClient();
  await client
    .from('usage_counters')
    .update({ used_count: 20 })
    .eq('canonical_user_key', bs.canonical_user_key)
    .eq('feature_key', 'voice_cook_session');
  const res = await callRealtimeSession(validBody(), bs.session_jwt);
  assertEquals(res.status, 429);
  assertEquals(res.body.error, 'RATE-01');
  assertEquals(res.body.used, 20);
  assertEquals(res.body.cap, 20);
});

// ---------------------------------------------------------------------------
// Mint failure (placeholder key → 502 AI-01). Exercises everything
// up to and including the Gemini mint call. Skipped when a real paid-tier
// legacy key is in the env (STIR_RUN_AI_INTEGRATION_TESTS=1 path) —
// that path belongs in the eval harness, not CI.
// ---------------------------------------------------------------------------

Deno.test('realtime-session: Premium user reaches mint (502 AI-01 on placeholder key, proves pre-mint logic OK)', async () => {
  if (Deno.env.get('STIR_RUN_AI_INTEGRATION_TESTS') === '1') {
    // Skip — a real mint would be cheap but we don't want CI runs burning
    // Gemini quota. The eval harness covers the real happy path.
    return;
  }
  const bs = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(bs.canonical_user_key);
  const res = await callRealtimeSession(validBody(), bs.session_jwt);
  // With a 25-char placeholder key the mint returns 400 INVALID_ARGUMENT;
  // our handler maps that to 502 AI-01. The important part is that we
  // reached mint — all upstream logic (auth, entitlement, quota, prompt
  // read, render) worked.
  assertEquals(res.status, 502);
  assertEquals(res.body.error, 'AI-01');
});

// ---------------------------------------------------------------------------
// is_refresh: quota-skip + rate-limit (P1-N)
// ---------------------------------------------------------------------------
//
// Refresh mints bypass the monthly voice_cook_session quota (ADR 0014 —
// `is_refresh` skips increment). The tests below pin both observable
// consequences of `didConsumeQuota = !body.is_refresh`:
//
//   (1) quota-skip: `is_refresh=true` must NOT increment the counter,
//       and must NOT be blocked by `used_count >= cap_count`. A user at
//       cap can still refresh.
//   (2) refund-guard gating (implicit): both refund paths (no active
//       prompt, mint-throw) gate on `didConsumeQuota && consumedPeriodStart`,
//       so a mint-failure on the `is_refresh=true` path MUST NOT fire
//       `refundQuota`. The post-call `used_count` being identical to
//       the pre-call value pins this — if the refund fired incorrectly,
//       the counter would decrement below the pre-call value.
//
// Not pinned here (filed to §Deferred): the `is_refresh=false`
// increment-then-refund path on mint failure. On the placeholder-key
// CI path, refund returns used_count to its pre-call value, so post-
// call state is indistinguishable from "never incremented". Requires
// either a real mint (STIR_RUN_AI_INTEGRATION_TESTS) or refund-audit
// observability to disambiguate.

Deno.test('realtime-session: is_refresh=true skips quota increment even at cap', async () => {
  if (Deno.env.get('STIR_RUN_AI_INTEGRATION_TESTS') === '1') {
    // A real mint would burn Gemini quota on every CI run. The
    // invariant under test is the pre-mint quota-skip branch; the
    // 502-AI-01 proxy on the placeholder-key path is sufficient.
    return;
  }
  const bs = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(bs.canonical_user_key);

  // Set used_count = cap_count. On the non-refresh path this would
  // return 429 RATE-01 (see "RATE-01 when voice_cook_session cap
  // reached"). On the refresh path, the whole quota branch is
  // skipped, so the call proceeds to mint.
  const client = serviceClient();
  await client
    .from('usage_counters')
    .update({ used_count: 20 })
    .eq('canonical_user_key', bs.canonical_user_key)
    .eq('feature_key', 'voice_cook_session');

  const res = await callRealtimeSession(
    validBody({ is_refresh: true }),
    bs.session_jwt,
  );

  // Pin (1a): at-cap + is_refresh=true does NOT produce 429. The
  // 502-AI-01 proxy proves the handler reached mint — all pre-mint
  // logic including the quota-branch skip worked.
  assertEquals(
    res.status,
    502,
    `expected 502 (reached mint) but got ${res.status}; is_refresh may not be skipping the quota branch`,
  );
  assertEquals(res.body.error, 'AI-01');

  // Pin (1b): post-call used_count is unchanged from the pre-call
  // value (20). If didConsumeQuota=false had been violated and the
  // increment ran anyway, used_count would be 21. If the mint-
  // failure refund path had fired incorrectly (ignoring
  // didConsumeQuota guard), used_count would be 19 (decrement). 20
  // is the only correct value.
  const { data: counter } = await client
    .from('usage_counters')
    .select('used_count')
    .eq('canonical_user_key', bs.canonical_user_key)
    .eq('feature_key', 'voice_cook_session')
    .single();
  assertEquals(
    (counter as { used_count: number } | null)?.used_count,
    20,
    'is_refresh=true must not mutate used_count (no increment, no refund)',
  );
});

Deno.test('realtime-session: is_refresh=true still trips user-scoped rate limiter at cap', async () => {
  if (Deno.env.get('STIR_RUN_AI_INTEGRATION_TESTS') === '1') return;
  const bs = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(bs.canonical_user_key);

  // Pre-fill the per-user mint rate-limit bucket at cap. Policy
  // (from _shared/rate_limiter.ts RATE_LIMIT_POLICIES):
  //   scope: 'user:realtime_session_hourly'
  //   windowSeconds: 3600
  //   maxCount: 40
  //
  // The RPC `stir_rate_limit_check` SUMs count across all rows
  // where `window_start > now() - windowSeconds`. Inserting a single
  // row at `window_start = now()` with `count = 40` puts the
  // sum at cap; the cap-check (`v_current_count >= p_max_count`)
  // fires before any insert, returning 429 RATE-01.
  const client = serviceClient();
  const { error: insertErr } = await client
    .from('rate_limit_buckets')
    .insert({
      scope_key: 'user:realtime_session_hourly',
      bucket_key: bs.canonical_user_key,
      window_start: new Date().toISOString(),
      count: 40,
    });
  if (insertErr) throw insertErr;

  // Call with is_refresh=true. Quota branch is skipped, but the
  // rate limiter runs BEFORE the quota check (realtime-session
  // /index.ts:247-288). Pre-filled user-scoped bucket at cap must
  // trip 429 regardless of is_refresh — rate-limiting protects
  // against a runaway is_refresh=true loop driving Gemini API
  // spend indefinitely (ADR 0014 comment at index.ts:241-245).
  const res = await callRealtimeSession(
    validBody({ is_refresh: true }),
    bs.session_jwt,
  );

  assertEquals(
    res.status,
    429,
    `expected 429 (rate-limited) but got ${res.status}; is_refresh may be skipping the rate limiter`,
  );
  assertEquals(res.body.error, 'RATE-01');
  assertEquals(
    res.body.scope,
    'user:realtime_session_hourly',
    'rate-limit scope must identify the user-scoped mint limiter',
  );
});
