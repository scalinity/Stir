// AccountStateTests
//
// Verifies the (tier, billing_state, cloudkit) → AccountState derivation
// table in `AccountState.derive`. This enum is what iOS emits as the
// `from_state` / `to_state` property on `entitlement_state_changed` per
// spec §15, so drift here is telemetry drift.

import XCTest
@testable import Stir

final class AccountStateTests: XCTestCase {
    func test_free_noneBilling_localOnly() {
        let state = AccountState.derive(
            tier: .free, billingState: .none, cloudKitAvailable: false,
        )
        XCTAssertEqual(state, .anonymousLocal)
    }

    func test_free_noneBilling_syncedCloudKit() {
        let state = AccountState.derive(
            tier: .free, billingState: .none, cloudKitAvailable: true,
        )
        XCTAssertEqual(state, .anonymousSyncedFree)
    }

    func test_premium_trial_isTrialPremium() {
        let state = AccountState.derive(
            tier: .premium, billingState: .trial, cloudKitAvailable: true,
        )
        XCTAssertEqual(state, .trialPremium)
    }

    func test_premium_active_isPremiumActive() {
        let state = AccountState.derive(
            tier: .premium, billingState: .active, cloudKitAvailable: true,
        )
        XCTAssertEqual(state, .premiumActive)
    }

    func test_pro_active_isProActive() {
        let state = AccountState.derive(
            tier: .pro, billingState: .active, cloudKitAvailable: true,
        )
        XCTAssertEqual(state, .proActive)
    }

    func test_pro_trial_still_mapsToTrialPremium() {
        // Per spec: trials only exist on Premium annual. If RC ever
        // produces a Pro+trial combo (shouldn't), still route to trialPremium.
        let state = AccountState.derive(
            tier: .pro, billingState: .trial, cloudKitAvailable: true,
        )
        XCTAssertEqual(state, .trialPremium)
    }

    func test_anyTier_grace_isBillingGrace() {
        for tier in [Tier.premium, Tier.pro] {
            let state = AccountState.derive(
                tier: tier, billingState: .grace, cloudKitAvailable: true,
            )
            XCTAssertEqual(state, .billingGrace, "tier=\(tier.rawValue) in grace")
        }
    }

    func test_anyTier_cancelledActive_isCancelledActive() {
        for tier in [Tier.premium, Tier.pro] {
            let state = AccountState.derive(
                tier: tier, billingState: .cancelledActive, cloudKitAvailable: true,
            )
            XCTAssertEqual(state, .cancelledActive, "tier=\(tier.rawValue) cancelled_active")
        }
    }

    func test_anyTier_expired_isExpiredFree() {
        // Critical invariant: expired ALWAYS demotes to expired_free regardless
        // of what RC remembers as tier. Server's effectiveTier() enforces the
        // same mapping. Telemetry on the client must match.
        for tier in Tier.allCases {
            let state = AccountState.derive(
                tier: tier, billingState: .expired, cloudKitAvailable: true,
            )
            XCTAssertEqual(state, .expiredFree, "tier=\(tier.rawValue) expired")
        }
    }

    func test_premium_none_mapsToFree_defensively() {
        // Defensive — shouldn't occur in practice (RC webhook leaves tier
        // at free when billing_state becomes none). If it does, don't
        // ghost-promote the user.
        let state = AccountState.derive(
            tier: .premium, billingState: .none, cloudKitAvailable: true,
        )
        XCTAssertEqual(state, .anonymousSyncedFree)
    }

    func test_allCasesDerivableFromKnownInputs() {
        // Lightweight coverage: every AccountState.allCases should be
        // producible from SOME (tier, billing_state, cloudkit) triple.
        // `banned` is admin-action-only and can't be derived from entitlements
        // — iOS would need a dedicated "banned" entitlement bit from backend.
        // We don't model it in the derive function; handle here by skipping.
        var reachable: Set<AccountState> = []
        for tier in Tier.allCases {
            for bs in BillingState.allCases {
                for ck in [true, false] {
                    reachable.insert(AccountState.derive(
                        tier: tier, billingState: bs, cloudKitAvailable: ck,
                    ))
                }
            }
        }
        // Every case except .banned should be reachable via derive().
        let expected = Set(AccountState.allCases).subtracting([.banned])
        XCTAssertEqual(reachable, expected)
    }
}
