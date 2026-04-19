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
