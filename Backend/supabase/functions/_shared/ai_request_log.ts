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

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from './logger.ts';
import { GeminiModel } from './gemini.ts';

// ---------------------------------------------------------------------------
// Pricing
// ---------------------------------------------------------------------------

export interface ModelPricing {
  textInPer1M: number;    // USD per 1M text input tokens
  audioInPer1M: number;   // USD per 1M audio input tokens
  imageInPer1M: number;   // USD per 1M image tokens (approximated as text-price tier)
  textOutPer1M: number;   // USD per 1M text output tokens
  audioOutPer1M: number;  // USD per 1M audio output tokens (Live only; 0 for non-audio)
}

export const MODEL_PRICING: Readonly<Record<GeminiModel, ModelPricing>> = {
  [GeminiModel.Flash]: {
    textInPer1M: 0.50,
    audioInPer1M: 1.00,
    imageInPer1M: 0.50,
    textOutPer1M: 3.00,
    audioOutPer1M: 0, // not an audio-output model
  },
  [GeminiModel.FlashLite]: {
    textInPer1M: 0.25,
    audioInPer1M: 0.50,
    imageInPer1M: 0.25,
    textOutPer1M: 1.50,
    audioOutPer1M: 0,
  },
  [GeminiModel.FlashLivePreview]: {
    textInPer1M: 0.75,
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
 */
export function computeCostUSD(
  model: GeminiModel,
  counts: {
    textInputTokens: number;
    imageInputTokens?: number;
    audioInputTokens?: number;
    textOutputTokens: number;
    audioOutputTokens?: number;
  },
): number {
  const p = MODEL_PRICING[model];
  const cost =
    (counts.textInputTokens * p.textInPer1M) / 1_000_000 +
    ((counts.imageInputTokens ?? 0) * p.imageInPer1M) / 1_000_000 +
    ((counts.audioInputTokens ?? 0) * p.audioInPer1M) / 1_000_000 +
    (counts.textOutputTokens * p.textOutPer1M) / 1_000_000 +
    ((counts.audioOutputTokens ?? 0) * p.audioOutPer1M) / 1_000_000;
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
}

/**
 * Fire-and-forget write to ai_request_log. Uses EdgeRuntime.waitUntil()
 * when available so the response can return before the log insert
 * completes; falls back to an unawaited promise otherwise.
 *
 * ON CONFLICT (request_id) DO NOTHING makes retries of the same
 * request_id idempotent — the first write wins, later writes silently
 * no-op rather than duplicate rows.
 */
export function logAIRequest(
  client: SupabaseClient,
  log: Logger,
  entry: AIRequestLogEntry,
): void {
  const task = (async () => {
    try {
      const { error } = await client
        .from('ai_request_log')
        .upsert(entry, { onConflict: 'request_id', ignoreDuplicates: true });
      if (error) {
        log.error('ai_request_log_write_failed', error, {
          request_id: entry.request_id,
          feature_key: entry.feature_key,
        });
      }
    } catch (err) {
      log.error('ai_request_log_write_threw', err, {
        request_id: entry.request_id,
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
