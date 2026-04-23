// ai_request_log writer + per-model pricing constants.
//
// Writes are fire-and-forget via EdgeRuntime.waitUntil() so the HTTP
// response isn't gated on the log insert. If the log write fails the
// handler should not surface it to the user — the primary work (AI call)
// already succeeded. Failures log via logger.error for ops visibility.
//
// Pricing table mirrors CLAUDE.md §"Gemini model strings and pricing".
// All rates per 1M tokens. If CLAUDE.md changes, update here — single
// source of truth for cost math in handlers.

import type { PostgrestError, SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from './logger.ts';
import { GeminiModel } from './gemini.ts';

// ---------------------------------------------------------------------------
// Pricing
// ---------------------------------------------------------------------------

export interface ModelPricing {
  textInPer1M: number;    // USD per 1M text input tokens
  /** USD per 1M text input tokens served from implicit context cache.
   *
   * Values below are LITERALS, not derived from `textInPer1M * 0.25`.
   * Keep them as literals: Google's published rates are the source of
   * truth and tiered pricing isn't guaranteed to stay uniform — if
   * one tier's discount rate ever changes, we want to update that tier
   * alone without silently drifting the others. Comment the 25%
   * relationship so future maintainers know the current invariant;
   * verify against https://ai.google.dev/gemini-api/docs/pricing when
   * changing any of these numbers.
   *
   * Flash + FlashLite: 25% of `textInPer1M` per Google's published
   * cached-input rate for `generateContent`. Verified against the
   * pricing page as of 2026-04-23.
   *
   * FlashLivePreview: **unverified assumption**. Google lists caching
   * as "not supported" in the published pricing row for this model,
   * so there's no authoritative cached-input rate to reference. ADR
   * 0015 device measurements confirm `cachedContentTokenCount = 0`
   * on every Live turn, so the cached-cost contribution is always 0
   * in practice. The 0.1875 literal (25% of 0.75) is a best-guess
   * defensive value in case caching ever starts firing; the handler
   * (`voice-turn-usage/index.ts`) also logs at warn level when a
   * non-zero cached count arrives so the assumption break is
   * surfaced BEFORE the cost math feeds a cap-reversal decision. */
  cachedInPer1M: number;
  audioInPer1M: number;   // USD per 1M audio input tokens
  imageInPer1M: number;   // USD per 1M image tokens (approximated as text-price tier)
  textOutPer1M: number;   // USD per 1M text output tokens
  audioOutPer1M: number;  // USD per 1M audio output tokens (Live only; 0 for non-audio)
}

export const MODEL_PRICING: Readonly<Record<GeminiModel, ModelPricing>> = {
  [GeminiModel.Flash]: {
    textInPer1M: 0.50,
    cachedInPer1M: 0.125, // 25% of textInPer1M per Google's cached-input pricing
    audioInPer1M: 1.00,
    imageInPer1M: 0.50,
    textOutPer1M: 3.00,
    audioOutPer1M: 0, // not an audio-output model
  },
  [GeminiModel.FlashLite]: {
    textInPer1M: 0.25,
    cachedInPer1M: 0.0625, // 25% of textInPer1M
    audioInPer1M: 0.50,
    imageInPer1M: 0.25,
    textOutPer1M: 1.50,
    audioOutPer1M: 0,
  },
  [GeminiModel.FlashLivePreview]: {
    textInPer1M: 0.75,
    // Published Gemini pricing lists Live-API caching as "not supported."
    // Kept arithmetically consistent with the 25% discount (0.1875 =
    // 0.75 * 0.25) so IF the invariant ever breaks, cost math is
    // conservative rather than accidentally under-billing. ADR 0015
    // measurements keep `cachedContentTokenCount = 0` for all Live turns,
    // so this rate is a no-op in practice.
    cachedInPer1M: 0.1875,
    audioInPer1M: 3.00,
    imageInPer1M: 0.75,
    textOutPer1M: 4.50,
    audioOutPer1M: 12.00,
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
 *   - Live API caching doesn't fire in practice (ADR 0015 measurement);
 *     FlashLivePreview callers will typically pass 0 here forever, but
 *     the math handles non-zero values correctly if the assumption breaks.
 */
export function computeCostUSD(
  model: GeminiModel,
  counts: {
    textInputTokens: number;
    cachedInputTokens?: number;
    imageInputTokens?: number;
    audioInputTokens?: number;
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
  const safe = (n: number | undefined): number =>
    Number.isFinite(n) ? Math.max(0, n as number) : 0;
  const textInputTokens = safe(counts.textInputTokens);
  const imageInputTokens = safe(counts.imageInputTokens);
  const audioInputTokens = safe(counts.audioInputTokens);
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
  const uncachedTextTokens = textInputTokens - cachedTextTokens;
  const cost =
    (uncachedTextTokens * p.textInPer1M) / 1_000_000 +
    (cachedTextTokens * p.cachedInPer1M) / 1_000_000 +
    (imageInputTokens * p.imageInPer1M) / 1_000_000 +
    (audioInputTokens * p.audioInPer1M) / 1_000_000 +
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
