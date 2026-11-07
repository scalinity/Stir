// Text-model router (ADR 0038). Every /v1/ai/* text call goes through
// `aiTextGenerate`; the model string decides the provider, and
// `textModelFor(feature)` decides the model from the `AI_TEXT_PROVIDER`
// secret. One selection for every endpoint — no per-request cross-vendor
// fallback (ADR 0038 decision 2).

import { ClaudeModel, claudeGenerate } from './claude.ts';
import { GeminiError, geminiGenerate, GeminiModel } from './gemini.ts';
import { AITextError } from './ai_text_error.ts';

export { AITextError };

export type AIThinkingLevel = 'minimal' | 'low' | 'medium' | 'high';

export interface InlineImagePart {
  mimeType: 'image/jpeg' | 'image/png' | 'image/heic' | 'image/webp';
  dataBase64: string;
}

export interface AITextArgs {
  systemInstruction: string;
  /** Plain-text user content. */
  userText: string;
  /** Optional single image. Mutually exclusive with `images`. */
  image?: InlineImagePart;
  /** Optional multi-image input (SCA-35 Pro pantry-parse). Caller enforces caps. */
  images?: InlineImagePart[];
  thinkingLevel?: AIThinkingLevel;
  /** Gemini OpenAPI-dialect schema for structured JSON output. */
  responseSchema?: Record<string, unknown>;
  maxOutputTokens?: number;
  /** Returned verbatim on the result for telemetry. */
  promptVersion?: string;
  /** For tests: override the provider client's fetch. */
  fetchImpl?: typeof fetch;
}

export interface AITextResult {
  text: string;
  finishReason: string;
  /** Full prompt size, cached and uncached. */
  inputTokens: number;
  /** Portion of `inputTokens` served from the provider's prompt cache. */
  cachedInputTokens: number;
  /** Portion of `inputTokens` written to the prompt cache (Claude only). */
  cacheWriteTokens: number;
  outputTokens: number;
  imageInputTokens: number;
  latencyMs: number;
  promptVersion: string | undefined;
}

/** `ai_request_log.feature_key` values for the text endpoints. */
export type TextFeature =
  | 'pantry_parse'
  | 'dinner_solve'
  | 'substitution'
  | 'recipe_step_rewrite'
  | 'cook_turn'
  | 'recipe_import'
  | 'grocery_generate';

export type TextProvider = 'anthropic' | 'gemini';
export type TextModel = ClaudeModel | GeminiModel;

// Per-feature models. The Claude column is the parity-check result recorded
// in ADR 0038; the Gemini column is the pre-0038 assignment with the shut-down
// Lite preview replaced.
const MODELS: Readonly<Record<TextProvider, Readonly<Record<TextFeature, TextModel>>>> = {
  anthropic: {
    pantry_parse: ClaudeModel.Haiku,
    dinner_solve: ClaudeModel.Haiku,
    // Sonnet: on eval_substitutions_v1 it passes 48/50 with prompt v1.2.0
    // against Haiku's 42-43/50 (Haiku keeps naming the replaced
    // ingredient, which the hard-rule scan rejects). ADR 0038.
    substitution: ClaudeModel.Sonnet,
    recipe_step_rewrite: ClaudeModel.Haiku,
    cook_turn: ClaudeModel.Haiku,
    recipe_import: ClaudeModel.Haiku,
    grocery_generate: ClaudeModel.Haiku,
  },
  gemini: {
    pantry_parse: GeminiModel.Flash,
    dinner_solve: GeminiModel.Flash,
    substitution: GeminiModel.Flash,
    recipe_step_rewrite: GeminiModel.Flash,
    cook_turn: GeminiModel.Flash,
    recipe_import: GeminiModel.FlashLite,
    grocery_generate: GeminiModel.FlashLite,
  },
};

/** Provider selected by the `AI_TEXT_PROVIDER` secret; `anthropic` when unset. */
export function textProvider(): TextProvider {
  const raw = Deno.env.get('AI_TEXT_PROVIDER')?.trim().toLowerCase();
  if (raw === undefined || raw === '' || raw === 'anthropic') return 'anthropic';
  if (raw === 'gemini') return 'gemini';
  // A typo must not silently pick a provider; fail loudly at the first call.
  throw new Error(`AI_TEXT_PROVIDER must be 'anthropic' or 'gemini', got '${raw}'.`);
}

export function textModelFor(feature: TextFeature): TextModel {
  return MODELS[textProvider()][feature];
}

export function isTextFeature(key: string): key is TextFeature {
  return Object.hasOwn(MODELS.anthropic, key);
}

const CLAUDE_MODELS = new Set<string>(Object.values(ClaudeModel));

export async function aiTextGenerate(
  args: AITextArgs & { model: TextModel },
): Promise<AITextResult> {
  if (CLAUDE_MODELS.has(args.model)) {
    return await claudeGenerate(args.model as ClaudeModel, args);
  }
  try {
    const result = await geminiGenerate({ ...args, model: args.model as GeminiModel });
    return { ...result, cachedInputTokens: 0, cacheWriteTokens: 0 };
  } catch (err) {
    if (err instanceof GeminiError) {
      throw new AITextError(err.status, err.body, err.upstreamStatus, err.message);
    }
    throw err;
  }
}
