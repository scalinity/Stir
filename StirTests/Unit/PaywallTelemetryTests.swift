// PaywallTelemetryTests
//
// Snapshot-against-canonical tests for spec §15 billing event property
// names. A typo like `currency_code`, `product_id`, `old_tier`, `context`,
// etc. would silently corrupt the funnel dashboard — these assertions
// pin the keys exactly.
//
// Every builder on BillingTelemetryProperties gets its own test. Keys
// are listed verbatim; if spec §15 ever adds a property, update both
// the spec and the `expectedKeys` set here.

import XCTest
@testable import Stir

final class PaywallTelemetryTests: XCTestCase {
    // Spec §15 canonical property sets per event.
    private let canonicalKeys: [TelemetryEvent: Set<String>] = [
        .paywallViewed: ["trigger", "variant", "current_tier"],
        .trialStarted: ["sku", "trigger"],
        .trialReminderSent: ["days_remaining"],
        .purchaseStarted: ["sku", "origin"],
        .purchaseCompleted: ["sku", "price", "trial", "intro_offer"],
        .restorePurchasesTapped: ["origin"],
        .entitlementStateChanged: ["from_state", "to_state", "billing_state"],
        .favoriteSaved: ["recipe_origin"],
    ]

    // MARK: paywall_viewed

    func test_paywallViewed_keysMatchSpec_withVariant() {
        let props = BillingTelemetryProperties.paywallViewed(
            trigger: .settingsUpgrade,
            variant: "variant_a",
            currentTier: .free,
        )
        XCTAssertEqual(Set(props.keys), canonicalKeys[.paywallViewed])
        XCTAssertEqual(props["trigger"] as? String, "settings_upgrade")
        XCTAssertEqual(props["variant"] as? String, "variant_a")
        XCTAssertEqual(props["current_tier"] as? String, "free")
    }

    func test_paywallViewed_dropsVariantKey_whenNil() {
        let props = BillingTelemetryProperties.paywallViewed(
            trigger: .voiceAffordanceTapped, variant: nil, currentTier: .free,
        )
        // variant is optional in spec §15 for A/B-naive deployments;
        // the property is absent, not null, when no flag is set.
        XCTAssertFalse(props.keys.contains("variant"))
        XCTAssertEqual(props["trigger"] as? String, "voice_affordance_tapped")
        XCTAssertEqual(props["current_tier"] as? String, "free")
    }

    // MARK: trial_started

    func test_trialStarted_keysMatchSpec() {
        let props = BillingTelemetryProperties.trialStarted(
            sku: "stir.premium.annual.trial7",
            trigger: .voiceAffordanceTapped,
        )
        XCTAssertEqual(Set(props.keys), canonicalKeys[.trialStarted])
        XCTAssertEqual(props["sku"] as? String, "stir.premium.annual.trial7")
        XCTAssertEqual(props["trigger"] as? String, "voice_affordance_tapped")
    }

    // MARK: trial_reminder_sent

    func test_trialReminderSent_keysMatchSpec() {
        let props = BillingTelemetryProperties.trialReminderSent(daysRemaining: 2)
        XCTAssertEqual(Set(props.keys), canonicalKeys[.trialReminderSent])
        XCTAssertEqual(props["days_remaining"] as? Int, 2)
    }

    // MARK: purchase_started

    func test_purchaseStarted_keysMatchSpec() {
        let props = BillingTelemetryProperties.purchaseStarted(
            sku: "stir.premium.monthly",
            origin: .savedFavoritesGate,
        )
        XCTAssertEqual(Set(props.keys), canonicalKeys[.purchaseStarted])
        XCTAssertEqual(props["sku"] as? String, "stir.premium.monthly")
        XCTAssertEqual(props["origin"] as? String, "saved_favorites_gate")
    }

    // MARK: purchase_completed

    func test_purchaseCompleted_keysMatchSpec_withIntroOffer() {
        let props = BillingTelemetryProperties.purchaseCompleted(
            sku: "stir.premium.annual.trial7",
            priceDisplay: "$69.99",
            trial: true,
            introOffer: true,
        )
        XCTAssertEqual(Set(props.keys), canonicalKeys[.purchaseCompleted])
        XCTAssertEqual(props["sku"] as? String, "stir.premium.annual.trial7")
        XCTAssertEqual(props["price"] as? String, "$69.99")
        XCTAssertEqual(props["trial"] as? Bool, true)
        XCTAssertEqual(props["intro_offer"] as? Bool, true)
    }

    func test_purchaseCompleted_keysMatchSpec_noTrial() {
        let props = BillingTelemetryProperties.purchaseCompleted(
            sku: "stir.pro.monthly",
            priceDisplay: "$14.99",
            trial: false,
            introOffer: false,
        )
        XCTAssertEqual(Set(props.keys), canonicalKeys[.purchaseCompleted])
        XCTAssertEqual(props["trial"] as? Bool, false)
        XCTAssertEqual(props["intro_offer"] as? Bool, false)
    }

    // MARK: restore_purchases_tapped

    func test_restorePurchasesTapped_keysMatchSpec() {
        let props = BillingTelemetryProperties.restorePurchasesTapped(origin: .settings)
        XCTAssertEqual(Set(props.keys), canonicalKeys[.restorePurchasesTapped])
        XCTAssertEqual(props["origin"] as? String, "settings")
    }

    // MARK: entitlement_state_changed

    func test_entitlementStateChanged_keysMatchSpec() {
        let props = BillingTelemetryProperties.entitlementStateChanged(
            fromState: .anonymousSyncedFree,
            toState: .trialPremium,
            billingState: .trial,
        )
        XCTAssertEqual(Set(props.keys), canonicalKeys[.entitlementStateChanged])
        XCTAssertEqual(props["from_state"] as? String, "anonymous_synced_free")
        XCTAssertEqual(props["to_state"] as? String, "trial_premium")
        XCTAssertEqual(props["billing_state"] as? String, "trial")
    }

    // MARK: favorite_saved

    func test_favoriteSaved_keysMatchSpec() {
        let props = BillingTelemetryProperties.favoriteSaved(recipeOrigin: "ai")
        XCTAssertEqual(Set(props.keys), canonicalKeys[.favoriteSaved])
        XCTAssertEqual(props["recipe_origin"] as? String, "ai")
    }

    // MARK: trigger → telemetryValue stability

    func test_paywallTrigger_telemetryValues_areStable() {
        // Dashboards key off these exact strings — renaming breaks existing
        // funnels. If we ever need to rename, it's a coordinated change
        // with PostHog dashboard updates and spec §15.
        XCTAssertEqual(PaywallTrigger.dinnerSolveQuotaExhausted.telemetryValue, "dinner_solve_quota_exhausted")
        XCTAssertEqual(PaywallTrigger.recipeImportQuotaExhausted.telemetryValue, "recipe_import_quota_exhausted")
        XCTAssertEqual(PaywallTrigger.savedFavoritesGate.telemetryValue, "saved_favorites_gate")
        XCTAssertEqual(PaywallTrigger.widgetsGate.telemetryValue, "widgets_gate")
        XCTAssertEqual(PaywallTrigger.leftoversGate.telemetryValue, "leftovers_gate")
        XCTAssertEqual(PaywallTrigger.multiImageScanGate.telemetryValue, "multi_image_scan_gate")
        XCTAssertEqual(PaywallTrigger.settingsUpgrade.telemetryValue, "settings_upgrade")
        XCTAssertEqual(PaywallTrigger.settingsProComparison.telemetryValue, "settings_pro_comparison")
        XCTAssertEqual(PaywallTrigger.voiceAffordanceTapped.telemetryValue, "voice_affordance_tapped")
        XCTAssertEqual(PaywallTrigger.voiceCookQuotaExhausted.telemetryValue, "voice_cook_quota_exhausted")
    }

    // MARK: forbidden property names — any invented key would fail here

    func test_noInventedPropertyNames() {
        // Build every event with a realistic input set and verify no
        // invented keys leak in. Catches a regression where a future
        // PR adds `currency_code` or `product_id` on a whim.
        let forbidden: Set<String> = [
            "product_id",
            "currency_code",
            "price_local",
            "context",
            "old_tier",
            "new_tier",
            "is_trial_conversion",
            "tier",
            "plan_id",
        ]
        let allProps: [[String: Any]] = [
            BillingTelemetryProperties.paywallViewed(trigger: .savedFavoritesGate, variant: nil, currentTier: .free),
            BillingTelemetryProperties.trialStarted(sku: "x", trigger: .savedFavoritesGate),
            BillingTelemetryProperties.trialReminderSent(daysRemaining: 2),
            BillingTelemetryProperties.purchaseStarted(sku: "x", origin: .savedFavoritesGate),
            BillingTelemetryProperties.purchaseCompleted(sku: "x", priceDisplay: "$1", trial: false, introOffer: false),
            BillingTelemetryProperties.restorePurchasesTapped(origin: .settings),
            BillingTelemetryProperties.entitlementStateChanged(fromState: .anonymousLocal, toState: .premiumActive, billingState: .active),
            BillingTelemetryProperties.favoriteSaved(recipeOrigin: "ai"),
        ]
        for props in allProps {
            for key in props.keys {
                XCTAssertFalse(forbidden.contains(key), "invented key \(key) slipped into a telemetry payload")
            }
        }
    }
}
