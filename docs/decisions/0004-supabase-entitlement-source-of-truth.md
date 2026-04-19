# ADR 0004: Supabase entitlement_snapshots is source of truth; RC is a refresh trigger only

- **Status**: Accepted
- **Date**: 2026-04-19
- **Owner-step**: Step 5 (billing + paywall) — standing
- **Related**: CLAUDE.md §Billing model, `Stir/Core/Services/EntitlementService.swift`, `Stir/Integrations/RevenueCat/RevenueCatService.swift`

## Context

iOS has two potential readers of entitlement state: RevenueCat's `Purchases.shared.customerInfo` (updated live via the SDK's `customerInfoStream`), and Supabase's `/v1/config/bootstrap` response (updated via the webhook → DB pipeline). Both carry subscription status; both can be stale at different times. Picking one as authoritative is a design choice with churn implications.

## Decision

**Supabase `entitlement_snapshots` is the single source of truth for iOS.** `EntitlementService.canAccess(_)` reads only from Supabase-hydrated state. RC's `customerInfoStream` is observed, but the observer's only action is to trigger `configBootstrap()`, which pulls fresh state from Supabase. iOS never feature-gates on RC's view directly.

## Alternatives considered

- **RC as source of truth** — rejected: bypasses our billing invariants (tier demotion on `expired`, grace-banner logic, quota caps snapshot-at-creation per CLAUDE.md). RC doesn't know about Stir-specific rules. Also, RC's SDK cache can lag cross-device changes.
- **Dual-read with consistency check** — rejected: two readers means two stale conditions. When they disagree (they will), which wins? Adds branching logic in every feature gate.
- **Server-computed state in every iOS request** — rejected: latency cost on every tap. `configBootstrap` + 24h Keychain snapshot gives us the same guarantees at lower cost.

## Consequences

### Positive

- One place to enforce billing rules (`effectiveTier`, `effectiveVoiceEnabled`, `billing_retry_banner`, quota caps).
- Predictable behavior: iOS shows what Supabase said, and Supabase reflects what RC's webhook told it. Cross-device consistency comes free because both devices read the same Supabase state.
- 24h Keychain snapshot on iOS gives an offline fallback without inventing custom sync logic.

### Negative

- Webhook delivery delay is the user-perceptible lag on purchases. If RC takes 10s to deliver, iOS is stale for 10s. Mitigated by `configBootstrap` refresh on scenePhase `.active` and on `customerInfoStream` emissions.
- Two systems to keep in sync. Requires the RC→Supabase pipeline to be correct (ADR 0005: alias-forward promote).

### Tradeoffs

- Accept a small latency window on purchase → entitlement visibility in exchange for a single consistent authoritative read path.

## Notes

- CLAUDE.md §"What NOT to do by default": "Don't derive `voice_enabled` on iOS. It's server-computed in the bootstrap response." Codifies this ADR.
- Tests for this invariant: `EntitlementServiceTests.test_expiredBillingState_treatsUserAsFree` and the decision-matrix coverage ensure iOS gates match server rules.
