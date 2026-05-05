// PaywallTrigger
//
// The context that caused the paywall to appear. iOS-internal enum; when
// emitted to PostHog via `paywall_viewed.trigger`, we use the snake_case
// `telemetryValue` to match spec §15 + downstream dashboard filters.
//
// Adding a case requires three updates:
//   1. Here (add the case + telemetryValue).
//   2. `PaywallDisplay.headline` (if the paywall copy differs per trigger).
//   3. Backend funnel: no server config needed; PostHog reads the property
//      directly.

import Foundation

enum PaywallTrigger: String, Sendable, CaseIterable, Equatable, Identifiable {
    /// Stable identifier used by `.fullScreenCover(item:)` in RootView.
    var id: String { rawValue }

    /// Free user ran out of Dinner Solves for the month.
    case dinnerSolveQuotaExhausted

    /// User hit their tier's remembered-pantry-items cap (Free: 25,
    /// Premium: 250, Pro: 1000). Surfaced from the Pantry Management
    /// list when a Free or Premium user attempts to add a 26th / 251st
    /// remembered item.
    case pantryCapReached

    /// Free user ran out of Recipe Imports for the month.
    /// (UI path lands in step 7; enum exists now for backend gate.)
    case recipeImportQuotaExhausted

    /// Free user tapped the favorite toggle on a recipe.
    case savedFavoritesGate

    /// Free user tapped into the Widgets setup flow (step 7 UI).
    case widgetsGate

    /// Free user tapped Leftovers (step 7 UI).
    case leftoversGate

    /// Non-Pro user attempted a multi-image scan (step 7 UI).
    case multiImageScanGate

    /// User tapped "Upgrade" from Settings > Plan & Billing.
    case settingsUpgrade

    /// User opened the Premium-vs-Pro comparison sheet directly from
    /// Settings > Plan & Billing — distinct from `.settingsUpgrade`
    /// (which routes to the full Premium-CTA paywall). Two entry points
    /// share this trigger:
    ///   * Free user tapped "See Pro features" (discovery)
    ///   * Premium subscriber tapped "Upgrade to Pro" (cross-tier upgrade)
    /// `current_tier` on `paywall_viewed` discriminates the two. Kept
    /// distinct from `.settingsUpgrade` so PostHog dashboards filtering
    /// on `trigger=settings_upgrade` aren't polluted by comparison-sheet
    /// impressions (which never lead to a Premium trial — only to Pro
    /// purchase or dismiss).
    case settingsProComparison

    /// Free user tapped the Cook Mode voice affordance — the highest-intent
    /// conversion moment per spec §9. Defined now; the paywall path wires
    /// in step 6 (Cook Mode voice).
    case voiceAffordanceTapped

    /// Premium user ran out of monthly voice Cook Sessions. Routes to
    /// the Pro-upsell variant of the paywall (more voice sessions, multi-
    /// image scan, priority inference queue).
    case voiceCookQuotaExhausted

    // MARK: - Telemetry

    /// Snake-case value sent to PostHog as `paywall_viewed.trigger`.
    /// Stable wire format; renaming these breaks existing dashboards.
    var telemetryValue: String {
        switch self {
        case .dinnerSolveQuotaExhausted:   return "dinner_solve_quota_exhausted"
        case .pantryCapReached:            return "pantry_cap_reached"
        case .recipeImportQuotaExhausted:  return "recipe_import_quota_exhausted"
        case .savedFavoritesGate:          return "saved_favorites_gate"
        case .widgetsGate:                 return "widgets_gate"
        case .leftoversGate:               return "leftovers_gate"
        case .multiImageScanGate:          return "multi_image_scan_gate"
        case .settingsUpgrade:             return "settings_upgrade"
        case .settingsProComparison:       return "settings_pro_comparison"
        case .voiceAffordanceTapped:       return "voice_affordance_tapped"
        case .voiceCookQuotaExhausted:     return "voice_cook_quota_exhausted"
        }
    }

    /// Top-of-paywall copy hook. Voice trigger gets the highest-intent hero
    /// per spec §9 (step 6 polishes this).
    var headline: String {
        switch self {
        case .voiceAffordanceTapped:
            // ADR 0015 copy spec: hero carries the benefit verb ("Cook
            // hands-free with voice") + trial CTA. Cap numbers live in
            // the subheadline / feature list below, never the hero.
            return "Cook hands-free with voice. Start Premium free for 7 days."
        case .voiceCookQuotaExhausted:
            return "You've used this month's voice Cook Sessions. Upgrade to Pro for more."
        case .dinnerSolveQuotaExhausted:
            return "You're out of Dinner Solves for this month. Upgrade to keep going."
        case .pantryCapReached:
            return "Need more pantry space?"
        case .recipeImportQuotaExhausted:
            return "You've used your import quota. Upgrade for unlimited imports."
        case .savedFavoritesGate:
            return "Save your weeknight wins. Premium unlocks unlimited favorites."
        case .widgetsGate:
            return "Widgets for one-tap dinner. Upgrade to Premium."
        case .leftoversGate:
            return "Turn leftovers into next dinner. Upgrade to Premium."
        case .multiImageScanGate:
            return "Scan your whole kitchen at once. Upgrade to Pro."
        case .settingsUpgrade:
            // Hero aligns with the Pro-flavored subheadline below
            // (ADR 0015 paywall copy spec classified settingsUpgrade
            // as a generic Pro-upsell row). Previous "Try Premium
            // free for 7 days." produced Premium-hero + Pro-feature-
            // list dissonance on the same surface.
            return "Upgrade for every-dinner voice and multi-image scan."
        case .settingsProComparison:
            // Surface uses ProComparisonSheet's own header ("Premium or
            // Pro?"); this string is unread on that path and exists
            // only so the enum stays exhaustive. Kept Pro-flavored for
            // any future PaywallView-routed reuse.
            return "Premium or Pro? Compare your options."
        }
    }

    /// Sub-headline / descriptor. Kept short; the feature list below
    /// carries the full value prop.
    ///
    /// Exhaustive (no `default`) so the compiler forces an update when a
    /// new trigger is added. A `default` arm would silently misrepresent
    /// the value prop on a new trigger and produce "copy says X, cap
    /// enforces Y" refund-request bugs.
    ///
    /// **Copy philosophy (ADR 0015):** frequency framing, never raw
    /// session counts. "~3 dinners a week" on Premium and "every dinner"
    /// on Pro read as benefit statements; "13 voice Cook Sessions / mo"
    /// and "27 voice Cook Sessions / mo" read as rationing. Both the
    /// paywall surfaces (this file + PaywallView.featuresList) and the
    /// ProComparisonSheet use frequency framing for the voice row;
    /// enforcement numbers (13 / 27) live only in
    /// `_shared/entitlements.ts`. If those numbers change, update the
    /// frequency phrases here and in ProComparisonSheet in the same
    /// commit — the phrases must stay truthful to the enforced caps.
    var subheadline: String {
        // Premium value prop — voice leads, then cadence, then surface
        // features. Frequency-framed so it ages well if the cap changes
        // later (ADR 0015 trigger-to-revisit).
        let premiumValueProp = "Hands-free voice for ~3 dinners a week, 40 Dinner Solves/mo, unlimited favorites, widgets, leftovers."
        // Pro value prop — voice "every dinner" is the anchoring benefit;
        // exact cap (27) stays out of prose. 120 Dinner Solves acts as
        // a second anchor so the subhead works for non-voice Pro triggers.
        let proValueProp = "Voice cooking for every dinner, 120 Dinner Solves/mo, multi-image scan, priority inference, 1,000 pantry items."
        switch self {
        case .voiceAffordanceTapped:
            // Free→Premium hero trigger — lead with the benefit verb,
            // not the cap. ADR 0015 paywall copy table, row 1.
            return "Cook hands-free with your voice, 40 Dinner Solves/mo, unlimited favorites, widgets, leftovers."
        case .voiceCookQuotaExhausted:
            // Premium user hit monthly voice cap → Pro upsell. Voice is
            // THE reason they'd upgrade; "every dinner" removes the
            // rationing frame without citing 27.
            return proValueProp
        case .multiImageScanGate:
            // Premium user tried Pro-only multi-image scan. Voice still
            // leads because it's the durable differentiator, with
            // multi-image called out as the surface feature that
            // triggered the paywall. ADR 0015 paywall copy table, row 3.
            return "Voice for every dinner + multi-image scan, 120 Dinner Solves/mo, priority inference, 1,000 pantry items."
        case .settingsUpgrade:
            // Generic upgrade from Settings. Classified as Pro-upsell
            // per ADR 0015 paywall copy table, row 2 — the surface
            // needs a strong voice anchor because it's context-free
            // (unlike feature-gated triggers which have their own lead).
            return proValueProp
        case .settingsProComparison:
            // Same Pro-anchoring as `.settingsUpgrade`. Unread on the
            // ProComparisonSheet path (sheet has its own static prose).
            return proValueProp
        case .pantryCapReached:
            // Pantry cap is per-tier (Free 25 / Premium 250 / Pro 1000),
            // so the subhead names both Premium and Pro counts to keep
            // the upgrade choice legible. Frequency framing doesn't fit
            // a "remembered ingredients" cap — exact counts read as
            // capability, not rationing.
            return "Premium remembers up to 250 ingredients. Pro remembers 1000."
        case .dinnerSolveQuotaExhausted,
             .recipeImportQuotaExhausted,
             .savedFavoritesGate,
             .widgetsGate,
             .leftoversGate:
            return premiumValueProp
        }
    }
}
