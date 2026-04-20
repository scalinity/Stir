// Gemini Live ephemeral-token mint helper.
//
// Called from ai-realtime-session to produce a short-lived session token
// the iOS client uses to open a direct WebSocket to Gemini Live. The main
// GEMINI_API_KEY never leaves Supabase — the ephemeral token is scoped to
// one Cook Session by expiry + uses:1 constraint.
//
// Wire facts (CLAUDE.md §Gemini Live sharp-edges #14, verified 2026-04-19):
//   - POST https://generativelanguage.googleapis.com/v1alpha/auth_tokens
//     (snake_case underscore, NOT `authTokens` camelCase)
//   - Auth: `x-goog-api-key: <GEMINI_API_KEY>`, paid-tier AIzaSy key
//   - Body is flat camelCase, NOT wrapped in `{ authToken: {...} }`
//   - Response: { name: "auth_tokens/<hex>" }. The `.name` IS the
//     ephemeral token value — passed as `access_token=<name>` query
//     param on the WebSocket URL.
//
// iOS then connects to:
//   wss://<base>/ws/google.ai.generativelanguage.v1alpha.
//        GenerativeService.BidiGenerateContentConstrained?access_token=<name>
//
// Note: BidiGenerateContentConstrained (NOT BidiGenerateContent) when
// using an ephemeral token. v1alpha (NOT v1beta) for Constrained path.

const MINT_URL = 'https://generativelanguage.googleapis.com/v1alpha/auth_tokens';
const WS_BASE = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained';

/** Stir policy constants from CLAUDE.md §Gemini Live constants. */
export const LIVE_MINT_OPEN_WINDOW_SEC = 60;     // session must open within 60s
export const LIVE_MINT_HARD_DEADLINE_SEC = 35 * 60;  // session itself times out at 35min (5min past the 30min model limit)

/** Function tool declarations baked into the session. CLAUDE.md §Cook
 * Mode Architecture §7. Ordering is stable so prompt_versions schema_hash
 * has something deterministic to key off when we bump the prompt. */
export const COOK_MODE_TOOLS: Array<Record<string, unknown>> = [
  {
    name: 'substitution_check',
    description:
      'Check safe ingredient substitutions against the current recipe and the user\'s dietary rules. ' +
      'Before calling this tool, you MUST first say a short filler out loud like "Let me see what\'ll work" or "Let me check that". ' +
      'Never call this tool without speaking first.',
    parameters: {
      type: 'OBJECT',
      properties: {
        missing_ingredient: { type: 'STRING', description: 'Ingredient the user is out of, as a short display name.' },
        user_problem: { type: 'STRING', description: 'Short paraphrase of what the user said, for logs.' },
      },
      required: ['missing_ingredient'],
    },
  },
  {
    name: 'start_timer',
    description:
      'Start a timer for the current or upcoming step. Before calling, say "Starting timer now" out loud.',
    parameters: {
      type: 'OBJECT',
      properties: {
        seconds: { type: 'INTEGER', description: 'Duration in seconds.' },
        label: { type: 'STRING', description: 'Short label for the timer.' },
      },
      required: ['seconds'],
    },
  },
  {
    name: 'advance_step',
    description:
      "Move to the next step when the user says they're done with the current one. No preamble needed — this is instantaneous.",
    parameters: { type: 'OBJECT', properties: {} },
  },
];

export interface LiveMintConfig {
  /** The full rendered system-prompt text (already has recipe + household
   * context substituted). Baked into the token. */
  systemInstruction: string;
  /** Model string, e.g. "models/gemini-3.1-flash-live-preview". */
  model: string;
  /** Thinking level for the session. Defaults to "minimal" (lowest TTFA,
   * zero thoughts-tokens cost). Escalation path to "low" is gated by the
   * `cook_voice_thinking_level` feature flag. */
  thinkingLevel?: 'minimal' | 'low';
  /** Prebuilt voice name. Default "Aoede" per Cook Mode Architecture. */
  voiceName?: string;
  /** Max output audio tokens per turn. Stir policy: 150. CLAUDE.md #8. */
  maxOutputTokens?: number;
  /** Turn coverage mode. April 2026 default:
   * TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO. */
  turnCoverage?: string;
}

export interface LiveMintResult {
  /** `auth_tokens/<hex>` — the ephemeral resource name that IS the token
   * value for the WebSocket query param. */
  tokenName: string;
  /** ISO-8601 timestamp when the full session deadline elapses. */
  expiresAt: string;
  /** Full WebSocket URL ready for iOS to open — includes the access_token
   * query param pre-populated. */
  wsUrl: string;
  /** Serialized JSON for the FIRST WebSocket message iOS must send
   * immediately after `ws.open`, shape: `{"setup": {...}}`. The server
   * does NOT emit `setupComplete` until it receives this frame — tested
   * on 2026-04-20 against the official google-gemini example. Sending
   * the exact `bidiGenerateContentSetup` body that was baked into the
   * mint matches the Constrained token's authorized config, so the
   * frame is accepted and `setupComplete` returns. */
  setupFrameJSON: string;
}

export class LiveMintError extends Error {
  public readonly statusCode: number;
  public readonly upstreamBody: string;
  constructor(statusCode: number, upstreamBody: string) {
    super(`Gemini Live mint failed: status=${statusCode} body=${upstreamBody.slice(0, 200)}`);
    this.name = 'LiveMintError';
    this.statusCode = statusCode;
    this.upstreamBody = upstreamBody;
  }
}

/**
 * Mint an ephemeral token for one Gemini Live session with the given
 * config baked in.
 *
 * Throws `LiveMintError` on non-2xx upstream responses; the handler maps
 * these to AI-01 (upstream) or AI-VOICE-01 (kill-switch) per the request
 * context.
 */
export async function mintLiveToken(config: LiveMintConfig): Promise<LiveMintResult> {
  const apiKey = Deno.env.get('GEMINI_API_KEY');
  if (!apiKey) {
    throw new LiveMintError(500, 'GEMINI_API_KEY not set in Edge Function env');
  }

  const now = new Date();
  const openDeadline = new Date(now.getTime() + LIVE_MINT_OPEN_WINDOW_SEC * 1000);
  const hardDeadline = new Date(now.getTime() + LIVE_MINT_HARD_DEADLINE_SEC * 1000);

  const thinkingLevel = config.thinkingLevel ?? 'minimal';
  const voiceName = config.voiceName ?? 'Aoede';
  const maxOutputTokens = config.maxOutputTokens ?? 150;
  const turnCoverage = config.turnCoverage ?? 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO';

  const bidiGenerateContentSetup = {
    model: config.model,
    generationConfig: {
      responseModalities: ['AUDIO'],
      speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName } } },
      maxOutputTokens,
      thinkingConfig: { thinkingLevel },
    },
    systemInstruction: { parts: [{ text: config.systemInstruction }] },
    tools: [{ functionDeclarations: COOK_MODE_TOOLS }],
    realtimeInputConfig: {
      automaticActivityDetection: { disabled: false },
      turnCoverage,
    },
  };

  const body = {
    expireTime: hardDeadline.toISOString(),
    newSessionExpireTime: openDeadline.toISOString(),
    uses: 1,
    bidiGenerateContentSetup,
  };

  const res = await fetch(MINT_URL, {
    method: 'POST',
    headers: {
      'x-goog-api-key': apiKey,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new LiveMintError(res.status, text);
  }

  const parsed = await res.json() as { name?: string };
  const tokenName = parsed.name;
  if (!tokenName) {
    throw new LiveMintError(500, 'mint response missing .name field');
  }

  return {
    tokenName,
    expiresAt: hardDeadline.toISOString(),
    wsUrl: `${WS_BASE}?access_token=${encodeURIComponent(tokenName)}`,
    setupFrameJSON: JSON.stringify({ setup: bidiGenerateContentSetup }),
  };
}
