import { assert, assertEquals, assertRejects } from '@std/assert';
import { AITextError } from './ai_text_error.ts';
import {
  mintRealtimeSession,
  OpenAIRealtimeModel,
  REALTIME_MAX_OUTPUT_TOKENS,
  REALTIME_SECRET_TTL_SEC,
  REALTIME_TRUNCATION,
  RealtimeMintError,
} from './realtime_mint.ts';

// Only fake transports run in this file; no provider request can leave the process.
Deno.env.set('ANTHROPIC_API_KEY', 'unit-test-credential');
const { claudeGenerate, ClaudeModel, toJsonSchema } = await import('./claude.ts');

const args = {
  systemInstruction: 'system fixture',
  userText: 'user fixture',
  maxOutputTokens: 512,
  promptVersion: 'test-version',
};

function message(stopReason = 'end_turn', text = '{"ok":true}') {
  return {
    id: 'msg_test',
    type: 'message',
    role: 'assistant',
    model: ClaudeModel.Haiku,
    stop_reason: stopReason,
    stop_sequence: null,
    content: [{ type: 'text', text }],
    usage: {
      input_tokens: 10,
      output_tokens: 7,
      cache_read_input_tokens: 3,
      cache_creation_input_tokens: 2,
    },
  };
}

function json(value: unknown, status = 200) {
  return Promise.resolve(
    new Response(JSON.stringify(value), {
      status,
      headers: { 'content-type': 'application/json' },
    }),
  );
}

Deno.test('Claude sends vision first and structured output without unsupported sampling fields', async () => {
  let body!: {
    messages: [{ content: { type: string }[] }];
    output_config: { format: { schema: unknown } };
    max_tokens: number;
  };
  const result = await claudeGenerate(ClaudeModel.Haiku, {
    ...args,
    image: { mimeType: 'image/jpeg', dataBase64: 'AA==' },
    responseSchema: { type: 'OBJECT', properties: { ok: { type: 'BOOLEAN' } }, required: ['ok'] },
    fetchImpl: (_input, init) => {
      body = JSON.parse(String(init?.body));
      return json(message());
    },
  });
  assertEquals(body.messages[0].content.map((part) => part.type), ['image', 'text']);
  assertEquals(body.output_config.format.schema, {
    type: 'object',
    properties: { ok: { type: 'boolean' } },
    required: ['ok'],
    additionalProperties: false,
  });
  assertEquals(body.max_tokens, 512);
  for (const key of ['temperature', 'top_p', 'top_k', 'tool_choice']) assert(!(key in body));
  assertEquals(result.text, '{"ok":true}');
  assertEquals(result.inputTokens, 15);
  assertEquals(result.cachedInputTokens, 3);
  assertEquals(result.cacheWriteTokens, 2);
  assertEquals(result.outputTokens, 7);
});

Deno.test('nested nullable schemas retain array, enum, and closed object shape', () => {
  assertEquals(
    toJsonSchema({
      type: 'ARRAY',
      items: {
        type: 'OBJECT',
        nullable: true,
        properties: { kind: { type: 'STRING', enum: ['a', 'b'] } },
      },
    }),
    {
      type: 'array',
      items: {
        anyOf: [{
          type: 'object',
          properties: { kind: { type: 'string', enum: ['a', 'b'] } },
          required: [],
          additionalProperties: false,
        }, { type: 'null' }],
      },
    },
  );
});

for (const reason of ['refusal', 'max_tokens']) {
  Deno.test(`Claude ${reason} never exposes partial content and retains billed usage`, async () => {
    let calls = 0;
    const error = await assertRejects(() =>
      claudeGenerate(ClaudeModel.Haiku, {
        ...args,
        fetchImpl: () => {
          calls++;
          return json(message(reason, '{"partial":'));
        },
      }), AITextError);
    assertEquals(error.status, 422);
    assertEquals(error.upstreamStatus, reason);
    assertEquals(error.body, '');
    assertEquals(error.usage?.inputTokens, 15);
    assertEquals(error.usage?.outputTokens, 7);
    assertEquals(calls, 1);
    assert(!error.message.includes('partial'));
  });
}

Deno.test('Claude errors retain status/type without echoing provider content or retrying', async () => {
  let calls = 0;
  const error = await assertRejects(() =>
    claudeGenerate(ClaudeModel.Haiku, {
      ...args,
      fetchImpl: () => {
        calls++;
        return json({
          type: 'error',
          error: { type: 'overloaded_error', message: 'private recipe fixture' },
        }, 529);
      },
    }), AITextError);
  assertEquals(error.status, 529);
  assertEquals(error.upstreamStatus, 'overloaded_error');
  assertEquals(error.body, '');
  assert(!error.message.includes('private recipe'));
  assertEquals(calls, 1);
});

const mintConfig = {
  instructions: 'cooking fixture',
  model: OpenAIRealtimeModel.Mini,
  reasoningEffort: 'minimal' as const,
  turnDetectionMode: 'semantic_vad' as const,
  safetyIdentifier: 'hashed-fixture',
};

async function withMintKey(operation: () => Promise<void>) {
  const prior = Deno.env.get('OPENAI_API_KEY');
  Deno.env.set('OPENAI_API_KEY', 'unit-test-credential');
  try {
    await operation();
  } finally {
    if (prior === undefined) Deno.env.delete('OPENAI_API_KEY');
    else Deno.env.set('OPENAI_API_KEY', prior);
  }
}

for (const mode of ['semantic_vad', 'server_vad'] as const) {
  Deno.test(`Realtime ${mode} mint serializes bounded audio/tool/session settings`, () =>
    withMintKey(async () => {
      let body!: {
        expires_after: unknown;
        session: {
          max_output_tokens: number;
          model: string;
          audio: {
            input: {
              format: unknown;
              turn_detection: { type: string; interrupt_response: boolean };
            };
          };
          tools: { name: string }[];
        };
      };
      const expiresAt = Math.floor(Date.now() / 1000) + 120;
      const result = await mintRealtimeSession({
        ...mintConfig,
        turnDetectionMode: mode,
        fetchImpl: (_input, init) => {
          body = JSON.parse(String(init?.body));
          assertEquals(
            new Headers(init?.headers).get('OpenAI-Safety-Identifier'),
            'hashed-fixture',
          );
          return json({ value: 'ek_fixture', expires_at: expiresAt });
        },
      });
      assertEquals(body.expires_after, { anchor: 'created_at', seconds: REALTIME_SECRET_TTL_SEC });
      assertEquals(body.session.max_output_tokens, REALTIME_MAX_OUTPUT_TOKENS);
      assertEquals(body.session.model, OpenAIRealtimeModel.Mini);
      assertEquals(body.session.audio.input.format, { type: 'audio/pcm', rate: 24000 });
      assertEquals(body.session.audio.input.turn_detection.type, mode);
      assertEquals(body.session.audio.input.turn_detection.interrupt_response, false);
      assert(body.session.tools.some((tool) => tool.name === 'start_timer'));
      assertEquals(JSON.parse(result.setupFrameJSON).session.truncation, REALTIME_TRUNCATION);
      assertEquals(result.expiresAt, new Date(expiresAt * 1000).toISOString());
      assert(result.wsUrl.startsWith('wss://api.openai.com/v1/realtime?model='));
    }));
}

for (
  const secret of [{ expires_at: 10 }, { value: 'ek_fixture' }, {
    value: 'ek_fixture',
    expires_at: 0,
  }, { value: 'ek_fixture', expires_at: 'invalid' }]
) {
  Deno.test(`Realtime rejects malformed or expired secret ${JSON.stringify(secret)}`, () =>
    withMintKey(async () => {
      await assertRejects(
        () => mintRealtimeSession({ ...mintConfig, fetchImpl: () => json(secret) }),
        RealtimeMintError,
      );
    }));
}

Deno.test('Realtime missing server key never invokes transport', async () => {
  const prior = Deno.env.get('OPENAI_API_KEY');
  Deno.env.delete('OPENAI_API_KEY');
  let calls = 0;
  try {
    await assertRejects(() =>
      mintRealtimeSession({
        ...mintConfig,
        fetchImpl: () => {
          calls++;
          return json({});
        },
      }), RealtimeMintError);
    assertEquals(calls, 0);
  } finally {
    if (prior !== undefined) Deno.env.set('OPENAI_API_KEY', prior);
  }
});

Deno.test('Realtime upstream failure is typed and does not leak response content in message', () =>
  withMintKey(async () => {
    const error = await assertRejects(
      () =>
        mintRealtimeSession({
          ...mintConfig,
          fetchImpl: () => json({ error: { message: 'private recipe fixture' } }, 503),
        }),
      RealtimeMintError,
    );
    assertEquals(error.statusCode, 503);
    assert(!error.message.includes('private recipe'));
  }));

// Advance SDK-owned request deadlines without waiting 10/30 real seconds.
// Each test restores the timer before returning; fetch still receives and
// reacts to the SDK's actual AbortSignal, exercising its timeout exception.
async function withImmediateDeadline(operation: () => Promise<void>) {
  const original = globalThis.setTimeout;
  globalThis.setTimeout =
    ((handler: TimerHandler, _delay?: number, ...parameters: unknown[]) =>
      original(handler, 0, ...parameters)) as typeof setTimeout;
  try {
    await operation();
  } finally {
    globalThis.setTimeout = original;
  }
}

const waitForAbort: typeof fetch = (_input, init) =>
  new Promise((_resolve, reject) => {
    const signal = init?.signal;
    const abort = () => reject(new DOMException('test deadline', 'AbortError'));
    if (!signal || signal.aborted) abort();
    else signal.addEventListener('abort', abort, { once: true });
  });

Deno.test('Claude SDK deadline becomes typed 504 timeout', () =>
  withImmediateDeadline(async () => {
    const error = await assertRejects(
      () => claudeGenerate(ClaudeModel.Haiku, { ...args, fetchImpl: waitForAbort }),
      AITextError,
    );
    assertEquals(error.status, 504);
    assertEquals(error.upstreamStatus, 'timeout');
  }));

Deno.test('Realtime SDK deadline becomes typed 504 mint error', () =>
  withMintKey(() =>
    withImmediateDeadline(async () => {
      const error = await assertRejects(
        () => mintRealtimeSession({ ...mintConfig, fetchImpl: waitForAbort }),
        RealtimeMintError,
      );
      assertEquals(error.statusCode, 504);
    })
  ));

Deno.test('Claude connection failure becomes typed 502 without provider content', async () => {
  const error = await assertRejects(() =>
    claudeGenerate(ClaudeModel.Haiku, {
      ...args,
      fetchImpl: () => Promise.reject(new TypeError('private connection fixture')),
    }), AITextError);
  assertEquals(error.status, 502);
  assertEquals(error.upstreamStatus, 'connection_error');
  assert(!error.message.includes('private connection'));
});

Deno.test('Realtime connection failure becomes typed 502', () =>
  withMintKey(async () => {
    const error = await assertRejects(() =>
      mintRealtimeSession({
        ...mintConfig,
        fetchImpl: () => Promise.reject(new TypeError('private connection fixture')),
      }), RealtimeMintError);
    assertEquals(error.statusCode, 502);
    assert(!error.message.includes('private connection'));
  }));

Deno.test('Claude adaptive thinking preserves answer headroom and requested effort', async () => {
  let body!: { max_tokens: number; thinking: { type: string }; output_config: { effort: string } };
  await claudeGenerate(ClaudeModel.Sonnet, {
    ...args,
    thinkingLevel: 'medium',
    fetchImpl: (_input, init) => {
      body = JSON.parse(String(init?.body));
      return json(message());
    },
  });
  assertEquals(body.thinking.type, 'adaptive');
  assertEquals(body.output_config.effort, 'medium');
  assertEquals(body.max_tokens, 512 + 4096);
});
