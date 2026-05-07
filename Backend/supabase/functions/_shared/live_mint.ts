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
const WS_BASE =
  'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained';

/** Stir policy constants from CLAUDE.md §Gemini Live constants. */
export const LIVE_MINT_OPEN_WINDOW_SEC = 60; // session must open within 60s
export const LIVE_MINT_HARD_DEADLINE_SEC = 35 * 60; // session itself times out at 35min (5min past the 30min model limit)

/** Function tool declarations baked into the session. CLAUDE.md §Cook
 * Mode Architecture §7. Ordering is stable so prompt_versions schema_hash
 * has something deterministic to key off when we bump the prompt. */
export const COOK_MODE_TOOLS: Array<Record<string, unknown>> = [
  {
    name: 'substitution_check',
    description:
      "Check safe ingredient substitutions against the current recipe and the user's dietary rules. " +
      'Before calling this tool, you MUST first say a short filler out loud like "Let me see what\'ll work" or "Let me check that". ' +
      'Never call this tool without speaking first.',
    parameters: {
      type: 'OBJECT',
      properties: {
        missing_ingredient: {
          type: 'STRING',
          description: 'Ingredient the user is out of, as a short display name.',
        },
        user_problem: {
          type: 'STRING',
          description: 'Short paraphrase of what the user said, for logs.',
        },
      },
      required: ['missing_ingredient'],
    },
  },
  {
    name: 'start_timer',
    description:
      'Start a timer for the current step. Use when the user says "start the timer", "set a timer for N minutes", or when they ask to begin a timed step. Before calling, say a short filler like "Starting timer now" out loud.',
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
    name: 'get_timer_status',
    description:
      "Check the current timer's state and remaining time. Use when the user asks 'how much time is left', 'is the timer running', 'how long until the timer goes off', or any similar question. Returns { state, remaining_seconds, total_seconds, label }. No preamble needed — just call it.",
    parameters: { type: 'OBJECT', properties: {} },
  },
  {
    name: 'pause_timer',
    description:
      'Pause the currently running timer. Use when the user says "pause the timer", "hold on", "stop for a second", or similar pause intents. Before calling, say a short filler like "Pausing now" out loud.',
    parameters: { type: 'OBJECT', properties: {} },
  },
  {
    name: 'resume_timer',
    description:
      'Resume a paused timer. Use when the user says "resume the timer", "start it back up", "unpause", or similar. Before calling, say a short filler like "Resuming" out loud.',
    parameters: { type: 'OBJECT', properties: {} },
  },
  {
    name: 'cancel_timer',
    description:
      'Cancel the currently running or paused timer. Use when the user says "cancel the timer", "stop the timer entirely", or "nevermind the timer". Before calling, say a short filler like "Cancelling" out loud.',
    parameters: { type: 'OBJECT', properties: {} },
  },
  {
    name: 'restart_timer',
    description:
      'Restart the current timer — cancels the existing timer (if any) and starts a fresh one. Use when the user says "restart the timer", "start the timer over", "reset the timer", or "start the timer again". This is a SINGLE atomic tool call — do NOT call cancel_timer + start_timer separately. If the user specifies a new duration ("restart for 5 minutes"), pass seconds; otherwise omit seconds to reuse the existing timer\'s duration. Before calling, say a short filler like "Restarting timer" out loud.',
    parameters: {
      type: 'OBJECT',
      properties: {
        seconds: {
          type: 'INTEGER',
          description:
            "Optional duration in seconds for the restarted timer. If omitted, reuses the existing timer's total duration. Required if no timer currently exists on this step.",
        },
        label: { type: 'STRING', description: 'Optional label for the restarted timer.' },
      },
    },
  },
  {
    name: 'set_step',
    description:
      "Navigate the cooking UI to a specific step number. Use whenever the user says anything indicating they want to see a specific step — 'next step', 'I\\'m done with this step' (pass current_step+1), 'go back to step 3', 'jump to step 5', 'skip ahead', 'show me step N', 'let\\'s finish' (pass total_steps). Works forward OR backward. No preamble needed.",
    parameters: {
      type: 'OBJECT',
      properties: {
        step_number: {
          type: 'INTEGER',
          description:
            '1-indexed step number to navigate to. Must be between 1 and total_steps inclusive.',
        },
      },
      required: ['step_number'],
    },
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
  /** Max output audio tokens per turn. Stir policy: 300 (see CLAUDE.md
   * #8 and ADR 0010). 150 was too tight — 2-sentence responses
   * exceeding 6 seconds of speech (e.g., step instructions with an
   * amount + a doneness cue) hit the cap mid-sentence. 300 covers
   * ~12 seconds at 25 tokens/sec, which matches the "2 short sentences"
   * prompt budget with a safety margin. */
  maxOutputTokens?: number;
  /** Turn coverage mode. April 2026 default:
   * TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO. */
  turnCoverage?: string;
  /** VAD tuning profile. `semantic_vad` (default) uses the tuned
   * silence/sensitivity config validated 2026-04-20..22 for kitchen
   * noise tolerance. `server_vad` passes `{ disabled: false }` only,
   * letting Gemini use its own defaults — a kill-switch fallback if
   * the tuned profile misbehaves in prod. Driven by the
   * `voice_turn_detection_mode` feature flag. */
  turnDetectionMode?: 'semantic_vad' | 'server_vad';
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
    // SA3-12: .message MUST NOT contain the upstream body — Gemini
    // error payloads can echo the rendered systemInstruction (which
    // carries household dietary rules + recipe context rendered into
    // the prompt). `upstreamBody` stays on the instance for targeted
    // dev debugging; surface it through logs only when the explicit
    // STIR_LOG_GEMINI_BODIES env flag is set (see callers below).
    super(`Gemini Live mint failed: status=${statusCode}`);
    this.name = 'LiveMintError';
    this.statusCode = statusCode;
    this.upstreamBody = upstreamBody;
  }
}

/** Whether `LiveMintError.upstreamBody` may be logged. Defaults OFF in
 * production. Set `STIR_LOG_GEMINI_BODIES=true` in dev/staging only. */
export function shouldLogGeminiBodies(): boolean {
  const raw = Deno.env.get('STIR_LOG_GEMINI_BODIES') ?? 'false';
  return /^(1|true|yes|on)$/i.test(raw.trim());
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
  const maxOutputTokens = config.maxOutputTokens ?? 400;
  const turnCoverage = config.turnCoverage ?? 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO';
  const turnDetectionMode = config.turnDetectionMode ?? 'semantic_vad';

  // VAD profile switch — `semantic_vad` is the tuned-for-kitchen
  // config; `server_vad` is the escape hatch that defers to Gemini's
  // defaults if the tuned config misbehaves.
  const automaticActivityDetection = turnDetectionMode === 'server_vad' ? { disabled: false } : {
    disabled: false,
    silenceDurationMs: 800,
    prefixPaddingMs: 300,
    startOfSpeechSensitivity: 'START_SENSITIVITY_LOW',
    endOfSpeechSensitivity: 'END_SENSITIVITY_LOW',
  };

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
      // Automatic VAD — hands-free is the core Premium UX (dirty
      // hands, cooking, can't tap a button to end each utterance).
      //
      // Empirical testing 2026-04-20..22 with `{ disabled: false }`
      // alone (no explicit params, no transcription) got zero
      // server response over 40 s on good audio. Hypothesis:
      // default silence-duration / sensitivity doesn't fire on
      // iPhone mic noise floors with just speech + room ambience.
      // Explicit values below match the ranges the Gemini reference
      // app ships with, widened slightly for kitchen noise tolerance.
      //
      //   silenceDurationMs=800   — ~natural pause; short enough to
      //                              feel responsive, long enough to
      //                              not clip multi-clause queries.
      //   prefixPaddingMs=300     — include ~300 ms before VAD-
      //                              detected speech (catches soft
      //                              onsets).
      //   startOfSpeechSensitivity=LOW — less likely to trigger on
      //                              ambient kitchen noise.
      //   endOfSpeechSensitivity=LOW   — only fire on clear pauses,
      //                              not mid-utterance micropauses.
      //
      // `server_vad` mode bypasses the tuned profile and passes just
      // `{ disabled: false }` — escape hatch via feature flag.
      automaticActivityDetection,
      turnCoverage,
    },
    // Transcription: diagnostic + long-term VoiceTurn persistence.
    // With this on, `serverContent.inputTranscription` tells us
    // EXACTLY what Gemini heard (if anything — silence means the
    // audio pipeline is broken, not VAD). `outputTranscription`
    // gives us the text of what Gemini spoke back for logs.
    //
    // Tiny token cost per turn (~25-50 input, similar output) and
    // gives us the observability we've been missing while debugging
    // the "no reply" problem.
    inputAudioTranscription: {},
    outputAudioTranscription: {},
  };

  const body = {
    expireTime: hardDeadline.toISOString(),
    newSessionExpireTime: openDeadline.toISOString(),
    uses: 1,
    bidiGenerateContentSetup,
  };

  // P0-K (2026-04-23): 10 s timeout on the Gemini mint call. Without
  // this, a Gemini outage or partial-network stall hangs the Edge
  // Function until Supabase's platform request timeout fires (~150 s),
  // stretching the user-visible voice-start path from ~500 ms to 150 s
  // during upstream degradation. 10 s matches the iOS client-side
  // timeout on /v1/ai/realtime-session, so iOS and backend converge on
  // the same failure mode instead of one hanging while the other has
  // already given up. AbortError is mapped to a typed 504 below so the
  // handler returns AI-01 502 consistently.
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), 10_000);
  let res: Response;
  try {
    res = await fetch(MINT_URL, {
      method: 'POST',
      headers: {
        'x-goog-api-key': apiKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch (err) {
    if ((err as Error).name === 'AbortError') {
      throw new LiveMintError(504, 'Gemini mint request exceeded 10s timeout');
    }
    throw err;
  } finally {
    clearTimeout(timeoutId);
  }

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
