// AccountState
//
// iOS-side materialization of spec §10's Account state enum. Derived from
// (tier, billing_state, cloudkit_available) — never directly assigned, always
// computed. Emitted as `from_state` / `to_state` on
// `entitlement_state_changed` telemetry.
//
// CLAUDE.md + spec §15: "`from_state` / `to_state` are account-state enum
// values from spec §10 (anonymous_local, premium_active, etc.). `billing_state`
// is the six-value enum from CLAUDE.md. Do NOT emit `old_tier` / `new_tier`."

import Foundation

/// Spec §10 Account states. String raw values match the telemetry
/// property values exactly — do not rename.
enum AccountState: String, Sendable, Equatable, CaseIterable {
    case anonymousLocal      = "anonymous_local"
    case anonymousSyncedFree = "anonymous_synced_free"
    case trialPremium        = "trial_premium"
    case premiumActive       = "premium_active"
    case proActive           = "pro_active"
    case billingGrace        = "billing_grace"
    case cancelledActive     = "cancelled_active"
    case expiredFree         = "expired_free"
    case banned
}

extension AccountState {
    /// Derive the current account state from the three inputs iOS actually
    /// knows. Falls back conservatively when inputs conflict (e.g. stale
    /// tier row + expired billing state → `expiredFree`).
    static func derive(
        tier: Tier,
        billingState: BillingState,
        cloudKitAvailable: Bool,
    ) -> AccountState {
        switch (tier, billingState) {
        case (_, .grace):           return .billingGrace
        case (_, .cancelledActive): return .cancelledActive
        case (_, .expired):         return .expiredFree

        case (.premium, .trial), (.pro, .trial):
            return .trialPremium

        case (.premium, .active): return .premiumActive
        case (.pro, .active):     return .proActive

        case (.free, _):
            return cloudKitAvailable ? .anonymousSyncedFree : .anonymousLocal

        // Defensive: premium/pro with billing_state .none shouldn't happen
        // (effectiveTier maps to free server-side). Treat as free-equivalent
        // so telemetry doesn't show ghost "premium_active" users.
        case (.premium, .none), (.pro, .none):
            return cloudKitAvailable ? .anonymousSyncedFree : .anonymousLocal
        }
    }
}
