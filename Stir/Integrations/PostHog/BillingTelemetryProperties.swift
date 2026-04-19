// BillingTelemetryProperties
//
// Typed builders for every step-5 PostHog event's property dictionary.
// CLAUDE.md + spec §15 pin the exact property names; the snapshot test in
// StirTests verifies every builder against the canonical list so a typo
// (`currency_code`, `context`, `old_tier`, ...) can't silently ship.
//
// Convention: each builder returns `[String: Any]` (PostHog's capture API
// signature). Nested values must be JSON-compatible (string, number, bool,
// array, dictionary). Dates become ISO 8601 strings.

import Foundation

enum BillingTelemetryProperties {
    // MARK: paywall_viewed

    /// Spec §15: `trigger`, `variant`, `current_tier`.
    static func paywallViewed(
        trigger: PaywallTrigger,
        variant: String?,
        currentTier: Tier,
    ) -> [String: Any] {
        var props: [String: Any] = [
            "trigger": trigger.telemetryValue,
            "current_tier": currentTier.rawValue,
        ]
        if let variant = variant {
            props["variant"] = variant
        }
        return props
    }

    // MARK: trial_started

    /// Spec §15: `sku`, `trigger`.
    static func trialStarted(sku: String, trigger: PaywallTrigger) -> [String: Any] {
        [
            "sku": sku,
            "trigger": trigger.telemetryValue,
        ]
    }

    // MARK: trial_reminder_sent

    /// Spec §15: `days_remaining`.
    static func trialReminderSent(daysRemaining: Int) -> [String: Any] {
        [
            "days_remaining": daysRemaining,
        ]
    }

    // MARK: purchase_started

    /// Spec §15: `sku`, `origin`. `origin` is the paywall trigger at the
    /// moment the user tapped Subscribe — useful for funnel analysis.
    static func purchaseStarted(sku: String, origin: PaywallTrigger) -> [String: Any] {
        [
            "sku": sku,
            "origin": origin.telemetryValue,
        ]
    }

    // MARK: purchase_completed

    /// Spec §15: `sku`, `price`, `trial`, `intro_offer`. `price` is the
    /// localized display string from StoreKit; analytics is tier-comparison
    /// oriented, not for revenue math (RC dashboard is source of revenue).
    static func purchaseCompleted(
        sku: String,
        priceDisplay: String,
        trial: Bool,
        introOffer: Bool,
    ) -> [String: Any] {
        [
            "sku": sku,
            "price": priceDisplay,
            "trial": trial,
            "intro_offer": introOffer,
        ]
    }

    // MARK: restore_purchases_tapped

    /// Spec §15: `origin`. Where in the UI the user tapped Restore
    /// (settings vs paywall).
    static func restorePurchasesTapped(origin: RestoreOrigin) -> [String: Any] {
        [
            "origin": origin.rawValue,
        ]
    }

    // MARK: entitlement_state_changed

    /// Spec §15: `from_state`, `to_state`, `billing_state`.
    ///
    /// `from_state`/`to_state` come from spec §10's account-state enum
    /// (`anonymous_local`, `premium_active`, etc.) — derived from
    /// (tier, billing_state, cloudkit_available) on iOS. `billing_state`
    /// is the six-value backend enum (none/active/trial/grace/...).
    static func entitlementStateChanged(
        fromState: AccountState,
        toState: AccountState,
        billingState: BillingState,
    ) -> [String: Any] {
        [
            "from_state": fromState.rawValue,
            "to_state": toState.rawValue,
            "billing_state": billingState.rawValue,
        ]
    }

    // MARK: favorite_saved

    /// Spec §15: `recipe_origin`. From RecipePlan.origin (scan | import | saved).
    static func favoriteSaved(recipeOrigin: String) -> [String: Any] {
        [
            "recipe_origin": recipeOrigin,
        ]
    }
}

/// Where a Restore Purchases tap originated. Captured as the `origin`
/// property on `restore_purchases_tapped`. Matches spec §15 requirement
/// of having a defined set.
enum RestoreOrigin: String, Sendable {
    case settings
    case paywall
    /// Reserved for future Account Deletion flow (step 8+).
    case accountRecovery = "account_recovery"
}
