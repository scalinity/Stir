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
import { quickBootstrap, testIPHeaders } from './_helpers/factory.ts';
import { serviceClient } from './_helpers/pg.ts';

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
  const sessionId = crypto.randomUUID();
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
  const sessionId = crypto.randomUUID();
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
  const sessionId = crypto.randomUUID();
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
    const sessionId = crypto.randomUUID();
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
    const sessionId = crypto.randomUUID();
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

Deno.test(
  'voice-turn-usage accepts prompt_tokens_cached exactly equal to prompt_tokens_total',
  async () => {
    // Boundary: cached == total is valid (whole prompt was cached, which
    // can happen on a turn that replays the same systemInstruction with
    // no new user content yet — rare but legal).
    const boot = await quickBootstrap();
    const sessionId = crypto.randomUUID();
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
