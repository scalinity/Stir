// Atomic per-user quota helpers for the three metered features.
//
// Both functions dispatch to Postgres RPCs defined in migration 18:
//   - stir_increment_usage_counter: single UPDATE … WHERE used_count <
//     cap_count … RETURNING. Empty return = capped. No TOCTOU race.
//   - stir_decrement_usage_counter: period-scoped refund. Called when
//     Gemini fails AFTER the counter was incremented. NEVER refund on
//     iOS timeout — the work was done, charge it.
//
// Why RPC instead of chained supabase-js calls: atomicity. Two clients
// could race the check-and-increment; the Postgres function collapses
// it into a single statement.

import type { SupabaseClient } from '@supabase/supabase-js';
import {
  computeCurrentPeriodStart,
  toIsoDate,
  type UsageFeatureKey,
} from './entitlements.ts';
import type { Logger } from './logger.ts';

export type IncrementResult =
  | { status: 'allowed'; used: number; cap: number; period_start: string }
  | { status: 'capped'; used: number; cap: number; period_start: string }
  | { status: 'not_bootstrapped' };

/**
 * Atomic "consume one" against the current period's counter row.
 * Returns 'allowed' if incremented, 'capped' if at limit, or
 * 'not_bootstrapped' when the row doesn't exist yet (iOS bug — a
 * session-bootstrap creates these rows).
 */
export async function incrementQuotaAtomic(
  client: SupabaseClient,
  canonicalKey: string,
  featureKey: UsageFeatureKey,
  accountCreatedAt: Date,
  now: Date = new Date(),
): Promise<IncrementResult> {
  const { periodStart } = computeCurrentPeriodStart(accountCreatedAt, now);
  const periodStartIso = toIsoDate(periodStart);

  const { data, error } = await client.rpc('stir_increment_usage_counter', {
    p_canonical_user_key: canonicalKey,
    p_period_start: periodStartIso,
    p_feature_key: featureKey,
  });
  if (error) throw error;

  const row = Array.isArray(data) ? data[0] : data;
  if (!row) return { status: 'not_bootstrapped' };

  const typed = row as { used_count: number; cap_count: number; status: string };
  if (typed.status === 'allowed') {
    return {
      status: 'allowed',
      used: typed.used_count,
      cap: typed.cap_count,
      period_start: periodStartIso,
    };
  }
  if (typed.status === 'capped') {
    return {
      status: 'capped',
      used: typed.used_count,
      cap: typed.cap_count,
      period_start: periodStartIso,
    };
  }
  return { status: 'not_bootstrapped' };
}

/**
 * Period-scoped refund via RPC. Idempotent: no-ops if the counter is
 * already at 0 or the row doesn't exist.
 *
 * Scoped to the SPECIFIC period_start the caller incremented — crucial
 * because if the request straddles anchor-day midnight, the current
 * period may differ from the one consumed.
 */
export async function refundQuota(
  client: SupabaseClient,
  log: Logger,
  canonicalKey: string,
  featureKey: UsageFeatureKey,
  periodStartIso: string,
): Promise<void> {
  const { data, error } = await client.rpc('stir_decrement_usage_counter', {
    p_canonical_user_key: canonicalKey,
    p_period_start: periodStartIso,
    p_feature_key: featureKey,
  });
  if (error) {
    log.error('quota_refund_failed', error, {
      feature_key: featureKey,
      period_start: periodStartIso,
    });
    return;
  }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row || (row as { refunded: boolean }).refunded === false) {
    log.warn('quota_refund_noop', {
      feature_key: featureKey,
      period_start: periodStartIso,
      reason: 'counter already at zero or row missing',
    });
  }
}
