// SettingsRootViewTests
//
// Predicate-matrix coverage for the Plan & Billing surface's Pro-upsell
// placement decision (`SettingsRootView.proUpsellPlacement(tier:billingState:)`).
// Asserts the full 18-pair `(Tier × BillingState)` matrix so a regression
// in any single arm fails loud at compile/run time rather than silently
// reordering rows in the live UI.
//
// Why these matter:
//   * `(.free, .expired)` MUST resolve to `.none` — that arm gets the
//     focused Resubscribe recovery copy, not a competing Pro CTA.
//   * `(.premium, .active|.trial|.cancelledActive)` MUST resolve to
//     `.above` — Premium subscribers see Pro as the primary CTA above
//     the admin row. `.cancelledActive` was added per W7 (don't strand
//     a cancelling Premium user from the Pro upgrade path).
//   * `(.premium, .grace|.none|.expired)` MUST resolve to `.none` —
//     payment-recovery / defensive states shouldn't compete with
//     a tier-switch CTA. `.expired` is unreachable on the wire under
//     server `effectiveTier()` sanitization but listed for switch
//     exhaustiveness, so we test the mapping anyway.
//   * `.pro` always resolves to `.none` — no higher tier to upsell.

import XCTest
@testable import Stir

final class SettingsRootViewTests: XCTestCase {
    // MARK: - Free tier

    func test_proUpsellPlacement_freeNone_isBelow() {
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .free, billingState: .none),
            .below,
        )
    }

    func test_proUpsellPlacement_freeExpired_isNone() {
        // Win-back path — focused Resubscribe recovery, no competing Pro CTA.
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .free, billingState: .expired),
            .none,
        )
    }

    func test_proUpsellPlacement_freeTransientStates_areBelow() {
        // Free + non-`.none`/`.expired` billing states are transient
        // (mid-downgrade etc.). Pro discovery still appropriate.
        for state: BillingState in [.active, .trial, .grace, .cancelledActive] {
            XCTAssertEqual(
                SettingsRootView.proUpsellPlacement(tier: .free, billingState: state),
                .below,
                "tier=free billingState=\(state) should be .below",
            )
        }
    }

    // MARK: - Premium tier

    func test_proUpsellPlacement_premiumActive_isAbove() {
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .premium, billingState: .active),
            .above,
        )
    }

    func test_proUpsellPlacement_premiumTrial_isAbove() {
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .premium, billingState: .trial),
            .above,
        )
    }

    func test_proUpsellPlacement_premiumCancelledActive_isAbove() {
        // W7: don't strand a cancelling Premium user from the Pro
        // upgrade path. They get BOTH "Keep Premium" (recovery) AND
        // "Upgrade to Pro" (alternative).
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .premium, billingState: .cancelledActive),
            .above,
        )
    }

    func test_proUpsellPlacement_premiumGrace_isNone() {
        // Apple won't allow tier change while billing is failing —
        // showing "Upgrade to Pro" would lead to a confusing failure.
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .premium, billingState: .grace),
            .none,
        )
    }

    func test_proUpsellPlacement_premiumNone_isNone() {
        // Defensive — paid tier without a billing state means the
        // RevenueCat webhook hasn't propagated. Don't compound the
        // confusion with an upsell CTA.
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .premium, billingState: .none),
            .none,
        )
    }

    func test_proUpsellPlacement_premiumExpired_isNone() {
        // Unreachable on the wire (server demotes `.expired` tier →
        // `.free`). Listed for switch exhaustiveness.
        XCTAssertEqual(
            SettingsRootView.proUpsellPlacement(tier: .premium, billingState: .expired),
            .none,
        )
    }

    // MARK: - Pro tier

    func test_proUpsellPlacement_proAllStates_isNone() {
        // No higher tier — Pro never sees an upsell row. Apple handles
        // downgrade via cross-grade in the manage-subscriptions sheet.
        for state in BillingState.allCases {
            XCTAssertEqual(
                SettingsRootView.proUpsellPlacement(tier: .pro, billingState: state),
                .none,
                "tier=pro billingState=\(state) should be .none",
            )
        }
    }

    // MARK: - Exhaustiveness sentinel

    func test_proUpsellPlacement_coversFullMatrix() {
        // Sanity — if a new Tier or BillingState case is added without
        // updating proUpsellPlacement, the switch fails to compile.
        // This test additionally asserts that no (tier, state) pair
        // crashes or returns an unexpected value type.
        for tier in Tier.allCases {
            for state in BillingState.allCases {
                let placement = SettingsRootView.proUpsellPlacement(tier: tier, billingState: state)
                XCTAssertTrue(
                    [.above, .below, .none].contains(placement),
                    "tier=\(tier) billingState=\(state) returned unexpected placement \(placement)",
                )
            }
        }
    }
}
