// Pure unit tests for resolveEventAction + verifyAuthHeader + productIdToTier.
//
// No DB, no HTTP. Just exercises the resolver's event → action transitions
// verbatim against CLAUDE.md §"RC event → billing_state transition" table.

import './_helpers/env.ts';
import { assertEquals } from '@std/assert';
import {
  HANDLED_EVENT_TYPES,
  isEventFresh,
  MAX_EVENT_AGE_MS,
  PRODUCT_TIER_MAP,
  productIdToTier,
  resolveEventAction,
  verifyAuthHeader,
  type RevenueCatEvent,
} from '../functions/_shared/revenuecat.ts';

// ---------------------------------------------------------------------------
// Event factory — only fields the resolver cares about. Extra fields are
// allowed by the .passthrough() schema.
// ---------------------------------------------------------------------------

function event(overrides: Partial<RevenueCatEvent> & { type: string }): RevenueCatEvent {
  // Defaults first, overrides last — `type` is required on overrides so the
  // spread always wins for it. Keeps the typechecker happy (no duplicate-key
  // warnings) and leaves the test call sites readable.
  return {
    id: `evt_${crypto.randomUUID()}`,
    app_user_id: `ck:_${crypto.randomUUID().split('-').join('')}`,
    environment: 'SANDBOX',
    ...overrides,
  } as RevenueCatEvent;
}

// ---------------------------------------------------------------------------
// verifyAuthHeader
// ---------------------------------------------------------------------------

Deno.test('verifyAuthHeader: equal strings match', () => {
  assertEquals(verifyAuthHeader('abc123', 'abc123'), true);
});

Deno.test('verifyAuthHeader: null header fails', () => {
  assertEquals(verifyAuthHeader(null, 'abc123'), false);
});

Deno.test('verifyAuthHeader: empty received fails against non-empty expected', () => {
  assertEquals(verifyAuthHeader('', 'abc123'), false);
});

Deno.test('verifyAuthHeader: length mismatch short-circuits false', () => {
  assertEquals(verifyAuthHeader('abc', 'abc123'), false);
  assertEquals(verifyAuthHeader('abc123X', 'abc123'), false);
});

Deno.test('verifyAuthHeader: same length, different bytes → false', () => {
  assertEquals(verifyAuthHeader('abc124', 'abc123'), false);
});

Deno.test('verifyAuthHeader: multi-byte unicode treated byte-wise', () => {
  // "Bearer é" (é is 2 UTF-8 bytes) must match itself and reject a
  // visually-similar substitution.
  assertEquals(verifyAuthHeader('Bearer é', 'Bearer é'), true);
  assertEquals(verifyAuthHeader('Bearer e', 'Bearer é'), false);
});

// ---------------------------------------------------------------------------
// productIdToTier
// ---------------------------------------------------------------------------

Deno.test('productIdToTier: all four known SKUs map correctly', () => {
  assertEquals(productIdToTier('stir.premium.monthly'), 'premium');
  assertEquals(productIdToTier('stir.premium.annual.trial7'), 'premium');
  assertEquals(productIdToTier('stir.pro.monthly'), 'pro');
  assertEquals(productIdToTier('stir.pro.annual'), 'pro');
});

Deno.test('productIdToTier: unknown and null return null', () => {
  assertEquals(productIdToTier('unknown'), null);
  assertEquals(productIdToTier(undefined), null);
  assertEquals(productIdToTier(''), null);
});

Deno.test('PRODUCT_TIER_MAP is frozen (Object.freeze applied)', () => {
  // The map must stay unchanged under a write attempt. In Deno strict mode
  // the write throws; in lenient runtimes it silently fails. Only the
  // "map unchanged" invariant is runtime-portable, so that's all we assert —
  // whether the write threw is an incidental detail.
  try {
    // deno-lint-ignore no-explicit-any
    (PRODUCT_TIER_MAP as any)['stir.something.new'] = 'pro';
  } catch (_err) {
    // Ignore — strict-mode throw is acceptable.
  }
  assertEquals('stir.something.new' in PRODUCT_TIER_MAP, false);
});

// ---------------------------------------------------------------------------
// resolveEventAction — happy paths per CLAUDE.md transition table
// ---------------------------------------------------------------------------

Deno.test('INITIAL_PURCHASE with TRIAL period → tier=premium, billing_state=trial, is_trial=true', () => {
  const action = resolveEventAction(event({
    type: 'INITIAL_PURCHASE',
    product_id: 'stir.premium.annual.trial7',
    period_type: 'TRIAL',
    expiration_at_ms: Date.UTC(2026, 3, 26), // 7 days from 2026-04-19
  }));
  assertEquals(action.kind, 'upsert_entitlement');
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'premium');
    assertEquals(action.billing_state, 'trial');
    assertEquals(action.is_trial, true);
    assertEquals(action.expires_at, new Date(Date.UTC(2026, 3, 26)).toISOString());
  }
});

Deno.test('INITIAL_PURCHASE with NORMAL period → billing_state=active, is_trial=false', () => {
  const action = resolveEventAction(event({
    type: 'INITIAL_PURCHASE',
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
  }));
  assertEquals(action.kind, 'upsert_entitlement');
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'premium');
    assertEquals(action.billing_state, 'active');
    assertEquals(action.is_trial, false);
  }
});

Deno.test('INITIAL_PURCHASE with INTRO period → counts as trial', () => {
  // RC uses INTRO and TRIAL interchangeably for intro-offer deliveries;
  // resolver treats both the same way.
  const action = resolveEventAction(event({
    type: 'INITIAL_PURCHASE',
    product_id: 'stir.premium.annual.trial7',
    period_type: 'INTRO',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.billing_state, 'trial');
    assertEquals(action.is_trial, true);
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('RENEWAL → billing_state=active regardless of prior state', () => {
  const action = resolveEventAction(event({
    type: 'RENEWAL',
    product_id: 'stir.pro.annual',
    period_type: 'NORMAL',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'pro');
    assertEquals(action.billing_state, 'active');
    assertEquals(action.is_trial, false);
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('CANCELLATION → billing_state=cancelled_active, tier preserved, is_trial=false', () => {
  const action = resolveEventAction(event({
    type: 'CANCELLATION',
    product_id: 'stir.premium.monthly',
    period_type: 'NORMAL',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'premium');
    assertEquals(action.billing_state, 'cancelled_active');
    assertEquals(action.is_trial, false);
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('CANCELLATION during TRIAL forces is_trial=false (cancelled state is authoritative)', () => {
  // Regression guard: a user who cancels mid-trial should NOT produce
  // { billing_state: 'cancelled_active', is_trial: true }. The iOS UI
  // would show contradictory copy ("Free trial" + "Cancels on <date>").
  const action = resolveEventAction(event({
    type: 'CANCELLATION',
    product_id: 'stir.premium.annual.trial7',
    period_type: 'TRIAL',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.billing_state, 'cancelled_active');
    assertEquals(action.is_trial, false);
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('UNCANCELLATION → billing_state=active, is_trial=false', () => {
  const action = resolveEventAction(event({
    type: 'UNCANCELLATION',
    product_id: 'stir.pro.monthly',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.billing_state, 'active');
    assertEquals(action.is_trial, false);
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('UNCANCELLATION ignores a stale period_type=TRIAL (always is_trial=false)', () => {
  const action = resolveEventAction(event({
    type: 'UNCANCELLATION',
    product_id: 'stir.premium.annual.trial7',
    period_type: 'TRIAL',  // stale/defensive value
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.is_trial, false);
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('TRANSFER ignores when transferred_to is empty (no fallback to app_user_id)', () => {
  // Regression guard for CA1 F3: previous version fell back to
  // event.app_user_id, which could silently target the wrong canonical
  // key on a malformed payload.
  const action = resolveEventAction(event({
    type: 'TRANSFER',
    app_user_id: 'ck:_abcdef1234567890abcdef1234567890ab',
    transferred_from: ['ck:_from_record_aaaaaaaaaaaaaaaaaa'],
    transferred_to: [],
  }));
  assertEquals(action.kind, 'ignore');
});

Deno.test('TRANSFER ignores when transferred_from is empty (symmetric to transferred_to guard)', () => {
  // Defense-in-depth: both arrays must be populated. An absent
  // transferred_from would strand the entitlement on a phantom source.
  const action = resolveEventAction(event({
    type: 'TRANSFER',
    app_user_id: 'ck:_abcdef1234567890abcdef1234567890ab',
    transferred_from: [],
    transferred_to: ['ck:_abcdef1234567890abcdef1234567890ab'],
  }));
  assertEquals(action.kind, 'ignore');
});

Deno.test('TRANSFER where from === to is ignored (noop transfer)', () => {
  // Edge case: RC can fire a same-value transfer on boundary crossings
  // where the subscription didn't actually move. Ignoring avoids a pointless
  // write that would re-bump updated_at for no reason.
  const key = 'ck:_abcdef1234567890abcdef1234567890ab';
  const action = resolveEventAction(event({
    type: 'TRANSFER',
    app_user_id: key,
    transferred_from: [key],
    transferred_to: [key],
  }));
  assertEquals(action.kind, 'ignore');
});

Deno.test('BILLING_ISSUE → billing_state=grace, tier preserved', () => {
  const action = resolveEventAction(event({
    type: 'BILLING_ISSUE',
    product_id: 'stir.premium.monthly',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'premium');
    assertEquals(action.billing_state, 'grace');
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('EXPIRATION with product_id → billing_state=expired, tier preserved', () => {
  // tier preserved for win-back segmentation; effectiveTier() maps 'expired'
  // to 'free' server-side for gating.
  const action = resolveEventAction(event({
    type: 'EXPIRATION',
    product_id: 'stir.premium.annual.trial7',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'premium');
    assertEquals(action.billing_state, 'expired');
    assertEquals(action.is_trial, false);
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('EXPIRATION without product_id → billing_state=expired, tier=free default', () => {
  const action = resolveEventAction(event({
    type: 'EXPIRATION',
    // no product_id — RC sometimes omits on EXPIRATION
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'free');
    assertEquals(action.billing_state, 'expired');
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('PRODUCT_CHANGE premium → pro → tier flips, billing_state=active', () => {
  // Resolver doesn't know previous state; PRODUCT_CHANGE always writes the
  // new product's tier with billing_state=active.
  const action = resolveEventAction(event({
    type: 'PRODUCT_CHANGE',
    product_id: 'stir.pro.monthly',
  }));
  if (action.kind === 'upsert_entitlement') {
    assertEquals(action.tier, 'pro');
    assertEquals(action.billing_state, 'active');
  } else {
    throw new Error('expected upsert_entitlement');
  }
});

Deno.test('NON_RENEWING_PURCHASE → ignore with reason', () => {
  const action = resolveEventAction(event({ type: 'NON_RENEWING_PURCHASE' }));
  assertEquals(action.kind, 'ignore');
});

Deno.test('Unknown event type → ignore', () => {
  const action = resolveEventAction(event({ type: 'SOMETHING_RC_ADDED' }));
  assertEquals(action.kind, 'ignore');
});

Deno.test('Unknown product_id on INITIAL_PURCHASE → ignore (never upsert with bogus tier)', () => {
  const action = resolveEventAction(event({
    type: 'INITIAL_PURCHASE',
    product_id: 'stir.some.future.sku',
  }));
  assertEquals(action.kind, 'ignore');
});

// ---------------------------------------------------------------------------
// SUBSCRIBER_ALIAS + TRANSFER
// ---------------------------------------------------------------------------

Deno.test('SUBSCRIBER_ALIAS → alias with from/to canonical keys', () => {
  const from = 'install:11111111-1111-4111-8111-111111111111';
  const to = 'ck:_abcdef1234567890abcdef1234567890ab';
  const action = resolveEventAction(event({
    type: 'SUBSCRIBER_ALIAS',
    app_user_id: to,
    original_app_user_id: from,
  }));
  assertEquals(action.kind, 'alias');
  if (action.kind === 'alias') {
    assertEquals(action.from, from);
    assertEquals(action.to, to);
  }
});

Deno.test('SUBSCRIBER_ALIAS where original == app_user_id → ignore', () => {
  const key = 'ck:_abcdef1234567890abcdef1234567890ab';
  const action = resolveEventAction(event({
    type: 'SUBSCRIBER_ALIAS',
    app_user_id: key,
    original_app_user_id: key,
  }));
  assertEquals(action.kind, 'ignore');
});

Deno.test('SUBSCRIBER_ALIAS missing original_app_user_id → ignore', () => {
  const action = resolveEventAction(event({
    type: 'SUBSCRIBER_ALIAS',
    app_user_id: 'ck:_abcdef1234567890abcdef1234567890ab',
  }));
  assertEquals(action.kind, 'ignore');
});

Deno.test('TRANSFER → transfer with from/to', () => {
  const from = 'ck:_from_record';
  const to = 'ck:_to_record';
  const action = resolveEventAction(event({
    type: 'TRANSFER',
    app_user_id: to,
    transferred_from: [from],
    transferred_to: [to],
  }));
  assertEquals(action.kind, 'transfer');
  if (action.kind === 'transfer') {
    assertEquals(action.from, from);
    assertEquals(action.to, to);
  }
});

// ---------------------------------------------------------------------------
// isEventFresh — replay-window / freshness check (SA2 defense-in-depth)
// ---------------------------------------------------------------------------

Deno.test('isEventFresh: missing event_timestamp_ms → allow (RC test events)', () => {
  assertEquals(isEventFresh({ event_timestamp_ms: undefined }), true);
});

Deno.test('isEventFresh: just-received event is fresh', () => {
  const now = 1_700_000_000_000;
  assertEquals(isEventFresh({ event_timestamp_ms: now - 1000 }, now), true);
});

Deno.test('isEventFresh: event exactly at window boundary is accepted', () => {
  const now = 1_700_000_000_000;
  // Age exactly = MAX_EVENT_AGE_MS is inclusive in `age <= MAX_EVENT_AGE_MS`.
  assertEquals(isEventFresh({ event_timestamp_ms: now - MAX_EVENT_AGE_MS }, now), true);
});

Deno.test('isEventFresh: event older than window is rejected', () => {
  const now = 1_700_000_000_000;
  assertEquals(isEventFresh({ event_timestamp_ms: now - MAX_EVENT_AGE_MS - 1 }, now), false);
});

Deno.test('isEventFresh: future timestamp within 60s tolerance is accepted (clock skew)', () => {
  const now = 1_700_000_000_000;
  assertEquals(isEventFresh({ event_timestamp_ms: now + 30_000 }, now), true);
});

Deno.test('isEventFresh: future timestamp beyond 60s tolerance is rejected (forgery)', () => {
  const now = 1_700_000_000_000;
  assertEquals(isEventFresh({ event_timestamp_ms: now + 120_000 }, now), false);
});

Deno.test('HANDLED_EVENT_TYPES covers every case in resolver switch', () => {
  const cases = [
    'INITIAL_PURCHASE',
    'RENEWAL',
    'CANCELLATION',
    'UNCANCELLATION',
    'BILLING_ISSUE',
    'EXPIRATION',
    'PRODUCT_CHANGE',
    'NON_RENEWING_PURCHASE',
    'SUBSCRIBER_ALIAS',
    'TRANSFER',
  ];
  for (const type of cases) {
    assertEquals(
      HANDLED_EVENT_TYPES.has(type),
      true,
      `${type} should be in HANDLED_EVENT_TYPES`,
    );
  }
});
