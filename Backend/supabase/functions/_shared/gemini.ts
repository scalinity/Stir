// Gemini client scaffolding.
//
// Step 1 deliberately does NOT make AI calls. This module exists so that
// every later Edge Function that needs Gemini imports from here, making it
// architecturally impossible to leak the API key out of Edge Function space
// into iOS-bound code. Reading GEMINI_API_KEY at module load proves the
// env plumbing works even though we don't send it anywhere yet.
//
// Activated in step 3+ (pantry-parse, dinner-solve, substitution, etc.).
// Cook Mode Live auth-token mint activated in step 6.

// Module-load check: ensures .env wiring is correct even though step 1
// doesn't actually call out. Missing key is fatal so we fail loud, not quiet.
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY');
if (!GEMINI_API_KEY) {
  // Not throwing here — step 1 loads this module but doesn't invoke it.
  // Step 3+ imports will throw at call time via the error below.
  console.warn(
    JSON.stringify({
      level: 'warn',
      msg: 'gemini_env_missing',
      detail: 'GEMINI_API_KEY missing from environment; step 3+ handlers will fail at call time.',
    }),
  );
}

export enum GeminiModel {
  Flash = 'gemini-3-flash',
  FlashLite = 'gemini-3.1-flash-lite',
  FlashLivePreview = 'gemini-3.1-flash-live-preview',
}

export type GeminiThinkingLevel = 'minimal' | 'low' | 'medium' | 'high';

export interface GeminiGenerateArgs {
  model: GeminiModel;
  systemInstruction: string;
  userContent: string;
  thinkingLevel?: GeminiThinkingLevel;
  responseSchema?: Record<string, unknown>;
  maxOutputTokens?: number;
}

export interface GeminiGenerateResult {
  text: string;
  inputTokens: number;
  outputTokens: number;
  latencyMs: number;
  promptVersion?: string;
}

export interface GeminiLiveAuthTokenArgs {
  systemInstruction: string;
  tools: unknown[];
  maxOutputTokens: number;
  thinkingLevel: GeminiThinkingLevel;
  sessionLifetimeSeconds: number;
  openWindowSeconds: number;
}

export interface GeminiLiveAuthToken {
  token: string;
  expires_at: string; // ISO timestamp
}

const STEP_ONE_SENTINEL =
  'Step 1: Gemini not wired yet — activated in step 3+ (/v1/ai/* handlers).';

/** Text/multimodal generation. Implemented in step 3+. */
export function geminiGenerate(_args: GeminiGenerateArgs): Promise<GeminiGenerateResult> {
  throw new Error(STEP_ONE_SENTINEL);
}

/** Gemini Live ephemeral-token mint. Implemented in step 6. */
export function geminiMintLiveAuthToken(
  _args: GeminiLiveAuthTokenArgs,
): Promise<GeminiLiveAuthToken> {
  throw new Error(STEP_ONE_SENTINEL);
}
