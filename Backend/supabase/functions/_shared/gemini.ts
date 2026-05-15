// Gemini client — REST generateContent for text + multimodal inputs.
//
// Endpoints (CLAUDE.md §Endpoints):
//   generateContent: POST https://generativelanguage.googleapis.com/v1beta/
//                         models/<model>:generateContent
//   authTokens (Live): POST /v1alpha/authTokens  — not wired until step 6
//
// Auth header: `x-goog-api-key: <GEMINI_API_KEY>` (Bearer/token-scheme
// pitfalls are Live-only per CLAUDE.md; generateContent accepts the
// header auth cleanly).
//
// Base URL is env-overridable via `GEMINI_BASE_URL` so integration tests
// can point at a local mock without code changes. Default is Google's
// production endpoint.

const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY');
const GEMINI_BASE_URL = Deno.env.get('GEMINI_BASE_URL') ??
  'https://generativelanguage.googleapis.com';

if (!GEMINI_API_KEY) {
  console.warn(
    JSON.stringify({
      level: 'warn',
      msg: 'gemini_env_missing',
      detail: 'GEMINI_API_KEY missing; /v1/ai/* handlers will throw on first call.',
    }),
  );
}

// ---------------------------------------------------------------------------
// Model + thinking-level types (step 1 carryover)
// ---------------------------------------------------------------------------

export enum GeminiModel {
  Flash = 'gemini-3-flash-preview',
  FlashLite = 'gemini-3.1-flash-lite-preview',
  FlashLivePreview = 'gemini-3.1-flash-live-preview',
}

export type GeminiThinkingLevel = 'minimal' | 'low' | 'medium' | 'high';

// ASSUMPTION: Gemini 3 Flash accepts thinkingConfig.thinkingBudget (0 =
// minimal/disabled; larger = more reasoning tokens). If the API shape
// drifted between April 2026 cutoff and the real Gemini 3 rollout,
// adjust mapLevelToBudget() below. Verified against pricing docs for
// the 4.5/tokens-per-1M pricing model.
function mapLevelToBudget(level: GeminiThinkingLevel | undefined): number | undefined {
  switch (level) {
    case 'minimal':
      return 0;
    case 'low':
      return 1024;
    case 'medium':
      return undefined; // omit → model default
    case 'high':
      return 8192;
    case undefined:
      return undefined;
  }
}

// ---------------------------------------------------------------------------
// Request / response types
// ---------------------------------------------------------------------------

export interface InlineImagePart {
  mimeType: 'image/jpeg' | 'image/png' | 'image/heic' | 'image/webp';
  dataBase64: string;
}

export interface GeminiGenerateArgs {
  model: GeminiModel;
  systemInstruction: string;
  /** Plain-text user content. Rendered as the first part of a user message. */
  userText: string;
  /** Optional inline image appended after userText. Mutually exclusive with `images`. */
  image?: InlineImagePart;
  /**
   * Optional multi-image input — appended in order after `userText`. Mutually
   * exclusive with `image`. Used by SCA-35 multi-image pantry-parse (Pro).
   * Caller is responsible for caps; this layer just forwards the parts.
   */
  images?: InlineImagePart[];
  thinkingLevel?: GeminiThinkingLevel;
  /** JSON schema for structured output. When set, response_mime_type=application/json. */
  responseSchema?: Record<string, unknown>;
  maxOutputTokens?: number;
  /** Attach prompt_version for telemetry — returned verbatim on the result. */
  promptVersion?: string;
  /** For integration tests: override the client's default fetch. */
  fetchImpl?: typeof fetch;
}

export interface GeminiGenerateResult {
  text: string;
  finishReason: string;
  inputTokens: number;
  outputTokens: number;
  imageInputTokens: number;
  latencyMs: number;
  promptVersion: string | undefined;
}

export class GeminiError extends Error {
  readonly status: number;
  readonly body: string;
  /** Structured upstream status enum from Google's error envelope
   * (e.g. "INVALID_ARGUMENT", "RESOURCE_EXHAUSTED", "PERMISSION_DENIED",
   * "FAILED_PRECONDITION"). Extracted from `body.error.status` when the
   * body parses as the canonical Google error shape; `undefined` for
   * synthetic errors (timeout, non-JSON, no-candidates) or when the
   * upstream returned a non-canonical body. PII-safe — the status enum
   * never echoes prompt content, unlike `body` or `error.message`.
   * SCA-429: lets `gemini_call_failed` log lines name the failure class
   * without leaking the full upstream body. */
  readonly upstreamStatus: string | undefined;
  constructor(status: number, body: string, message?: string) {
    super(message ?? `Gemini error: ${status}`);
    this.name = 'GeminiError';
    this.status = status;
    this.body = body;
    this.upstreamStatus = extractUpstreamStatus(body);
  }
}

/** Parse Google's canonical error envelope and return the structured
 * `error.status` enum string. Returns undefined on parse failure or
 * non-canonical shape so callers fall back to bare HTTP status. */
function extractUpstreamStatus(body: string): string | undefined {
  if (!body) return undefined;
  try {
    const parsed = JSON.parse(body) as { error?: { status?: unknown } };
    const status = parsed.error?.status;
    return typeof status === 'string' ? status : undefined;
  } catch {
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// generateContent
// ---------------------------------------------------------------------------

interface ApiPart {
  text?: string;
  inline_data?: { mime_type: string; data: string };
}

interface ApiCandidate {
  content?: { parts?: ApiPart[] };
  finishReason?: string;
}

interface ApiUsageMetadata {
  promptTokenCount?: number;
  candidatesTokenCount?: number;
  totalTokenCount?: number;
  promptTokensDetails?: Array<{ modality?: string; tokenCount?: number }>;
}

interface ApiResponse {
  candidates?: ApiCandidate[];
  usageMetadata?: ApiUsageMetadata;
}

export async function geminiGenerate(args: GeminiGenerateArgs): Promise<GeminiGenerateResult> {
  if (!GEMINI_API_KEY) throw new Error('GEMINI_API_KEY missing; cannot call Gemini.');

  const url = `${GEMINI_BASE_URL}/v1beta/models/${encodeURIComponent(args.model)}:generateContent`;

  if (args.image && args.images) {
    throw new Error('geminiGenerate: pass either `image` or `images`, not both.');
  }
  const parts: ApiPart[] = [{ text: args.userText }];
  if (args.image) {
    parts.push({
      inline_data: { mime_type: args.image.mimeType, data: args.image.dataBase64 },
    });
  } else if (args.images) {
    for (const img of args.images) {
      parts.push({
        inline_data: { mime_type: img.mimeType, data: img.dataBase64 },
      });
    }
  }

  interface GenerationConfig {
    maxOutputTokens?: number;
    response_mime_type?: string;
    response_schema?: Record<string, unknown>;
    thinkingConfig?: { thinkingBudget: number };
  }
  const generationConfig: GenerationConfig = {};
  if (args.maxOutputTokens !== undefined) generationConfig.maxOutputTokens = args.maxOutputTokens;
  if (args.responseSchema !== undefined) {
    generationConfig.response_mime_type = 'application/json';
    generationConfig.response_schema = args.responseSchema;
  }
  const budget = mapLevelToBudget(args.thinkingLevel);
  if (budget !== undefined) generationConfig.thinkingConfig = { thinkingBudget: budget };

  const body = {
    system_instruction: { parts: [{ text: args.systemInstruction }] },
    contents: [{ role: 'user', parts }],
    generationConfig,
  };

  const startedAt = performance.now();
  const fetchImpl = args.fetchImpl ?? fetch;

  // P0-K (2026-04-23): 30 s timeout on generateContent. Gemini's
  // `generateContent` calls are primary-user-path (dinner-solve,
  // cook-turn fallback, substitution, recipe-import, etc.) and the
  // Supabase Edge Function platform timeout of ~150 s would otherwise
  // mask Gemini degradation behind a 3-minute iOS stall. 30 s is
  // generous — most calls complete in 1-4 s, dinner-solve streaming
  // endpoints use their own budgets — but tight enough to fail fast
  // when Gemini is non-responsive. AbortError maps to a 504-shaped
  // GeminiError so handler retry logic sees a well-typed failure.
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 30_000);
  let res: Response;
  try {
    res = await fetchImpl(url, {
      method: 'POST',
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'x-goog-api-key': GEMINI_API_KEY,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      throw new GeminiError(504, '', `Gemini generateContent exceeded 30s timeout`);
    }
    throw err;
  } finally {
    clearTimeout(timeoutId);
  }
  const latencyMs = Math.round(performance.now() - startedAt);

  const rawText = await res.text();
  if (!res.ok) {
    // P1-C / SA3-W1 (2026-04-23): do NOT embed the upstream body in the
    // thrown error message. Gemini's 4xx response body commonly echoes
    // fragments of the rendered system prompt (transcript + household
    // dietary rules + pantry snapshot) — structured-JSON loggers then
    // ship that content to Edge Function logs on every refusal. The
    // body is still available on `err.body` for env-gated dev debugging
    // via `shouldLogGeminiBodies()`; the default log line stays PII-safe.
    // Mirrors the same fix already applied in `_shared/live_mint.ts`.
    throw new GeminiError(res.status, rawText);
  }

  let parsed: ApiResponse;
  try {
    parsed = JSON.parse(rawText) as ApiResponse;
  } catch (err) {
    throw new GeminiError(200, rawText, `Gemini returned non-JSON: ${String(err)}`);
  }

  const candidate = parsed.candidates?.[0];
  if (!candidate) throw new GeminiError(200, rawText, 'Gemini returned no candidates');

  const text = (candidate.content?.parts ?? [])
    .map((p) => p.text ?? '')
    .join('');

  const usage = parsed.usageMetadata ?? {};
  const inputTokens = usage.promptTokenCount ?? 0;
  const outputTokens = usage.candidatesTokenCount ?? 0;

  // Image token count — Gemini reports it in promptTokensDetails[{modality:"IMAGE"}]
  // when multimodal inputs are used.
  let imageInputTokens = 0;
  for (const detail of usage.promptTokensDetails ?? []) {
    if (detail.modality === 'IMAGE' && detail.tokenCount) {
      imageInputTokens += detail.tokenCount;
    }
  }

  return {
    text,
    finishReason: candidate.finishReason ?? 'UNKNOWN',
    inputTokens,
    outputTokens,
    imageInputTokens,
    latencyMs,
    promptVersion: args.promptVersion,
  };
}

// ---------------------------------------------------------------------------
// Live auth token mint
// ---------------------------------------------------------------------------
// Lives in `_shared/live_mint.ts`. Step-6 stub deleted (P2-D, 2026-04-23).
