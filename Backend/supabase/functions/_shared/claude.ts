// Claude client — Messages API for text + image inputs (ADR 0038).
//
// Called only through `_shared/ai_text.ts`; handlers never import this file.
// Official SDK per ADR 0038 decision 5 (exception to the no-npm-deps rule).
//
// Claude-specific rules this file owns, so no handler has to know them:
//   - Structured output goes through `output_config.format` (json_schema).
//     Forced `tool_choice` and assistant prefill are 400s on current models.
//   - The schemas handlers pass are Gemini's OpenAPI dialect (`type:'OBJECT'`,
//     `nullable:true`); `toJsonSchema` converts them to the JSON Schema subset
//     structured outputs accept (lowercase types, `additionalProperties:false`
//     on every object, nullable as `anyOf` with null).
//   - `stop_reason: "refusal"` is checked before content is read.
//   - No sampling parameters (`temperature`/`top_p`/`top_k` are 400s on API
//     version 2026-10-21, which this SDK release sends).
//   - SDK retries are off: handlers own their retry-once-on-5xx policy, and a
//     second retry layer would double the worst-case latency.

import Anthropic from '@anthropic-ai/sdk';
import type { AITextArgs, AITextResult, AIThinkingLevel } from './ai_text.ts';
import { AITextError } from './ai_text_error.ts';

export enum ClaudeModel {
  Haiku = 'claude-haiku-5-5',
  Sonnet = 'claude-sonnet-5-5',
}

const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY');

// 30 s matches gemini.ts's generateContent budget (P0-K): fail fast on the
// primary user path instead of riding the ~150 s platform timeout.
const TIMEOUT_MS = 30_000;

let sharedClient: Anthropic | undefined;
function clientFor(fetchImpl: typeof fetch | undefined): Anthropic {
  if (!ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY missing; cannot call Claude.');
  if (fetchImpl) {
    return new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: TIMEOUT_MS, maxRetries: 0, fetch: fetchImpl });
  }
  sharedClient ??= new Anthropic({ apiKey: ANTHROPIC_API_KEY, timeout: TIMEOUT_MS, maxRetries: 0 });
  return sharedClient;
}

// ---------------------------------------------------------------------------
// Schema conversion (Gemini OpenAPI dialect → JSON Schema subset)
// ---------------------------------------------------------------------------

export function toJsonSchema(node: Record<string, unknown>): Record<string, unknown> {
  const { type, nullable, properties, items, required, enum: enumValues } = node as {
    type?: string;
    nullable?: boolean;
    properties?: Record<string, Record<string, unknown>>;
    items?: Record<string, unknown>;
    required?: string[];
    enum?: unknown[];
  };
  const out: Record<string, unknown> = {};
  if (type) out.type = type.toLowerCase();
  if (enumValues) out.enum = enumValues;
  if (properties) {
    out.properties = Object.fromEntries(
      Object.entries(properties).map(([key, child]) => [key, toJsonSchema(child)]),
    );
    out.required = required ?? [];
  }
  if (out.type === 'object') out.additionalProperties = false;
  if (items) out.items = toJsonSchema(items);
  return nullable ? { anyOf: [out, { type: 'null' }] } : out;
}

// ---------------------------------------------------------------------------
// Thinking + effort mapping
// ---------------------------------------------------------------------------

// Handlers express depth as Gemini thinking levels. Haiku 5.5 accepts
// `disabled` at effort high or below; Sonnet 5.5 rejects `disabled` and turns
// thinking off with `between_tools` (also high or below). `minimal` is every
// short structured call (substitution, import, grocery, cook-turn, scan);
// `low` is dinner-solve.
function thinkingFor(
  model: ClaudeModel,
  level: AIThinkingLevel | undefined,
): Pick<Anthropic.MessageCreateParamsNonStreaming, 'thinking' | 'output_config'> {
  switch (level) {
    case 'minimal':
    case undefined:
      return {
        thinking: model === ClaudeModel.Sonnet ? { type: 'between_tools' } : { type: 'disabled' },
        output_config: { effort: 'low' },
      };
    case 'low':
      return { thinking: { type: 'adaptive' }, output_config: { effort: 'low' } };
    case 'medium':
      return { thinking: { type: 'adaptive' }, output_config: { effort: 'medium' } };
    case 'high':
      return { thinking: { type: 'adaptive' }, output_config: { effort: 'high' } };
  }
}

// Adaptive thinking spends output tokens before the answer; without headroom a
// caller's answer-sized cap (e.g. 4096 for dinner-solve) would truncate the
// JSON. The cap still bounds cost: Claude bills generated tokens only.
const THINKING_HEADROOM_TOKENS = 4096;

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

const SUPPORTED_IMAGE_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

export async function claudeGenerate(model: ClaudeModel, args: AITextArgs): Promise<AITextResult> {
  if (args.image && args.images) {
    throw new Error('claudeGenerate: pass either `image` or `images`, not both.');
  }
  const images = args.image ? [args.image] : (args.images ?? []);
  const content: Anthropic.ContentBlockParam[] = [];
  for (const img of images) {
    // Claude accepts JPEG/PNG/GIF/WebP. iOS sends JPEG today (ScanViewModel);
    // the HEIC value on the wire enum is a future path Claude cannot serve.
    if (!SUPPORTED_IMAGE_TYPES.has(img.mimeType)) {
      throw new AITextError(415, '', 'unsupported_media_type', `Claude cannot read ${img.mimeType}`);
    }
    content.push({
      type: 'image',
      source: {
        type: 'base64',
        media_type: img.mimeType as 'image/jpeg' | 'image/png' | 'image/webp',
        data: img.dataBase64,
      },
    });
  }
  // Images before text: Anthropic's vision guidance puts the image first.
  content.push({ type: 'text', text: args.userText });

  const depth = thinkingFor(model, args.thinkingLevel);
  const answerCap = args.maxOutputTokens ?? 4096;
  const outputConfig: Record<string, unknown> = { ...depth.output_config };
  if (args.responseSchema) {
    outputConfig.format = { type: 'json_schema', schema: toJsonSchema(args.responseSchema) };
  }

  const params: Anthropic.MessageCreateParamsNonStreaming = {
    model,
    max_tokens: depth.thinking?.type === 'adaptive' ? answerCap + THINKING_HEADROOM_TOKENS : answerCap,
    system: args.systemInstruction,
    messages: [{ role: 'user', content }],
    ...(depth.thinking ? { thinking: depth.thinking } : {}),
    output_config: outputConfig as NonNullable<
      Anthropic.MessageCreateParamsNonStreaming['output_config']
    >,
  };

  // Outside the try: a missing key is a configuration error and must log as
  // itself, not as a wrapped upstream failure.
  const client = clientFor(args.fetchImpl);
  const startedAt = performance.now();
  let response: Anthropic.Message;
  try {
    response = await client.messages.create(params);
  } catch (err) {
    throw toAITextError(err);
  }
  const latencyMs = Math.round(performance.now() - startedAt);

  if (response.stop_reason === 'refusal') {
    // Category only — the explanation can paraphrase prompt content, which
    // carries household data (ADR 0009 privacy posture).
    throw new AITextError(422, '', 'refusal', `Claude refused (category=${response.stop_details?.category ?? 'none'})`);
  }

  const text = response.content
    .map((block) => (block.type === 'text' ? block.text : ''))
    .join('');
  const usage = response.usage;
  const cacheRead = usage.cache_read_input_tokens ?? 0;
  const cacheWrite = usage.cache_creation_input_tokens ?? 0;

  return {
    text,
    finishReason: response.stop_reason ?? 'unknown',
    // `input_tokens` excludes cache reads and writes; log the full prompt size.
    inputTokens: usage.input_tokens + cacheRead + cacheWrite,
    cachedInputTokens: cacheRead,
    cacheWriteTokens: cacheWrite,
    outputTokens: usage.output_tokens,
    // Claude bills image tokens as ordinary input tokens.
    imageInputTokens: 0,
    latencyMs,
    promptVersion: args.promptVersion,
  };
}

// The SDK's typed errors carry the HTTP status and the API error type
// (`overloaded_error`, `rate_limit_error`, …). The message is not forwarded:
// a 400 body can echo prompt fragments (same posture as GeminiError, SA3-W1).
function toAITextError(err: unknown): AITextError {
  if (err instanceof Anthropic.APIConnectionTimeoutError) {
    return new AITextError(504, '', 'timeout', 'Claude request exceeded 30s timeout');
  }
  if (err instanceof Anthropic.APIConnectionError) {
    return new AITextError(502, '', 'connection_error', 'Claude connection failed');
  }
  if (err instanceof Anthropic.APIError) {
    const body = err.error as { error?: { type?: unknown } } | undefined;
    const type = typeof body?.error?.type === 'string' ? body.error.type : undefined;
    return new AITextError(err.status ?? 502, '', type, `Claude error: ${err.status ?? 'unknown'}`);
  }
  return new AITextError(502, '', undefined, `Claude call failed: ${(err as Error)?.name ?? 'unknown'}`);
}
