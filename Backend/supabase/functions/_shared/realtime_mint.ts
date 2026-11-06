// OpenAI Realtime client-secret mint (ADR 0038).
//
// Called from realtime-session to produce a short-lived client secret the
// iOS client uses to open a direct WebSocket to OpenAI Realtime. The main
// OPENAI_API_KEY never leaves Supabase — the secret only opens a session,
// and only within its expiry window.
//
// Wire facts (OpenAI docs, retrieved 2026-11-06; sources in ADR 0038):
//   - POST https://api.openai.com/v1/realtime/client_secrets with
//     `expires_after: {anchor:'created_at', seconds}` and a `session`
//     object. Response `{ value: "ek_...", expires_at, session }`.
//   - iOS connects to wss://api.openai.com/v1/realtime?model=<model> with
//     `Authorization: Bearer <value>`.
//   - Audio is PCM16 mono 24 kHz in both directions.
//   - The session config baked here is what the session runs with; the
//     setup frame iOS sends first (`session.update`) carries only the
//     truncation policy, and its `session.updated` reply is iOS's
//     handshake acknowledgement.
//   - Session maximum is 60 minutes; iOS refreshes before then.

import OpenAI from 'openai';

export enum OpenAIRealtimeModel {
  Mini = 'gpt-realtime-2.1-mini',
}

/** Window in which the client secret can open a session. Covers the
 * pre-mint path, which mints about a minute before the swap. */
export const REALTIME_SECRET_TTL_SEC = 120;

const WS_BASE = 'wss://api.openai.com/v1/realtime';

/** ADR 0010 / north-star #8: a bounded output cap exists. 400 output tokens
 * ≈ 18 s of speech at OpenAI's 20 audio tokens/s plus the transcript text. */
export const REALTIME_MAX_OUTPUT_TOKENS = 400;

/** Bounded-growth policy (ADR 0038 decision 4, replacing ADR 0014's
 * refresh cadence). When the conversation after the instructions exceeds
 * `post_instructions` tokens, the server drops the oldest items, keeping
 * 80% so truncation does not recur — and bust the prompt cache — every turn. */
export const REALTIME_TRUNCATION = {
  type: 'retention_ratio',
  retention_ratio: 0.8,
  token_limits: { post_instructions: 8000 },
} as const;

/** Function tools baked into the session. Names and argument shapes are the
 * iOS tool handlers' contract (`LiveFunctionCall` accessors) — do not rename.
 * Ordering is stable so prompt_versions schema_hash has something
 * deterministic to key off when the prompt changes. */
export const COOK_MODE_TOOLS = [
  {
    type: 'function',
    name: 'substitution_check',
    description:
      "Check safe ingredient substitutions against the current recipe and the user's dietary rules. " +
      'Before calling this tool, you MUST first say a short filler out loud like "Let me see what\'ll work" or "Let me check that". ' +
      'Never call this tool without speaking first.',
    parameters: {
      type: 'object',
      properties: {
        missing_ingredient: {
          type: 'string',
          description: 'Ingredient the user is out of, as a short display name.',
        },
        user_problem: {
          type: 'string',
          description: 'Short paraphrase of what the user said, for logs.',
        },
      },
      required: ['missing_ingredient'],
    },
  },
  {
    type: 'function',
    name: 'start_timer',
    description:
      'Start a timer for the current step. Use when the user says "start the timer", "set a timer for N minutes", or when they ask to begin a timed step. Before calling, say a short filler like "Starting timer now" out loud.',
    parameters: {
      type: 'object',
      properties: {
        seconds: { type: 'integer', description: 'Duration in seconds.' },
        label: { type: 'string', description: 'Short label for the timer.' },
      },
      required: ['seconds'],
    },
  },
  {
    type: 'function',
    name: 'get_timer_status',
    description:
      "Check the current timer's state and remaining time. Use when the user asks 'how much time is left', 'is the timer running', 'how long until the timer goes off', or any similar question. Returns { state, remaining_seconds, total_seconds, label }. No preamble needed — just call it.",
    parameters: { type: 'object', properties: {} },
  },
  {
    type: 'function',
    name: 'pause_timer',
    description:
      'Pause the currently running timer. Use when the user says "pause the timer", "hold on", "stop for a second", or similar pause intents. Before calling, say a short filler like "Pausing now" out loud.',
    parameters: { type: 'object', properties: {} },
  },
  {
    type: 'function',
    name: 'resume_timer',
    description:
      'Resume a paused timer. Use when the user says "resume the timer", "start it back up", "unpause", or similar. Before calling, say a short filler like "Resuming" out loud.',
    parameters: { type: 'object', properties: {} },
  },
  {
    type: 'function',
    name: 'cancel_timer',
    description:
      'Cancel the currently running or paused timer. Use when the user says "cancel the timer", "stop the timer entirely", or "nevermind the timer". Before calling, say a short filler like "Cancelling" out loud.',
    parameters: { type: 'object', properties: {} },
  },
  {
    type: 'function',
    name: 'restart_timer',
    description:
      'Restart the current timer — cancels the existing timer (if any) and starts a fresh one. Use when the user says "restart the timer", "start the timer over", "reset the timer", or "start the timer again". This is a SINGLE atomic tool call — do NOT call cancel_timer + start_timer separately. If the user specifies a new duration ("restart for 5 minutes"), pass seconds; otherwise omit seconds to reuse the existing timer\'s duration. Before calling, say a short filler like "Restarting timer" out loud.',
    parameters: {
      type: 'object',
      properties: {
        seconds: {
          type: 'integer',
          description:
            "Optional duration in seconds for the restarted timer. If omitted, reuses the existing timer's total duration. Required if no timer currently exists on this step.",
        },
        label: { type: 'string', description: 'Optional label for the restarted timer.' },
      },
    },
  },
  {
    type: 'function',
    name: 'set_step',
    description:
      "Navigate the cooking UI to a specific step number. Use whenever the user says anything indicating they want to see a specific step — 'next step', 'I\\'m done with this step' (pass current_step+1), 'go back to step 3', 'jump to step 5', 'skip ahead', 'show me step N', 'let\\'s finish' (pass total_steps). Works forward OR backward. No preamble needed.",
    parameters: {
      type: 'object',
      properties: {
        step_number: {
          type: 'integer',
          description:
            '1-indexed step number to navigate to. Must be between 1 and total_steps inclusive.',
        },
      },
      required: ['step_number'],
    },
  },
] as const;

export interface RealtimeMintConfig {
  /** Fully rendered system prompt (recipe + household context + optional
   * refresh recap). */
  instructions: string;
  model: OpenAIRealtimeModel;
  /** Driven by the `cook_voice_thinking_level` flag. `minimal` keeps time
   * to first audio lowest; `low` is the escalation path. */
  reasoningEffort: 'minimal' | 'low';
  /** Driven by the `voice_turn_detection_mode` flag. */
  turnDetectionMode: 'semantic_vad' | 'server_vad';
  /** Hashed canonical user key. OpenAI binds it to the client secret for
   * abuse attribution; never the raw key. */
  safetyIdentifier: string;
  /** For tests: override the SDK's fetch. */
  fetchImpl?: typeof fetch;
}

export interface RealtimeMintResult {
  /** Client secret value (`ek_...`) that authenticates the WebSocket. */
  authToken: string;
  /** ISO-8601 time after which the secret can no longer open a session. */
  expiresAt: string;
  wsUrl: string;
  /** First WebSocket message iOS sends: `session.update` with the
   * truncation policy. Its `session.updated` reply is the handshake ack. */
  setupFrameJSON: string;
}

export class RealtimeMintError extends Error {
  public readonly statusCode: number;
  public readonly upstreamBody: string;
  constructor(statusCode: number, upstreamBody: string) {
    // SA3-12: .message never carries the upstream body — an error payload
    // can echo the rendered instructions, which hold household dietary
    // rules. The body stays on the instance for env-gated dev debugging.
    super(`Realtime mint failed: status=${statusCode}`);
    this.name = 'RealtimeMintError';
    this.statusCode = statusCode;
    this.upstreamBody = upstreamBody;
  }
}

function turnDetectionFor(mode: RealtimeMintConfig['turnDetectionMode']) {
  // `interrupt_response: false` matches the half-duplex mic gate (ADR 0011):
  // iOS does not forward mic audio while the model speaks, so barge-in is
  // not a supported path.
  if (mode === 'server_vad') {
    // Escape hatch: plain energy VAD with the silence/padding values tuned
    // for kitchen noise on the previous provider.
    return {
      type: 'server_vad' as const,
      threshold: 0.6,
      prefix_padding_ms: 300,
      silence_duration_ms: 800,
      create_response: true,
      interrupt_response: false,
    };
  }
  return {
    type: 'semantic_vad' as const,
    eagerness: 'auto' as const,
    create_response: true,
    interrupt_response: false,
  };
}

export async function mintRealtimeSession(config: RealtimeMintConfig): Promise<RealtimeMintResult> {
  const apiKey = Deno.env.get('OPENAI_API_KEY');
  if (!apiKey) {
    throw new RealtimeMintError(500, 'OPENAI_API_KEY not set in Edge Function env');
  }

  // 10 s timeout (P0-K): matches the iOS client-side timeout on
  // /v1/ai/realtime-session so both sides fail the same way. SDK retries
  // off — the handler refunds quota on failure and iOS falls back to C.3.
  const client = new OpenAI({
    apiKey,
    timeout: 10_000,
    maxRetries: 0,
    ...(config.fetchImpl ? { fetch: config.fetchImpl } : {}),
  });

  let secret: OpenAI.Realtime.ClientSecretCreateResponse;
  try {
    secret = await client.realtime.clientSecrets.create(
      {
        expires_after: { anchor: 'created_at', seconds: REALTIME_SECRET_TTL_SEC },
        session: {
          type: 'realtime',
          model: config.model,
          instructions: config.instructions,
          output_modalities: ['audio'],
          max_output_tokens: REALTIME_MAX_OUTPUT_TOKENS,
          reasoning: { effort: config.reasoningEffort },
          audio: {
            input: {
              format: { type: 'audio/pcm', rate: 24000 },
              // Phones in Cook Mode sit on the counter, not at the mouth.
              noise_reduction: { type: 'far_field' },
              // User transcript for VoiceTurn persistence and the
              // transcript card; billed per minute of user speech.
              transcription: { model: 'gpt-transcribe' },
              turn_detection: turnDetectionFor(config.turnDetectionMode),
            },
            output: {
              format: { type: 'audio/pcm', rate: 24000 },
              voice: 'marin',
            },
          },
          tools: COOK_MODE_TOOLS as unknown as OpenAI.Realtime.RealtimeToolsConfig,
          tool_choice: 'auto',
        },
      },
      { headers: { 'OpenAI-Safety-Identifier': config.safetyIdentifier } },
    );
  } catch (err) {
    if (err instanceof OpenAI.APIConnectionTimeoutError) {
      throw new RealtimeMintError(504, 'Realtime mint request exceeded 10s timeout');
    }
    if (err instanceof OpenAI.APIError) {
      throw new RealtimeMintError(err.status ?? 502, JSON.stringify(err.error ?? {}));
    }
    throw err;
  }

  if (!secret.value) {
    throw new RealtimeMintError(500, 'client_secrets response missing value');
  }

  return {
    authToken: secret.value,
    expiresAt: new Date(secret.expires_at * 1000).toISOString(),
    wsUrl: `${WS_BASE}?model=${encodeURIComponent(config.model)}`,
    setupFrameJSON: JSON.stringify({
      type: 'session.update',
      session: { type: 'realtime', truncation: REALTIME_TRUNCATION },
    }),
  };
}
