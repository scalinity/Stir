// Entitlement + quota reads and period-row seeding.
//
// Tier → cap mapping is sourced from CLAUDE.md §"Tier entitlements". If
// spec values change, update TIER_CAPS here — the check is tight.
//
// period_start is anchored to the user's app_users.created_at day-of-month
// (spec: Apple-style subscription anchor). Helpers below compute it from
// a Date and an anchor day.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { UserTier } from './auth.ts';

export type UsageFeatureKey = 'dinner_solve' | 'voice_cook_session' | 'recipe_import';
export const USAGE_FEATURE_KEYS: readonly UsageFeatureKey[] = [
  'dinner_solve',
  'voice_cook_session',
  'recipe_import',
] as const;

export type BillingState =
  | 'none'
  | 'active'
  | 'trial'
  | 'grace'
  | 'cancelled_active'
  | 'expired';

/** Per-tier monthly caps. Mirrors CLAUDE.md "Tier entitlements (authoritative)". */
export const TIER_CAPS: Record<UserTier, Record<UsageFeatureKey, number>> = {
  free:    { dinner_solve: 6,   voice_cook_session: 0,  recipe_import: 2 },
  premium: { dinner_solve: 40,  voice_cook_session: 20, recipe_import: 100_000 },
  pro:     { dinner_solve: 120, voice_cook_session: 40, recipe_import: 100_000 },
};
// ASSUMPTION: "unlimited" Recipe Imports for Premium/Pro is modeled as a
// very large integer (100_000) to keep the atomic cap-check shape uniform.
// Flag if wrong — alternative is cap_count NULL with separate "unlimited" branch.

// ---------------------------------------------------------------------------
// entitlement_snapshots row shape
// ---------------------------------------------------------------------------

export interface EntitlementRow {
  canonical_user_key: string;
  tier: UserTier;
  is_trial: boolean;
  expires_at: string | null;
  billing_state: BillingState;
  raw_webhook_payload: unknown;
  updated_at: string;
}

export async function readEntitlement(
  client: SupabaseClient,
  canonicalKey: string,
): Promise<EntitlementRow | null> {
  const { data, error } = await client
    .from('entitlement_snapshots')
    .select('*')
    .eq('canonical_user_key', canonicalKey)
    .maybeSingle<EntitlementRow>();
  if (error) throw error;
  return data;
}

/** Ensure a Free-tier entitlement row exists; no-op if already present. */
export async function ensureEntitlementRow(
  client: SupabaseClient,
  canonicalKey: string,
): Promise<void> {
  const { error } = await client
    .from('entitlement_snapshots')
    .upsert(
      {
        canonical_user_key: canonicalKey,
        tier: 'free',
        is_trial: false,
        expires_at: null,
        billing_state: 'none',
      },
      { onConflict: 'canonical_user_key', ignoreDuplicates: true },
    );
  if (error) throw error;
}

// ---------------------------------------------------------------------------
// usage_counters
// ---------------------------------------------------------------------------

export interface UsageCounterRow {
  canonical_user_key: string;
  period_start: string; // ISO date (YYYY-MM-DD)
  feature_key: UsageFeatureKey;
  used_count: number;
  cap_count: number;
  tier_at_snapshot: UserTier;
  created_at: string;
  updated_at: string;
}

export interface QuotaWire {
  feature_key: UsageFeatureKey;
  used: number;
  cap: number;
  period_end: string; // ISO date (exclusive end of the user's current period)
}

/**
 * Compute this user's current period_start given an account anchor day.
 * Monthly periods rooted at the day-of-month from `accountCreatedAt`.
 * e.g. account created 2026-01-17 → periods start 17th of each month.
 * Edge case: if anchor day > days-in-month (Feb 29, etc.), clamp to the
 * last day of the current month.
 */
export function computeCurrentPeriodStart(
  accountCreatedAt: Date,
  now: Date = new Date(),
): { periodStart: Date; periodEnd: Date } {
  const anchorDay = accountCreatedAt.getUTCDate();
  const year = now.getUTCFullYear();
  const month = now.getUTCMonth(); // 0-indexed
  const day = now.getUTCDate();

  // Candidate period_start this month, clamped to month length.
  const daysThisMonth = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
  const thisAnchor = Math.min(anchorDay, daysThisMonth);

  let periodYear: number;
  let periodMonth: number;
  let periodDay: number;
  if (day >= thisAnchor) {
    // Current period started this month.
    periodYear = year;
    periodMonth = month;
    periodDay = thisAnchor;
  } else {
    // Previous month's anchor applies.
    const prevMonth = month === 0 ? 11 : month - 1;
    const prevYear = month === 0 ? year - 1 : year;
    const daysPrevMonth = new Date(Date.UTC(prevYear, prevMonth + 1, 0)).getUTCDate();
    periodYear = prevYear;
    periodMonth = prevMonth;
    periodDay = Math.min(anchorDay, daysPrevMonth);
  }

  const periodStart = new Date(Date.UTC(periodYear, periodMonth, periodDay));
  const nextMonth = periodMonth === 11 ? 0 : periodMonth + 1;
  const nextYear = periodMonth === 11 ? periodYear + 1 : periodYear;
  const daysNextMonth = new Date(Date.UTC(nextYear, nextMonth + 1, 0)).getUTCDate();
  const endDay = Math.min(anchorDay, daysNextMonth);
  const periodEnd = new Date(Date.UTC(nextYear, nextMonth, endDay));

  return { periodStart, periodEnd };
}

/** Format a Date as an ISO date string `YYYY-MM-DD` in UTC. */
export function toIsoDate(d: Date): string {
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(
    d.getUTCDate(),
  ).padStart(2, '0')}`;
}

/**
 * Create the three current-period usage_counters rows if missing.
 * cap_count is snapshotted from the passed `tier` (immutable for the period).
 */
export async function ensureCurrentPeriodRows(
  client: SupabaseClient,
  canonicalKey: string,
  tier: UserTier,
  accountCreatedAt: Date,
  now: Date = new Date(),
): Promise<{ periodStart: Date; periodEnd: Date }> {
  const { periodStart, periodEnd } = computeCurrentPeriodStart(accountCreatedAt, now);
  const periodStartIso = toIsoDate(periodStart);
  const caps = TIER_CAPS[tier];

  const rows = USAGE_FEATURE_KEYS.map((feature_key) => ({
    canonical_user_key: canonicalKey,
    period_start: periodStartIso,
    feature_key,
    used_count: 0,
    cap_count: caps[feature_key],
    tier_at_snapshot: tier,
  }));

  const { error } = await client
    .from('usage_counters')
    .upsert(rows, {
      onConflict: 'canonical_user_key,period_start,feature_key',
      ignoreDuplicates: true,
    });
  if (error) throw error;

  return { periodStart, periodEnd };
}

/** Read the three current-period quota rows as wire objects. */
export async function readQuotasForWire(
  client: SupabaseClient,
  canonicalKey: string,
  periodStart: Date,
  periodEnd: Date,
): Promise<QuotaWire[]> {
  const { data, error } = await client
    .from('usage_counters')
    .select('feature_key, used_count, cap_count')
    .eq('canonical_user_key', canonicalKey)
    .eq('period_start', toIsoDate(periodStart));
  if (error) throw error;

  const periodEndIso = toIsoDate(periodEnd);
  type QuotaPartial = Pick<UsageCounterRow, 'feature_key' | 'used_count' | 'cap_count'>;
  const rows = (data ?? []) as QuotaPartial[];
  const byKey = new Map<UsageFeatureKey, { used: number; cap: number }>(
    rows.map((r) => [r.feature_key, { used: r.used_count, cap: r.cap_count }]),
  );

  return USAGE_FEATURE_KEYS.map((feature_key) => {
    const row = byKey.get(feature_key);
    return {
      feature_key,
      used: row?.used ?? 0,
      cap: row?.cap ?? 0,
      period_end: periodEndIso,
    };
  });
}
