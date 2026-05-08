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

// ---------------------------------------------------------------------------
// SCA-100 — standing-pantry-item caps (per-tier, non-metered)
// ---------------------------------------------------------------------------
//
// Standing cap on `PantryItem.memoryState = .remembered` rows the user can
// keep across cook sessions. Distinct from `TIER_CAPS` below (those are
// monthly metered usage_counters); this one is a steady-state ceiling
// enforced client-side against CloudKit (no server-side row count, since
// user content lives in CloudKit per north-star #3).
//
// Pre-SCA-100 the value table lived only on iOS (`Tier.rememberedPantryCap`).
// Centralizing it here lets `/v1/session/bootstrap` and
// `/v1/config/bootstrap` ship the value as
// `entitlements.standing_pantry_cap`, so a future marketing A/B or cap
// change is server-resolvable without an iOS release. iOS keeps the
// constant table as a fallback for offline / cached / pre-SCA-100 server
// response paths — see `EntitlementService.standingPantryCap`.
//
// CLAUDE.md §"Tier entitlements (authoritative)" remains the source of
// truth for the values: free 25 / premium 250 / pro 1000.
export const STANDING_PANTRY_CAPS: Record<UserTier, number> = {
  free: 25,
  premium: 250,
  pro: 1000,
};

/**
 * Resolve the standing-pantry-cap value to ship on the wire for a given
 * entitlement row. Goes through `effectiveTier` so a stale RevenueCat
 * column with `billing_state = expired` correctly demotes to the Free
 * cap — same defense the rest of this module relies on for every other
 * entitlement decision.
 */
export function standingPantryCap(
  row: Pick<EntitlementRow, 'tier' | 'billing_state'>,
): number {
  return STANDING_PANTRY_CAPS[effectiveTier(row)];
}

/** Per-tier monthly caps. Mirrors CLAUDE.md "Tier entitlements (authoritative)". */
export const TIER_CAPS: Record<UserTier, Record<UsageFeatureKey, number>> = {
  // ADR 0015 caps (post-step-6 device test, 2026-04-23):
  //   - free.voice_cook_session reverted 20 → 0 (supersedes ADR-0008
  //     testing bump; voice is Premium+ only per CLAUDE.md north-star #6)
  //   - premium.voice_cook_session cut 20 → 13 (~3 dinners/week) — paywall
  //     copy in PaywallView.featuresList + PaywallTrigger.subheadline +
  //     ProComparisonSheet must stay in lockstep with this number
  //   - pro.voice_cook_session cut 40 → 27 ("every dinner" — 6-7/week
  //     at 7 dinners/week ≈ every dinner)
  // Cost model + margin justification: ADR 0015. Cap-reversal trigger +
  // guard rail for raising back toward 20/40: same ADR.
  free: { dinner_solve: 6, voice_cook_session: 0, recipe_import: 2 },
  premium: { dinner_solve: 40, voice_cook_session: 13, recipe_import: 100_000 },
  pro: { dinner_solve: 120, voice_cook_session: 27, recipe_import: 100_000 },
};
// ASSUMPTION: "unlimited" Recipe Imports for Premium/Pro is modeled as a
// very large integer (100_000) to keep the atomic cap-check shape uniform.
// Flag if wrong — alternative is cap_count NULL with separate "unlimited" branch.

// ---------------------------------------------------------------------------
// Effective-tier resolution (CLAUDE.md §"billing_state enum" bootstrap rules)
// ---------------------------------------------------------------------------
//
// The raw `tier` column on entitlement_snapshots is orthogonal to
// `billing_state`: RevenueCat may leave tier='premium' while the subscription
// is `expired` (eligible for win-back). The *effective* tier — the one that
// should drive both quota caps and feature gates — is Free whenever
// billing_state is 'none' or 'expired'.
//
// Every code path that needs "what does this user get right now?" must go
// through effectiveTier() / effectiveVoiceEnabled() — never read
// entitlement.tier directly for gating or cap snapshots.

const PAID_BILLING_STATES: readonly BillingState[] = [
  'active',
  'trial',
  'grace',
  'cancelled_active',
] as const;

export function effectiveTier(row: Pick<EntitlementRow, 'tier' | 'billing_state'>): UserTier {
  if (row.billing_state === 'none' || row.billing_state === 'expired') return 'free';
  return row.tier;
}

export function effectiveVoiceEnabled(
  row: Pick<EntitlementRow, 'tier' | 'billing_state'>,
): boolean {
  // ADR-0008 (Superseded by ADR 0015): the
  // ENTITLEMENT_OVERRIDE_VOICE_FREE env escape hatch stays in the code
  // path so future testing / dev / staging runs can temporarily open
  // voice to all tiers without a cap change. Production must never
  // have this env var set — ADR 0015 reverted the step-6 open state
  // on 2026-04-23. Default remains FAIL-CLOSED (voice gated unless
  // the env is explicitly set), matching the security invariant
  // established during ADR-0008's second review round.
  //
  // To re-enable for dev only:
  //   `supabase secrets set ENTITLEMENT_OVERRIDE_VOICE_FREE=true --project-ref <dev-ref>`
  //   `supabase functions deploy session-bootstrap config-bootstrap ...`
  //
  // Production secret must stay unset (or explicitly false). Runbook:
  // before any cap-related deploy, verify via
  //   `supabase secrets list --project-ref ktqajarcomzplnpbczfo`
  // that ENTITLEMENT_OVERRIDE_VOICE_FREE is absent.
  const overrideRaw = Deno.env.get('ENTITLEMENT_OVERRIDE_VOICE_FREE') ?? 'false';
  const overrideEnabled = /^(1|true|yes|on)$/i.test(overrideRaw.trim());
  if (overrideEnabled) return true;

  const tier = effectiveTier(row);
  return (
    (tier === 'premium' || tier === 'pro') &&
    PAID_BILLING_STATES.includes(row.billing_state)
  );
}

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

/**
 * Ensure a Free-tier entitlement row exists and return it in one call. For
 * returning users (~100% of bootstraps after onboarding) this is one SELECT.
 * For first-time users we SELECT (miss), INSERT, and SELECT again — three
 * round-trips, which is fine because it happens exactly once per user.
 *
 * Previous implementation did upsert+select unconditionally (2 RT for
 * everyone). The read-first variant is strictly better for the common path,
 * and new-user bootstrap is not a latency-sensitive moment.
 */
export async function ensureEntitlementRow(
  client: SupabaseClient,
  canonicalKey: string,
): Promise<EntitlementRow> {
  const existing = await readEntitlement(client, canonicalKey);
  if (existing) return existing;

  // Row missing — INSERT with ON CONFLICT DO NOTHING so a concurrent
  // bootstrap that raced us to insert doesn't trigger an error.
  const { error: insertError } = await client
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
  if (insertError) throw insertError;

  // Re-read: either we inserted (and need to fetch), or a racing caller
  // inserted first (and we need their row).
  const row = await readEntitlement(client, canonicalKey);
  if (!row) throw new Error('entitlement row missing after ensure+upsert');
  return row;
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
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${
    String(
      d.getUTCDate(),
    ).padStart(2, '0')
  }`;
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

/**
 * Thrown by readQuotasForWire when one or more expected usage_counters rows
 * are missing for the requested period. The handler catches this, runs
 * ensureCurrentPeriodRows, and retries — never returns silently because
 * cap=0 on the wire reads as "quota exhausted" on iOS and would block
 * every metered feature.
 */
export class MissingQuotaRowError extends Error {
  readonly missingFeatureKeys: readonly UsageFeatureKey[];
  constructor(missingFeatureKeys: readonly UsageFeatureKey[]) {
    super(
      `usage_counters missing rows for features: ${missingFeatureKeys.join(', ')}`,
    );
    this.name = 'MissingQuotaRowError';
    this.missingFeatureKeys = missingFeatureKeys;
  }
}

/**
 * Read the three current-period quota rows as wire objects. Throws
 * MissingQuotaRowError when any expected feature row is absent — callers
 * must call ensureCurrentPeriodRows BEFORE invoking this function.
 */
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

  const missing = USAGE_FEATURE_KEYS.filter((k) => !byKey.has(k));
  if (missing.length > 0) {
    throw new MissingQuotaRowError(missing);
  }

  return USAGE_FEATURE_KEYS.map((feature_key) => {
    // Non-null assertion justified: we just verified `missing` is empty.
    const row = byKey.get(feature_key)!;
    return {
      feature_key,
      used: row.used,
      cap: row.cap,
      period_end: periodEndIso,
    };
  });
}
