// In-process tests for the effective-tier / voice-enabled resolver.
//
// Motivation: CLAUDE.md §"entitlement_snapshots.billing_state enum" mandates
// that billing_state='none'|'expired' → Free tier regardless of what the
// RevenueCat-authoritative `tier` column remembers. This prevents a lapsed
// Premium subscriber from getting Premium caps snapshotted into a new
// usage_counters period, and keeps voice_enabled consistent with the
// canAccess() gate on iOS.

import './_helpers/env.ts';
import { assertEquals } from '@std/assert';
import {
  effectiveTier,
  effectiveVoiceEnabled,
  STANDING_PANTRY_CAPS,
  standingPantryCap,
  type BillingState,
} from '../functions/_shared/entitlements.ts';
import type { UserTier } from '../functions/_shared/auth.ts';

function row(tier: UserTier, billing_state: BillingState) {
  return { tier, billing_state };
}

// Effective tier: tier survives only when billing_state indicates active payment.

Deno.test('effectiveTier: free tier passes through for every billing_state', () => {
  for (const bs of ['none', 'active', 'trial', 'grace', 'cancelled_active', 'expired'] as const) {
    assertEquals(effectiveTier(row('free', bs)), 'free', `free + ${bs}`);
  }
});

Deno.test('effectiveTier: premium paid billing states stay premium', () => {
  for (const bs of ['active', 'trial', 'grace', 'cancelled_active'] as const) {
    assertEquals(effectiveTier(row('premium', bs)), 'premium', `premium + ${bs}`);
  }
});

Deno.test('effectiveTier: premium + expired → free (win-back downgrade)', () => {
  assertEquals(effectiveTier(row('premium', 'expired')), 'free');
});

Deno.test('effectiveTier: premium + none → free (defensive; should be impossible)', () => {
  // `none` on a premium row shouldn't happen in practice (RevenueCat webhook
  // would have left tier='free' if never purchased), but the resolver must
  // still downgrade rather than trust the row.
  assertEquals(effectiveTier(row('premium', 'none')), 'free');
});

Deno.test('effectiveTier: pro + expired → free', () => {
  assertEquals(effectiveTier(row('pro', 'expired')), 'free');
});

Deno.test('effectiveTier: pro + grace stays pro (still entitled during Apple retry)', () => {
  assertEquals(effectiveTier(row('pro', 'grace')), 'pro');
});

// Voice enabled: paid tier AND paid billing state.

Deno.test('effectiveVoiceEnabled: free is always false', () => {
  for (const bs of ['none', 'active', 'trial', 'grace', 'cancelled_active', 'expired'] as const) {
    assertEquals(effectiveVoiceEnabled(row('free', bs)), false);
  }
});

Deno.test('effectiveVoiceEnabled: premium paid states → true', () => {
  for (const bs of ['active', 'trial', 'grace', 'cancelled_active'] as const) {
    assertEquals(effectiveVoiceEnabled(row('premium', bs)), true, `premium + ${bs}`);
  }
});

Deno.test('effectiveVoiceEnabled: premium + expired → false (critical invariant)', () => {
  // Regression guard for the critical bug where `tier !== 'free'` was used
  // directly. A lapsed Premium user must NOT get voice_enabled=true.
  assertEquals(effectiveVoiceEnabled(row('premium', 'expired')), false);
});

Deno.test('effectiveVoiceEnabled: premium + none → false', () => {
  assertEquals(effectiveVoiceEnabled(row('premium', 'none')), false);
});

Deno.test('effectiveVoiceEnabled: pro paid states → true', () => {
  for (const bs of ['active', 'trial', 'grace', 'cancelled_active'] as const) {
    assertEquals(effectiveVoiceEnabled(row('pro', bs)), true, `pro + ${bs}`);
  }
});

// SCA-100 — standing-pantry-cap value table + effective-tier resolution.

Deno.test('STANDING_PANTRY_CAPS: matches CLAUDE.md tier-entitlements table', () => {
  // Lock the cap-per-tier table at the constant so the values can't
  // drift between Backend and iOS (which carries the same numbers in
  // Tier.rememberedPantryCap as a fallback). CLAUDE.md §"Tier
  // entitlements (authoritative)" is the source of truth.
  assertEquals(STANDING_PANTRY_CAPS.free, 25);
  assertEquals(STANDING_PANTRY_CAPS.premium, 250);
  assertEquals(STANDING_PANTRY_CAPS.pro, 1000);
});

Deno.test('standingPantryCap: paid premium → 250', () => {
  for (const bs of ['active', 'trial', 'grace', 'cancelled_active'] as const) {
    assertEquals(standingPantryCap(row('premium', bs)), 250, `premium + ${bs}`);
  }
});

Deno.test('standingPantryCap: paid pro → 1000', () => {
  for (const bs of ['active', 'trial', 'grace', 'cancelled_active'] as const) {
    assertEquals(standingPantryCap(row('pro', bs)), 1000, `pro + ${bs}`);
  }
});

Deno.test('standingPantryCap: free always → 25', () => {
  for (const bs of ['none', 'active', 'trial', 'grace', 'cancelled_active', 'expired'] as const) {
    assertEquals(standingPantryCap(row('free', bs)), 25, `free + ${bs}`);
  }
});

Deno.test('standingPantryCap: expired premium → 25 (effective-tier demotion)', () => {
  // Critical: a lapsed Premium user with `tier='premium', billing_state='expired'`
  // must demote to the Free cap. Without this routing through effectiveTier(),
  // a stale RevenueCat row would keep their 250-item cap even after Apple
  // expired the subscription.
  assertEquals(standingPantryCap(row('premium', 'expired')), 25);
});

Deno.test('standingPantryCap: expired pro → 25 (effective-tier demotion)', () => {
  assertEquals(standingPantryCap(row('pro', 'expired')), 25);
});

Deno.test('standingPantryCap: premium + none → 25 (defensive demotion)', () => {
  // `none` on a premium row shouldn't happen in practice, but the
  // resolver must demote rather than trust the stale tier column —
  // mirrors the same defense effectiveTier applies for canAccess.
  assertEquals(standingPantryCap(row('premium', 'none')), 25);
});
