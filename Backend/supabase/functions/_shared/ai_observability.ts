// AI Observability — typed `$ai_generation` emission for PostHog LLM
// Analytics (dual-write with ai_request_log).
//
// Thin typed layer over _shared/posthog.ts so call sites don't have to
// hand-assemble PostHog-reserved property names. Every AI call site that
// writes to ai_request_log uses `recordAIRequest` — one helper that
// upserts the row AND fires the matching `$ai_generation` event, with
// retry-safe semantics: on ON CONFLICT DO NOTHING, the PostHog capture
// is suppressed so dashboards don't double-count. 1:1 reconciliation
// by `$ai_span_id = ai_request_log.request_id`.
//
// Dashboard-join contract (ADR 0009, spec §15):
//   distinct_id   = canonical_user_key_hash        (who)
//   $ai_span_id   = ai_request_log.request_id      (which call)
//   $ai_trace_id  = feature-specific grouping id   (solve_request_id |
//                                                   session_id |
//                                                   import_id | ...)
//   $ai_parent_id = unused v1 (flat span structure)
//
// Privacy: no $ai_input / $ai_output_choices. Tokens + cost + latency +
// model + prompt_version + feature + thinking_level + error metadata only.
//
// Cost: callers pass the EXACT `cost_usd` value that lands in
// ai_request_log. No client-side math, no PostHog cost catalog — Stir's
// preview models aren't in PostHog's catalog so we forward our number
// authoritatively.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from './logger.ts';
import { hashCanonicalKey } from './hashing.ts';
import { capturePosthogEvent } from './posthog.ts';
import { type AIRequestLogEntry, insertAIRequestLog } from './ai_request_log.ts';

// ---------------------------------------------------------------------------
// recordAIRequest — dual-write with retry-safe PostHog capture
// ---------------------------------------------------------------------------

/**
 * Metadata an `$ai_generation` event carries that isn't already in the
 * ai_request_log row shape. Mirrors AIGenerationEntry's non-row fields.
 */
export interface AIGenerationMetadata {
  /** PostHog $ai_trace_id. Feature-scoped grouping id:
   *  solve_request_id | import_id | sub_event_id | session_id | client_request_id. */
  trace_id: string;
  /** Human-readable span name for the PostHog trace/span view. */
  span_name: string;
  is_error?: boolean;
  /** Stir ErrorCode when is_error=true. */
  error_code?: string;
  /** Voice-turn discriminator; absent on non-voice AI. */
  path?: 'live_api' | 'gemini_fallback';
}

/**
 * Single-call dual-write: upsert `ai_request_log` row AND fire PostHog
 * `$ai_generation` on successful insert. Enforces the 1:1 reconciliation
 * contract from ADR 0009 — on retry with the same request_id, the row's
 * ON CONFLICT DO NOTHING fires AND we skip the PostHog capture so
 * dashboards aren't double-counted.
 *
 * Use this at every AI-call site that expects a PostHog `$ai_generation`.
 * `logAIRequest` (without capture) remains for anchor rows only —
 * realtime-session mint's zero-cost row, which has no matching generation.
 *
 * Fire-and-forget via EdgeRuntime.waitUntil so the caller's response
 * isn't gated on either write.
 */
export function recordAIRequest(
  client: SupabaseClient,
  log: Logger,
  rowEntry: AIRequestLogEntry,
  generation: AIGenerationMetadata,
): void {
  const task = (async () => {
    // Misuse guard: an empty canonical_user_key would hash to a
    // constant distinct_id, cross-attributing events from different
    // callers to the same PostHog person. Fail loud so the bug surfaces
    // in ops rather than silently corrupting identity.
    if (!rowEntry.canonical_user_key) {
      log.error(
        'record_ai_request_missing_canonical_key',
        new Error('rowEntry.canonical_user_key is empty — refusing to write'),
        {
          request_id: rowEntry.request_id,
          feature_key: rowEntry.feature_key,
        },
      );
      return;
    }

    const { wasInserted, error } = await insertAIRequestLog(client, rowEntry);
    if (error) {
      log.error('ai_request_log_write_failed', error, {
        request_id: rowEntry.request_id,
        feature_key: rowEntry.feature_key,
      });
      // Don't fire PostHog on write failure — dashboards stay in sync with
      // Supabase: missing row → missing event.
      return;
    }
    if (!wasInserted) {
      // Conflict path: this request_id already has a row from an earlier
      // attempt. Skipping PostHog prevents retry double-capture. Logged
      // at info level so ops can trend retry rate without noise.
      log.info('ai_request_log_conflict_skip_capture', {
        request_id: rowEntry.request_id,
        feature_key: rowEntry.feature_key,
      });
      return;
    }

    // Newly inserted — fire PostHog $ai_generation.
    const distinctId = await hashCanonicalKey(rowEntry.canonical_user_key);
    const properties: Record<string, unknown> = {
      $ai_trace_id: generation.trace_id,
      $ai_span_id: rowEntry.request_id,
      $ai_span_name: generation.span_name,
      $ai_model: rowEntry.model,
      $ai_provider: 'gemini',
      $ai_input_tokens: rowEntry.input_tokens,
      $ai_output_tokens: rowEntry.output_tokens,
      $ai_total_cost_usd: rowEntry.cost_usd,
      $ai_latency: rowEntry.latency_ms / 1000,
      $ai_is_error: generation.is_error === true,
      feature: rowEntry.feature_key,
    };
    // Implicit-cache read tokens — PostHog standard property. Emitted
    // only when the row has a non-zero cached count so dashboards that
    // aggregate SUM($ai_cache_read_input_tokens) don't lose their
    // "how many cache reads fired?" count. Feeds the spec §9 cap-
    // reversal trigger (cachedContentTokenCount ≥ 50% of prompt).
    if (
      rowEntry.prompt_cached_tokens !== undefined &&
      rowEntry.prompt_cached_tokens > 0
    ) {
      properties.$ai_cache_read_input_tokens = rowEntry.prompt_cached_tokens;
    }
    if (rowEntry.prompt_version !== undefined) {
      properties.prompt_version = rowEntry.prompt_version;
    }
    if (rowEntry.thinking_level !== undefined) {
      properties.thinking_level = rowEntry.thinking_level;
    }
    if (rowEntry.retry_count !== undefined) {
      properties.retry_count = rowEntry.retry_count;
    }
    if (generation.is_error && generation.error_code) {
      properties.$ai_error = generation.error_code;
      properties.error_code = generation.error_code;
    }
    if (generation.path !== undefined) {
      properties.path = generation.path;
    }

    capturePosthogEvent(log, {
      event: '$ai_generation',
      distinctId,
      properties,
    });
  })();

  const runtime = (globalThis as { EdgeRuntime?: { waitUntil: (p: Promise<unknown>) => void } })
    .EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(task);
  }
}

// $ai_trace emission lives on iOS (PostHogClient.captureAITrace in Swift).
// The backend does not emit $ai_trace — the single session trace fires at
// close from CookModeViewModel. A mint-time backend emission was considered
// and dropped in ADR 0009: PostHog is append-only, so a mint + close pair
// would produce two sibling events rather than updating a single record.
