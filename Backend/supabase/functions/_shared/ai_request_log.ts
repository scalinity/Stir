// ai_request_log writer + per-model pricing constants.
//
// Writes are fire-and-forget via EdgeRuntime.waitUntil() so the HTTP
// response isn't gated on the log insert. If the log write fails the
// handler should not surface it to the user — the primary work (AI call)
// already succeeded. Failures log via logger.error for ops visibility.
//
// Pricing table mirrors docs/CLAUDE-Constants.md §Models and pricing; the
// sources and retrieval dates are in ADR 0038. All rates per 1M tokens.
// Single source of truth for cost math in handlers.

import type { PostgrestError, SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from './logger.ts';
import { GeminiModel } from './gemini.ts';
import { ClaudeModel } from './claude.ts';
import { OpenAIRealtimeModel } from './realtime_mint.ts';

// ---------------------------------------------------------------------------
// Pricing
// ---------------------------------------------------------------------------

export interface ModelPricing {
  textInPer1M: number; // USD per 1M text input tokens
  /** USD per 1M text input tokens served from the provider's prompt cache.
   *
   * Values below are LITERALS copied from each vendor's pricing page, not
   * derived from `textInPer1M` — vendors change discount ratios per model
   * (Gemini 10%, Claude Haiku 5.5 10%, Sonnet 5.5 5%), and a literal keeps
   * one model's change from silently drifting the others. */
  cachedInPer1M: number;
  /** USD per 1M input tokens written to the prompt cache (Claude 5-minute
   * TTL). 0 for providers that don't bill cache writes separately. */
  cacheWriteInPer1M: number;
  audioInPer1M: number; // USD per 1M audio input tokens
  /** USD per 1M audio input tokens served from the prompt cache (OpenAI
   * Realtime). Omitted where audio input is not cached. */
  cachedAudioInPer1M?: number;
  imageInPer1M: number; // USD per 1M image tokens (Claude bills images as text input)
  textOutPer1M: number; // USD per 1M text output tokens
  audioOutPer1M: number; // USD per 1M audio output tokens (0 for non-audio models)
}

export type PricedModel = GeminiModel | ClaudeModel | OpenAIRealtimeModel;

export const MODEL_PRICING: Readonly<Record<PricedModel, ModelPricing>> = {
  // Claude rates: prompts up to 100K tokens (Haiku 5.5 doubles above that;
  // no Stir prompt approaches it). Verified 2026-11-06, ADR 0038 sources.
  [ClaudeModel.Haiku]: {
    textInPer1M: 0.10,
    cachedInPer1M: 0.01,
    cacheWriteInPer1M: 0.125,
    audioInPer1M: 0,
    imageInPer1M: 0.10,
    textOutPer1M: 0.50,
    audioOutPer1M: 0,
  },
  [ClaudeModel.Sonnet]: {
    textInPer1M: 2.00,
    cachedInPer1M: 0.10,
    cacheWriteInPer1M: 2.50,
    audioInPer1M: 0,
    imageInPer1M: 2.00,
    textOutPer1M: 10.00,
    audioOutPer1M: 0,
  },
  // Gemini rates verified 2026-11-06 against ai.google.dev/gemini-api/docs/pricing.
  [GeminiModel.Flash]: {
    textInPer1M: 0.50,
    cachedInPer1M: 0.05,
    cacheWriteInPer1M: 0,
    audioInPer1M: 1.00,
    imageInPer1M: 0.50,
    textOutPer1M: 3.00,
    audioOutPer1M: 0, // not an audio-output model
  },
  [GeminiModel.FlashLite]: {
    textInPer1M: 0.25,
    cachedInPer1M: 0.025,
    cacheWriteInPer1M: 0,
    audioInPer1M: 0.50,
    imageInPer1M: 0.25,
    textOutPer1M: 1.50,
    audioOutPer1M: 0,
  },
  // OpenAI Realtime rates verified 2026-11-06 against
  // developers.openai.com/api/docs/models/gpt-realtime-2.1-mini.md. Audio
  // tokens: user speech 10/s, model speech 20/s. Caching is automatic.
  [OpenAIRealtimeModel.Mini]: {
    textInPer1M: 0.60,
    cachedInPer1M: 0.06,
    cacheWriteInPer1M: 0,
    audioInPer1M: 10.00,
    cachedAudioInPer1M: 0.30,
    imageInPer1M: 0.80,
    textOutPer1M: 2.40,
    audioOutPer1M: 20.00,
  },
};

/**
 * Compute USD cost for a (possibly multimodal) Gemini call.
 *
 * Caller passes token counts from Gemini's usageMetadata. Image tokens
 * count against image pricing tier (matches textIn for Flash/FlashLite).
 * Audio in/out relevant only on Live; pass 0 for non-Live calls.
 *
 * **Cached text tokens** (`cachedInputTokens`): portion of `textInputTokens`
 * served from Gemini's implicit context cache on `generateContent`. Billed
 * at the 25% cached-input rate rather than the full text-input rate.
 *   - MUST be ≤ `textInputTokens` — the subset relation is enforced by
 *     the Zod validator on the inbound wire (validation.ts cross-field
 *     invariant); this function clamps defensively so a bad caller can't
 *     produce a negative uncached count.
 *   - Omit or pass 0 when the caller doesn't have cached-token data
 *     (most handlers today do not extract `cachedContentTokenCount`; this
 *     param is opt-in until each site wires it through).
 *   - Claude reports cache reads and writes separately; OpenAI Realtime
 *     reports cached text and cached audio separately — pass each to its
 *     own parameter so every portion is priced at its published rate.
 */
export function computeCostUSD(
  model: PricedModel,
  counts: {
    textInputTokens: number;
    cachedInputTokens?: number;
    /** Portion of `textInputTokens` written to the prompt cache (Claude). */
    cacheWriteInputTokens?: number;
    imageInputTokens?: number;
    audioInputTokens?: number;
    /** Portion of `audioInputTokens` served from the prompt cache. */
    cachedAudioInputTokens?: number;
    textOutputTokens: number;
    audioOutputTokens?: number;
  },
): number {
  const p = MODEL_PRICING[model];
  // Coerce non-finite counts (NaN / Infinity) to 0. The Zod wire
  // validator rejects non-finite values upstream for HTTP callers;
  // this is defense in depth for programmatic callers (internal
  // retries, test fixtures, future call sites) so a bad input produces
  // a sane 0 rather than propagating NaN into `ai_request_log.cost_usd`
  // and tripping the NUMERIC(10,6) constraint at insert time.
  const safe = (n: number | undefined): number => Number.isFinite(n) ? Math.max(0, n as number) : 0;
  const textInputTokens = safe(counts.textInputTokens);
  const imageInputTokens = safe(counts.imageInputTokens);
  const audioInputTokens = safe(counts.audioInputTokens);
  // Cached audio is a subset of audio input; clamp like cached text.
  const cachedAudioTokens = Math.min(safe(counts.cachedAudioInputTokens), audioInputTokens);
  const textOutputTokens = safe(counts.textOutputTokens);
  const audioOutputTokens = safe(counts.audioOutputTokens);
  // Clamp cached in BOTH directions: `≥ 0` (a negative cached count
  // would inflate the uncached portion and over-report cost) and
  // `≤ textInputTokens` (cached tokens are a subset of text input;
  // if a buggy caller reports more cached than text, preserve the
  // invariant `uncached ≥ 0`). The Zod wire validator enforces
  // `0 ≤ prompt_tokens_cached ≤ prompt_tokens_total` on inbound
  // payloads — this double-clamp protects internal callers that
  // bypass the wire.
  const cachedTextTokens = Math.max(
    0,
    Math.min(safe(counts.cachedInputTokens), textInputTokens),
  );
  // Same subset clamp for cache writes, against what remains after reads.
  const cacheWriteTokens = Math.min(
    safe(counts.cacheWriteInputTokens),
    textInputTokens - cachedTextTokens,
  );
  const uncachedTextTokens = textInputTokens - cachedTextTokens - cacheWriteTokens;
  const cost = (uncachedTextTokens * p.textInPer1M) / 1_000_000 +
    (cachedTextTokens * p.cachedInPer1M) / 1_000_000 +
    (cacheWriteTokens * p.cacheWriteInPer1M) / 1_000_000 +
    (imageInputTokens * p.imageInPer1M) / 1_000_000 +
    ((audioInputTokens - cachedAudioTokens) * p.audioInPer1M) / 1_000_000 +
    (cachedAudioTokens * (p.cachedAudioInPer1M ?? p.audioInPer1M)) / 1_000_000 +
    (textOutputTokens * p.textOutPer1M) / 1_000_000 +
    (audioOutputTokens * p.audioOutPer1M) / 1_000_000;
  // Round to 6 decimal places to match ai_request_log.cost_usd NUMERIC(10,6).
  return Math.round(cost * 1_000_000) / 1_000_000;
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

export interface AIRequestLogEntry {
  request_id: string;
  canonical_user_key: string;
  feature_key: string;
  model: string;
  input_tokens: number;
  output_tokens: number;
  cost_usd: number;
  latency_ms: number;
  thinking_level?: string;
  prompt_version?: string;
  retry_count: number;
  /** Gemini Live `cachedContentTokenCount` — portion of `input_tokens`
   * served from implicit context cache. Non-voice features omit this
   * (caching is a Live API construct in the Stir stack). Feeds PostHog
   * `$ai_cache_read_input_tokens` standard property. Powers the spec §9
   * cap-reversal trigger. */
  prompt_cached_tokens?: number;
  /** Voice session UUID. Populated only on cook_mode_realtime rows
   * alongside request_id='voice:<session_id>:<turn_index>'. NULL for
   * non-voice features. Indexed via idx_ai_request_log_voice_session
   * (partial: feature_key='cook_mode_realtime') for ops aggregations
   * (stir_ops_list_voice_sessions, cost anomaly voice branch). Added
   * in migration 20260424000003. */
  session_id?: string;
}

/**
 * Result of an insert attempt. `wasInserted` distinguishes "row is new"
 * from "row already existed and DO NOTHING-equivalent fired" — callers
 * that chain side effects (e.g. PostHog capture in recordAIRequest)
 * must only fire on `wasInserted === true`, otherwise retries
 * double-report.
 */
export interface InsertAIRequestLogResult {
  wasInserted: boolean;
  error?: unknown;
}

/** PostgreSQL unique_violation error code. */
const PG_UNIQUE_VIOLATION_CODE = '23505';

/**
 * Awaitable insert of ai_request_log. Returns whether the row was
 * actually inserted (true) or a prior row with the same request_id
 * already existed (false). Never throws.
 *
 * Uses a plain INSERT + unique-violation catch rather than PostgREST
 * upsert+ignoreDuplicates+select. The previous upsert-based design had
 * an observed bug 2026-04-22: the FIRST call in a worker returned the
 * inserted row as expected, but SUBSEQUENT calls within the same worker
 * returned empty data even on successful inserts — causing PostHog
 * captures to silently skip (3 rows in ai_request_log, only 1 in
 * PostHog for the same voice session). INSERT with explicit 23505
 * (PostgreSQL unique_violation) detection is more predictable and
 * sidesteps whatever internal state the upsert path was holding.
 */
export async function insertAIRequestLog(
  client: SupabaseClient,
  entry: AIRequestLogEntry,
): Promise<InsertAIRequestLogResult> {
  try {
    const { error } = await client
      .from('ai_request_log')
      .insert(entry);
    if (error) {
      // `error` is a PostgrestError; narrow the type so the `.code`
      // access is compile-time checked. unique_violation = first
      // write won, current call is a retry. PostHog capture
      // correctly suppressed so dashboards don't double-count.
      const pgError = error as PostgrestError;
      if (pgError.code === PG_UNIQUE_VIOLATION_CODE) {
        return { wasInserted: false };
      }
      return { wasInserted: false, error };
    }
    return { wasInserted: true };
  } catch (err) {
    return { wasInserted: false, error: err };
  }
}

/**
 * Fire-and-forget write to ai_request_log. Uses EdgeRuntime.waitUntil()
 * when available so the response can return before the log insert
 * completes; falls back to an unawaited promise otherwise.
 *
 * Prefer `recordAIRequest` in ai_observability.ts for AI-call sites —
 * that helper additionally fires PostHog `$ai_generation` and guarantees
 * the reconciliation contract by only capturing on `wasInserted = true`.
 *
 * This fire-and-forget variant is for anchor rows (e.g., realtime-session
 * mint's zero-cost row) where no PostHog event is wanted.
 */
export function logAIRequest(
  client: SupabaseClient,
  log: Logger,
  entry: AIRequestLogEntry,
): void {
  const task = (async () => {
    const { error } = await insertAIRequestLog(client, entry);
    if (error) {
      log.error('ai_request_log_write_failed', error, {
        request_id: entry.request_id,
        feature_key: entry.feature_key,
      });
    }
  })();

  // Deno Deploy / Supabase Edge Runtime supports EdgeRuntime.waitUntil to
  // keep tasks running past response return. If unavailable (e.g. local
  // one-off test), the task still runs to completion because the test
  // harness awaits it via the returned promise's side effect on the
  // event loop — but we intentionally do NOT await here.
  const runtime = (globalThis as { EdgeRuntime?: { waitUntil: (p: Promise<unknown>) => void } })
    .EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(task);
  }
  // Else: task was already started; it'll complete on the event loop.
}
