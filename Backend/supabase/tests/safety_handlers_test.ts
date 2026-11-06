// Exercise the real registered handlers with synthetic DB/provider responses.
// No network permission is granted; an unrecognized request fails the test.
import { assertEquals, assertExists } from '@std/assert';

type Handler = (request: Request) => Response | Promise<Response>;

Deno.test('safety handlers preserve model refusals and reject unsafe final rewrites', async () => {
  const variables: Record<string, string> = {
    SUPABASE_URL: 'http://127.0.0.1:54321',
    SUPABASE_SERVICE_ROLE_KEY: 'synthetic-service-key',
    STIR_JWT_SECRET: 'synthetic-safety-handler-signing-key',
    ANTHROPIC_API_KEY: 'synthetic-anthropic-key',
    AI_TEXT_PROVIDER: 'anthropic',
    POSTHOG_PUBLIC_API_KEY: '',
  };
  const prior = new Map(Object.keys(variables).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(variables)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Deno.serve;
  const runtimeGlobal = globalThis as unknown as {
    EdgeRuntime?: { waitUntil: (task: Promise<unknown>) => void };
  };
  const originalRuntime = runtimeGlobal.EdgeRuntime;
  const pending: Promise<unknown>[] = [];
  runtimeGlobal.EdgeRuntime = { waitUntil: (task) => pending.push(task) };
  let handler: Handler | undefined;
  Deno.serve = ((registered: Handler) => {
    handler = registered;
    return {};
  }) as typeof Deno.serve;
  let candidate: unknown;
  let providerCalls = 0;
  let accountStatus = 'active';
  let stopReason = 'end_turn';
  let cacheBody: unknown;
  const logRows: Record<string, unknown>[] = [];
  const json = (body: unknown) => Promise.resolve(Response.json(body));
  globalThis.fetch = ((input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.origin === 'https://api.anthropic.com' && url.pathname === '/v1/messages') {
      providerCalls++;
      return json({
        id: 'msg_synthetic',
        type: 'message',
        role: 'assistant',
        model: 'claude-sonnet-5-5',
        stop_reason: stopReason,
        stop_sequence: null,
        content: [{ type: 'text', text: JSON.stringify(candidate) }],
        usage: {
          input_tokens: 11,
          output_tokens: 7,
          cache_read_input_tokens: 0,
          cache_creation_input_tokens: 0,
        },
      });
    }
    assertEquals(url.origin, 'http://127.0.0.1:54321', 'unexpected external request');
    const path = url.pathname;
    if (path === '/rest/v1/app_users') {
      return json([{ status: accountStatus, merged_into: null, reauth_required_at: null }]);
    }
    if (path === '/rest/v1/ai_response_cache') {
      return json(
        cacheBody === undefined
          ? []
          : [{ response_body: cacheBody, status_code: 200, created_at: new Date().toISOString() }],
      );
    }
    if (path === '/rest/v1/rpc/stir_rate_limit_check') {
      return json([{ allowed: true, retry_after_seconds: 0, reset_at: new Date().toISOString() }]);
    }
    if (path === '/rest/v1/prompt_versions') {
      return json([{
        feature_key: 'synthetic',
        version: 'test-1',
        provider_model: 'claude-sonnet-5-5',
        template_blob: 'Use household rules. {{user_problem}}',
        schema_hash: 'test',
        rollout_pct: 100,
      }]);
    }
    if (path === '/rest/v1/ai_request_log') {
      logRows.push(JSON.parse(String(init?.body)) as Record<string, unknown>);
      return json([]);
    }
    throw new Error(`unexpected synthetic route ${path}`);
  }) as typeof fetch;
  try {
    const { issueSessionJWT } = await import('../functions/_shared/auth.ts');
    const installation = crypto.randomUUID();
    const jwt = await issueSessionJWT({
      canonical_user_key: `install:${installation}`,
      installation_id: installation,
      tier: 'free',
    });
    const call = async (handle: Handler, body: unknown) => {
      const response = await handle(
        new Request('http://localhost/safety-test', {
          method: 'POST',
          headers: { authorization: `Bearer ${jwt}`, 'content-type': 'application/json' },
          body: JSON.stringify(body),
        }),
      );
      await Promise.all(pending.splice(0));
      return { status: response.status, body: await response.json() };
    };
    await import('../functions/substitution/index.ts');
    assertExists(handler);
    const substitution = handler;
    const body = {
      sub_event_id: crypto.randomUUID(),
      cooking_session_id: crypto.randomUUID(),
      recipe_plan_id: crypto.randomUUID(),
      missing_ingredient: { display_name: 'rice' },
      user_problem: 'I need another option.',
      household_context: { dietary_rules: [], available_equipment: [], pantry_snapshot: [] },
      recipe_context: {
        title: 'Dinner',
        current_step_number: 1,
        total_steps: 1,
        remaining_ingredients: [],
      },
    };
    for (
      const reason of [
        'No safe alternative is available.',
        'The proposed method risks harmful food handling.',
      ]
    ) {
      candidate = {
        substitution_text: 'Pause and choose another recipe.',
        constraint_safe: false,
        reasoning: reason,
        confidence: 'high',
      };
      providerCalls = 0;
      const result = await call(substitution, { ...body, sub_event_id: crypto.randomUUID() });
      assertEquals(result.status, 200);
      assertEquals(result.body.constraint_safe, false);
      assertEquals(result.body.amount_conversion, null);
      assertEquals(providerCalls, 1, 'an explicit refusal is terminal');
    }
    cacheBody = {
      sub_event_id: body.sub_event_id,
      substitution_text: 'Use peanuts.',
      amount_conversion: null,
      constraint_safe: true,
      constraint_violation_reason: null,
      reasoning: 'Use it.',
      confidence: 'high',
      prompt_version: 'test-1',
      latency_ms: 1,
      retry_count: 0,
    };
    providerCalls = 0;
    const replay = await call(substitution, {
      ...body,
      household_context: {
        ...body.household_context,
        dietary_rules: [{ kind: 'allergy', value: 'peanut', severity: 'hard' }],
      },
    });
    assertEquals(replay.body.constraint_safe, false, 'current rules also protect cache replay');
    assertEquals(JSON.stringify(replay.body).includes('peanut'), false);
    assertEquals(providerCalls, 0);
    cacheBody = undefined;
    // Banned users cannot reach cache or a paid model with an old JWT.
    accountStatus = 'banned';
    providerCalls = 0;
    assertEquals((await call(substitution, body)).status, 403);
    assertEquals(providerCalls, 0);
    accountStatus = 'active';
    await import('../functions/recipe-step-rewrite/index.ts');
    assertExists(handler);
    const rewrite = handler;
    const rewriteBody = {
      sub_event_id: crypto.randomUUID(),
      step_instruction_text: 'Top with crushed peanuts.',
      original_ingredient: 'peanuts',
      substitute_ingredient: 'sunflower seeds',
      dietary_rules: [{ kind: 'allergy', value: 'peanut', severity: 'hard' }],
      available_equipment: [],
    };
    candidate = { rewritten_text: 'Top with crushed peanuts.' };
    providerCalls = 0;
    const rejected = await call(rewrite, rewriteBody);
    assertEquals(rejected.status, 502);
    assertEquals(rejected.body.error, 'AI-02');
    assertEquals(rejected.body.rewritten_text, undefined);
    assertEquals(providerCalls, 2);
    candidate = { rewritten_text: 'Top with sunflower seeds.' };
    providerCalls = 0;
    const accepted = await call(rewrite, { ...rewriteBody, sub_event_id: crypto.randomUUID() });
    assertEquals(accepted.status, 200);
    assertEquals(accepted.body.rewritten_text, 'Top with sunflower seeds.');
    assertEquals(providerCalls, 1);
    cacheBody = {
      sub_event_id: rewriteBody.sub_event_id,
      rewritten_text: 'Top with peanuts.',
      prompt_version: 'test-1',
      latency_ms: 1,
      retry_count: 0,
    };
    providerCalls = 0;
    const safeReplay = await call(rewrite, rewriteBody);
    assertEquals(safeReplay.body.rewritten_text, 'Top with sunflower seeds.');
    assertEquals(providerCalls, 1, 'an unsafe cached rewrite must not bypass current rules');
    cacheBody = undefined;
    // Incomplete completions are rejected while their billed work is retained.
    stopReason = 'max_tokens';
    providerCalls = 0;
    const incompleteID = crypto.randomUUID();
    assertEquals((await call(rewrite, { ...rewriteBody, sub_event_id: incompleteID })).status, 502);
    const billed = logRows.find((row) => row.request_id === incompleteID);
    assertExists(billed);
    assertEquals(billed.input_tokens, providerCalls * 11);
    assertEquals(billed.output_tokens, providerCalls * 7);
  } finally {
    await Promise.all(pending);
    globalThis.fetch = originalFetch;
    Deno.serve = originalServe;
    if (originalRuntime) runtimeGlobal.EdgeRuntime = originalRuntime;
    else delete runtimeGlobal.EdgeRuntime;
    for (const [key, value] of prior) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
});
