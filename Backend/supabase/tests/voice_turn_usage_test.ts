// voice_turn_usage_test
//
// HTTP-level tests for /v1/ai/voice-turn-usage (PostHog LLM Observability
// dual-write path — see ADR 0009). Covers:
//   - 401 AUTH-01 on missing/invalid JWT
//   - 400 VAL-01 on malformed body (bad enum, wrong shape)
//   - 204 on valid POST + ai_request_log row written with expected shape
//   - Idempotency: repeat POST with same (session_id, turn_index)
//     upserts via ON CONFLICT DO NOTHING — no row duplication
//   - Cost math parity: backend's computeCostUSD on CLAUDE.md's spike-
//     validated baseline input (125+825 audio prompt, 200 overhead, 1000
//     text sys prompt, 150 audio out) produces ~$0.006/turn
//
// PostHog capture is NOT asserted here — posthog.ts is fire-and-forget
// and observability-path tests would require a mock ingest server. The
// capture signal is visible at prod via PostHog's own dashboard.

import { assertEquals, assertExists } from '@std/assert';
import { quickBootstrap, seedVoiceSessionOwner, testIPHeaders } from './_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';

// Kong overrides x-real-ip; clear rate buckets so bootstrap doesn't trip
// ip:bootstrap_hourly across repeated test-file runs. Mirrors the
// file-scope reset in realtime_session_test.ts — without this, the
// cumulative bootstrap count across runs eventually trips 429 and
// every test that calls `quickBootstrap()` fails.
await clearRateLimitBuckets();

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

interface HttpResult {
  status: number;
  body: unknown;
}

async function callVoiceTurnUsage(
  body: unknown,
  jwt: string | null,
): Promise<HttpResult> {
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    ...testIPHeaders(),
  };
  if (jwt !== null) headers['Authorization'] = `Bearer ${jwt}`;
  const res = await fetch(`${FUNCTIONS_URL}/voice-turn-usage`, {
    method: 'POST',
    headers,
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  // 204 has no body; empty-text safety.
  const text = await res.text();
  const parsed: unknown = text ? JSON.parse(text) : null;
  return { status: res.status, body: parsed };
}

function validBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const sessionId = overrides.session_id ?? crypto.randomUUID();
  const turns = overrides.turns ?? [{
    turn_index: 1,
    // CLAUDE.md §Cost model baseline: 125 new audio + 825 carried audio +
    // 200 overhead = 1150 audio in; 1000 text sys prompt; 150 audio out.
    prompt_tokens_text: 1000,
    prompt_tokens_audio: 1150,
    // Totals match the breakdown sum in the baseline case. When the
    // AUDIO-mode per-pass overhead goes unattributed (sharp-edge #15)
    // totals would exceed the breakdown; tested separately elsewhere.
    prompt_tokens_total: 2150,
    response_tokens_text: 0,
    response_tokens_audio: 150,
    response_tokens_total: 150,
    latency_ms: 1400,
    ended_reason: 'turn_complete',
    prompt_version: '1.0.0',
    path: 'live_api',
    ended_at: new Date().toISOString(),
  }];
  return { session_id: sessionId, turns, ...overrides };
}

/** Promote a bootstrapped Free user to Premium + fresh voice quota.
 * Copied verbatim from realtime_session_test.ts so the two files stay
 * style-consistent; consolidate into tests/_helpers/factory.ts when a
 * third caller emerges. (Filed as session-note §Deferred for the
 * backend test audit commit following P1-O.)
 *
 * Without this call, the voice-turn-usage entitlement gate
 * (voice-turn-usage/index.ts:210-211) rejects the Free user bootstrap
 * with 403 ENT-VOICE-01 before reaching the success path — the reason
 * every 204-expecting test in this file was red pre-fix. */
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
  const { error: quotaErr } = await client
    .from('usage_counters')
    .update({ cap_count: 20, updated_at: new Date().toISOString() })
    .eq('canonical_user_key', canonicalKey)
    .eq('feature_key', 'voice_cook_session');
  if (quotaErr) throw quotaErr;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

Deno.test('voice-turn-usage 401 AUTH-01 on missing Authorization', async () => {
  const result = await callVoiceTurnUsage(validBody(), null);
  assertEquals(result.status, 401);
  const body = result.body as { error: string; reason?: string };
  assertEquals(body.error, 'AUTH-01');
});

Deno.test('voice-turn-usage 401 AUTH-01 on malformed JWT', async () => {
  const result = await callVoiceTurnUsage(validBody(), 'not-a-real-jwt');
  assertEquals(result.status, 401);
  assertEquals((result.body as { error: string }).error, 'AUTH-01');
});

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

Deno.test('voice-turn-usage 400 VAL-01 on invalid session_id', async () => {
  const boot = await quickBootstrap();
  const result = await callVoiceTurnUsage(
    validBody({ session_id: 'not-a-uuid' }),
    boot.session_jwt,
  );
  assertEquals(result.status, 400);
  assertEquals((result.body as { error: string }).error, 'VAL-01');
});

Deno.test('voice-turn-usage 400 VAL-01 on invalid path enum', async () => {
  const boot = await quickBootstrap();
  const result = await callVoiceTurnUsage(
    validBody({
      turns: [{
        turn_index: 1,
        prompt_tokens_text: 100,
        prompt_tokens_audio: 100,
        prompt_tokens_total: 200,
        response_tokens_text: 0,
        response_tokens_audio: 50,
        response_tokens_total: 50,
        latency_ms: 1000,
        ended_reason: 'turn_complete',
        prompt_version: '1.0.0',
        path: 'not_a_path',
        ended_at: new Date().toISOString(),
      }],
    }),
    boot.session_jwt,
  );
  assertEquals(result.status, 400);
  assertEquals((result.body as { error: string }).error, 'VAL-01');
});

Deno.test('voice-turn-usage 400 VAL-01 on empty turns array', async () => {
  const boot = await quickBootstrap();
  const result = await callVoiceTurnUsage(
    validBody({ turns: [] }),
    boot.session_jwt,
  );
  assertEquals(result.status, 400);
});

// ---------------------------------------------------------------------------
// Success path + row writing
// ---------------------------------------------------------------------------

Deno.test('voice-turn-usage 204 + ai_request_log row with expected shape', async () => {
  const boot = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
  const sessionId = crypto.randomUUID();
  // P1-B (2026-04-23): seed ownership binding so the handler's new
  // IDOR check passes. Production writes this at mint time.
  await seedVoiceSessionOwner({ sessionId, canonicalUserKey: boot.canonical_user_key });
  const body = validBody({ session_id: sessionId });
  const result = await callVoiceTurnUsage(body, boot.session_jwt);
  assertEquals(result.status, 204);

  // Assert the row landed with the expected request_id shape.
  const client = serviceClient();
  const expectedRequestId = `voice:${sessionId}:1`;
  const { data, error } = await client
    .from('ai_request_log')
    .select('request_id, canonical_user_key, feature_key, model, input_tokens, output_tokens, cost_usd, latency_ms, thinking_level, prompt_version')
    .eq('request_id', expectedRequestId)
    .maybeSingle();
  assertEquals(error, null);
  assertExists(data);
  assertEquals(data!.request_id, expectedRequestId);
  assertEquals(data!.canonical_user_key, boot.canonical_user_key);
  assertEquals(data!.feature_key, 'cook_mode_realtime');
  assertEquals(data!.model, 'gemini-3.1-flash-live-preview');
  // 1000 text + 1150 audio in; 0 text + 150 audio out.
  assertEquals(data!.input_tokens, 2150);
  assertEquals(data!.output_tokens, 150);
  assertEquals(data!.thinking_level, 'minimal');
  assertEquals(data!.prompt_version, '1.0.0');
  // Cost math (per CLAUDE.md §Cost model, spike-validated):
  //   text in:   1000  * $0.75  / 1_000_000 = $0.000750
  //   audio in:  1150  * $3.00  / 1_000_000 = $0.003450
  //   audio out: 150   * $12.00 / 1_000_000 = $0.001800
  //   total                                 = $0.006000
  // Allow ±$0.000010 for rounding at 6-decimal precision.
  const cost = Number(data!.cost_usd);
  const expected = 0.006;
  if (Math.abs(cost - expected) > 0.00001) {
    throw new Error(`cost_usd ${cost} differs from baseline ${expected} by more than rounding`);
  }
});

Deno.test('voice-turn-usage idempotency: repeat POST with same (session_id, turn_index) is no-op', async () => {
  const boot = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
  const sessionId = crypto.randomUUID();
  await seedVoiceSessionOwner({ sessionId, canonicalUserKey: boot.canonical_user_key });
  const body = validBody({ session_id: sessionId });
  // First write.
  const r1 = await callVoiceTurnUsage(body, boot.session_jwt);
  assertEquals(r1.status, 204);
  // Second write with identical payload — ON CONFLICT DO NOTHING keeps
  // the original row.
  const r2 = await callVoiceTurnUsage(body, boot.session_jwt);
  assertEquals(r2.status, 204);

  const client = serviceClient();
  const { data, error } = await client
    .from('ai_request_log')
    .select('request_id')
    .eq('request_id', `voice:${sessionId}:1`);
  assertEquals(error, null);
  assertEquals((data ?? []).length, 1);
});

Deno.test('voice-turn-usage batch writes N rows', async () => {
  const boot = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
  const sessionId = crypto.randomUUID();
  await seedVoiceSessionOwner({ sessionId, canonicalUserKey: boot.canonical_user_key });
  const now = new Date().toISOString();
  const turns = [1, 2, 3].map((idx) => ({
    turn_index: idx,
    prompt_tokens_text: 500,
    prompt_tokens_audio: 500,
    prompt_tokens_total: 1000,
    response_tokens_text: 0,
    response_tokens_audio: 100,
    response_tokens_total: 100,
    latency_ms: 1200,
    ended_reason: 'turn_complete',
    prompt_version: '1.0.0',
    path: 'live_api',
    ended_at: now,
  }));
  const result = await callVoiceTurnUsage({ session_id: sessionId, turns }, boot.session_jwt);
  assertEquals(result.status, 204);

  const client = serviceClient();
  const { data, error } = await client
    .from('ai_request_log')
    .select('request_id')
    .like('request_id', `voice:${sessionId}:%`);
  assertEquals(error, null);
  assertEquals((data ?? []).length, 3);
});

// ---------------------------------------------------------------------------
// Cached-tokens observability (implicit caching on Gemini Live)
// ---------------------------------------------------------------------------

Deno.test(
  'voice-turn-usage persists prompt_tokens_cached into ai_request_log',
  async () => {
    const boot = await quickBootstrap();
    await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
    const sessionId = crypto.randomUUID();
    await seedVoiceSessionOwner({ sessionId, canonicalUserKey: boot.canonical_user_key });
    const body = validBody({
      session_id: sessionId,
      turns: [{
        turn_index: 1,
        prompt_tokens_text: 2000,
        prompt_tokens_audio: 500,
        prompt_tokens_total: 2500,
        prompt_tokens_cached: 1800, // ~72% cached — hypothetical "caching firing"
        response_tokens_text: 0,
        response_tokens_audio: 150,
        response_tokens_total: 150,
        latency_ms: 1200,
        ended_reason: 'turn_complete',
        prompt_version: '1.6.0',
        path: 'live_api',
        ended_at: new Date().toISOString(),
      }],
    });
    const result = await callVoiceTurnUsage(body, boot.session_jwt);
    assertEquals(result.status, 204);

    const client = serviceClient();
    const { data, error } = await client
      .from('ai_request_log')
      .select('prompt_cached_tokens')
      .eq('request_id', `voice:${sessionId}:1`)
      .maybeSingle();
    assertEquals(error, null);
    assertExists(data);
    assertEquals(data!.prompt_cached_tokens, 1800);
  },
);

Deno.test(
  'voice-turn-usage leaves prompt_cached_tokens NULL when field absent',
  async () => {
    const boot = await quickBootstrap();
    await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
    const sessionId = crypto.randomUUID();
    await seedVoiceSessionOwner({ sessionId, canonicalUserKey: boot.canonical_user_key });
    // validBody() deliberately omits prompt_tokens_cached — the common
    // path where caching either didn't fire or iOS didn't send the field.
    const result = await callVoiceTurnUsage(
      validBody({ session_id: sessionId }),
      boot.session_jwt,
    );
    assertEquals(result.status, 204);

    const client = serviceClient();
    const { data, error } = await client
      .from('ai_request_log')
      .select('prompt_cached_tokens')
      .eq('request_id', `voice:${sessionId}:1`)
      .maybeSingle();
    assertEquals(error, null);
    assertExists(data);
    assertEquals(data!.prompt_cached_tokens, null);
  },
);

Deno.test(
  'voice-turn-usage 400 VAL-01 when prompt_tokens_cached exceeds prompt_tokens_total',
  async () => {
    // Invariant enforced by Zod .refine() on VoiceTurnUsageRequest. A
    // buggy client that double-counted cached against non-prompt
    // generation passes would otherwise produce ratios > 1.0 in the
    // spec §9 cap-reversal trigger dashboard.
    const boot = await quickBootstrap();
    const result = await callVoiceTurnUsage(
      validBody({
        turns: [{
          turn_index: 1,
          prompt_tokens_text: 500,
          prompt_tokens_audio: 500,
          prompt_tokens_total: 1000,
          prompt_tokens_cached: 1500, // > total — must fail
          response_tokens_text: 0,
          response_tokens_audio: 100,
          response_tokens_total: 100,
          latency_ms: 1000,
          ended_reason: 'turn_complete',
          prompt_version: '1.0.0',
          path: 'live_api',
          ended_at: new Date().toISOString(),
        }],
      }),
      boot.session_jwt,
    );
    assertEquals(result.status, 400);
    assertEquals((result.body as { error: string }).error, 'VAL-01');
  },
);

// ---------------------------------------------------------------------------
// P1-B / SA2-W4: session_id ownership binding
// ---------------------------------------------------------------------------

Deno.test('voice-turn-usage 403 ENT-VOICE-01 for Free user (entitlement gate)', async () => {
  // Sprint-B-review C1: SCA-146 promoted users to Premium in the
  // session_missing + owner_mismatch tests. As a side-effect, Free →
  // ENT-VOICE-01 coverage on this handler dropped to zero (the only
  // remaining ENT-VOICE-01 assertions in tests/ live under
  // realtime_session_test.ts and cook_turn_test.ts, neither of which
  // exercise the voice-turn-usage handler). This test restores the
  // coverage explicitly: a Free-tier bootstrap (no entitlement
  // promotion) calls voice-turn-usage with a valid JWT and a
  // session_id; the entitlement gate must fire BEFORE owner-binding,
  // returning 403 ENT-VOICE-01.
  //
  // session_id is intentionally a random UUID so a future flip of the
  // gate-ordering (owner-binding before entitlement) wouldn't silently
  // pass via session_missing (different error code) — it would
  // surface a clear assertion failure.
  const boot = await quickBootstrap();
  const sessionId = crypto.randomUUID();
  const result = await callVoiceTurnUsage(
    validBody({ session_id: sessionId }),
    boot.session_jwt,
  );
  assertEquals(result.status, 403);
  assertEquals((result.body as { error: string }).error, 'ENT-VOICE-01');
});

Deno.test('voice-turn-usage 403 VOICE-SESSION-01 session_missing when no owner row exists (unbooted session)', async () => {
  // SCA-146: migrated from ENT-VOICE-01 to VOICE-SESSION-01 per ADR
  // 0017. The pre-migration assertion passed via entitlement-gate-
  // short-circuit (Free user fails ENT-VOICE-01 before reaching the
  // owner-binding check); the test pinned the wrong reason. Promoting
  // to Premium routes execution into the owner-binding path, which is
  // what this test should actually exercise.
  //
  // Scenario: valid Premium JWT but a session_id that was never minted.
  // Prior behavior: would 204 and happily write a turn under someone
  // else's trace_id. Post-P1-B: hard 403 with VOICE-SESSION-01 +
  // reason='session_missing'.
  const boot = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
  const sessionId = crypto.randomUUID(); // not seeded
  const result = await callVoiceTurnUsage(
    validBody({ session_id: sessionId }),
    boot.session_jwt,
  );
  assertEquals(result.status, 403);
  const body = result.body as { error: string; reason?: string };
  assertEquals(body.error, 'VOICE-SESSION-01');
  assertEquals(body.reason, 'session_missing');
});

Deno.test(
  'voice-turn-usage 403 VOICE-SESSION-01 session_closed when session was superseded by a newer mint',
  async () => {
    // Simulates: iOS mints a session, iOS refreshes → new session, iOS
    // posts a turn under the OLD session_id (e.g., in-flight POST that
    // crossed the supersede UPDATE on the backend). Ownership check
    // passes (same user) but lifecycle check rejects with a distinct
    // reason so ops can split this from IDOR failures.
    //
    // Migrated to VOICE-SESSION-01 per ADR 0017. Free user would hit
    // entitlement gate before owner-binding check; promote so the
    // lifecycle path actually runs.
    const boot = await quickBootstrap();
    await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
    const oldSessionId = crypto.randomUUID();
    await seedVoiceSessionOwner({
      sessionId: oldSessionId,
      canonicalUserKey: boot.canonical_user_key,
    });
    // Simulate supersede: a new mint landed for the same user, which
    // would mark the old row closed. Here we mutate directly via
    // service role to avoid needing a full realtime-session mint.
    const admin = serviceClient();
    await admin
      .from('voice_session_owners')
      .update({ closed_at: new Date().toISOString() })
      .eq('session_id', oldSessionId);

    const result = await callVoiceTurnUsage(
      validBody({ session_id: oldSessionId }),
      boot.session_jwt,
    );
    assertEquals(result.status, 403);
    const body = result.body as { error: string; reason?: string };
    assertEquals(body.error, 'VOICE-SESSION-01');
    assertEquals(body.reason, 'session_closed');
  },
);

Deno.test('voice-turn-usage 403 VOICE-SESSION-01 owner_mismatch when session_id was minted by a different user (IDOR)', async () => {
  // SCA-146: migrated from ENT-VOICE-01 to VOICE-SESSION-01 per ADR
  // 0017. Pre-migration the assertion fired on userB's entitlement
  // gate (Free) instead of the owner-mismatch check; pinned the wrong
  // reason. Promoting userB to Premium routes execution into the
  // owner-binding path where the IDOR rejection actually lives.
  //
  // Bootstrap TWO users. User A mints a session. User B (Premium)
  // tries to post turns under A's session_id — must be rejected with
  // VOICE-SESSION-01 + reason='owner_mismatch'.
  const userA = await quickBootstrap();
  const userB = await quickBootstrap();
  await promoteToPremiumWithVoiceQuota(userB.canonical_user_key);
  const sessionId = crypto.randomUUID();
  await seedVoiceSessionOwner({ sessionId, canonicalUserKey: userA.canonical_user_key });

  const result = await callVoiceTurnUsage(
    validBody({ session_id: sessionId }),
    userB.session_jwt, // B's JWT, A's session
  );
  assertEquals(result.status, 403);
  const body = result.body as { error: string; reason?: string };
  assertEquals(body.error, 'VOICE-SESSION-01');
  assertEquals(body.reason, 'owner_mismatch');
});

Deno.test(
  'voice-turn-usage accepts prompt_tokens_cached exactly equal to prompt_tokens_total',
  async () => {
    // Boundary: cached == total is valid (whole prompt was cached, which
    // can happen on a turn that replays the same systemInstruction with
    // no new user content yet — rare but legal).
    const boot = await quickBootstrap();
    await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
    const sessionId = crypto.randomUUID();
    await seedVoiceSessionOwner({ sessionId, canonicalUserKey: boot.canonical_user_key });
    const body = validBody({
      session_id: sessionId,
      turns: [{
        turn_index: 1,
        prompt_tokens_text: 500,
        prompt_tokens_audio: 500,
        prompt_tokens_total: 1000,
        prompt_tokens_cached: 1000, // == total, allowed
        response_tokens_text: 0,
        response_tokens_audio: 100,
        response_tokens_total: 100,
        latency_ms: 1000,
        ended_reason: 'turn_complete',
        prompt_version: '1.0.0',
        path: 'live_api',
        ended_at: new Date().toISOString(),
      }],
    });
    const result = await callVoiceTurnUsage(body, boot.session_jwt);
    assertEquals(result.status, 204);
  },
);

// ---------------------------------------------------------------------------
// AUDIO-mode overhead remainder (P1-O)
// ---------------------------------------------------------------------------
//
// Gemini Live charges ~200 audio-input tokens per turn beyond the literal
// text+audio breakdown — the AUDIO-mode per-pass overhead (CLAUDE.md
// sharp-edge #15, empirically observed April 2026 spike). The handler at
// voice-turn-usage/index.ts:398-405 prices this remainder at the audio
// rate for the relevant modality:
//
//   promptRemainder = max(0, inputTokens - (prompt_text + prompt_audio))
//   remainderCost   = promptRemainder   * audioInPer1M  / 1_000_000
//                   + responseRemainder * audioOutPer1M / 1_000_000
//
// Unit-level math (coefficients, clamping, cached-token discount) is
// pinned by compute_cost_usd_test.ts. The existing "expected shape"
// test (line 180) pins the happy path where total == text + audio
// (no remainder). This test pins the integration path where total >
// text + audio — the common AUDIO-mode case — and confirms both
// input_tokens persistence (raw total, not breakdown sum) and the
// remainder-priced cost survive the full flow to ai_request_log.

Deno.test(
  'voice-turn-usage AUDIO-mode prompt remainder flows through to ai_request_log cost',
  async () => {
    const boot = await quickBootstrap();
    await promoteToPremiumWithVoiceQuota(boot.canonical_user_key);
    const sessionId = crypto.randomUUID();
    await seedVoiceSessionOwner({ sessionId, canonicalUserKey: boot.canonical_user_key });

    // Payload shape: 200-token prompt remainder + 10-token response
    // remainder. The 200 matches the empirical AUDIO-mode overhead
    // observed in the April 2026 spike.
    const body = validBody({
      session_id: sessionId,
      turns: [{
        turn_index: 1,
        prompt_tokens_text: 1000,
        prompt_tokens_audio: 1150,
        prompt_tokens_total: 2350, // text + audio + 200 remainder
        response_tokens_text: 0,
        response_tokens_audio: 150,
        response_tokens_total: 160, // text + audio + 10 remainder
        latency_ms: 1400,
        ended_reason: 'turn_complete',
        prompt_version: '1.0.0',
        path: 'live_api',
        ended_at: new Date().toISOString(),
      }],
    });
    const result = await callVoiceTurnUsage(body, boot.session_jwt);
    assertEquals(result.status, 204);

    const client = serviceClient();
    const { data, error } = await client
      .from('ai_request_log')
      .select('input_tokens, output_tokens, cost_usd')
      .eq('request_id', `voice:${sessionId}:1`)
      .maybeSingle();
    assertEquals(error, null);
    assertExists(data);

    // Pin (1): input_tokens is the raw total (2350), NOT the breakdown
    // sum (2150). The handler clamps to max(total, sum); this payload
    // uses total > sum (the common AUDIO-mode case), so raw-total
    // survives.
    assertEquals(
      data!.input_tokens,
      2350,
      'input_tokens must be the raw Gemini total, not the breakdown sum',
    );

    // Pin (2): output_tokens same invariant — raw total, not breakdown.
    assertEquals(
      data!.output_tokens,
      160,
      'output_tokens must be the raw Gemini total',
    );

    // Pin (3): "remainder exists" invariant against the request's
    // declared breakdown. Not inferable from pin (1) alone — a future
    // refactor that clamped input_tokens to the breakdown sum while
    // also mutating the total would pass pins (1+2) silently. This
    // pin catches that by asserting the delta is positive.
    const requestBreakdownSum = 1000 + 1150;
    assertEquals(
      data!.input_tokens > requestBreakdownSum,
      true,
      'input_tokens must exceed breakdown sum — remainder must survive the integration',
    );

    // Pin (4): cost_usd includes the remainder priced at audio rates.
    //   text in:      1000 * $0.75  / 1_000_000 = $0.000750
    //   audio in:     1150 * $3.00  / 1_000_000 = $0.003450
    //   prompt rem:    200 * $3.00  / 1_000_000 = $0.000600 (audio-in rate)
    //   audio out:     150 * $12.00 / 1_000_000 = $0.001800
    //   response rem:   10 * $12.00 / 1_000_000 = $0.000120 (audio-out rate)
    //   total                                   = $0.006720
    // Tolerance 1e-6 matches production's Math.round(× 1e6) / 1e6 rounding
    // in voice-turn-usage/index.ts:410 (ai_request_log.cost_usd NUMERIC(10,6)).
    const cost = Number(data!.cost_usd);
    const expected = 0.006720;
    if (Math.abs(cost - expected) > 1e-6) {
      throw new Error(
        `cost_usd ${cost} differs from expected ${expected} by more than 1e-6 (production rounding precision)`,
      );
    }
  },
);
