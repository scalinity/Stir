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

    /// Free user tapped the Cook Mode voice affordance — the highest-intent
    /// conversion moment per spec §9. Defined now; the paywall path wires
    /// in step 6 (Cook Mode voice).
    case voiceAffordanceTapped

    // MARK: - Telemetry

    /// Snake-case value sent to PostHog as `paywall_viewed.trigger`.
    /// Stable wire format; renaming these breaks existing dashboards.
    var telemetryValue: String {
        switch self {
        case .dinnerSolveQuotaExhausted:   return "dinner_solve_quota_exhausted"
        case .recipeImportQuotaExhausted:  return "recipe_import_quota_exhausted"
        case .savedFavoritesGate:          return "saved_favorites_gate"
        case .widgetsGate:                 return "widgets_gate"
        case .leftoversGate:               return "leftovers_gate"
        case .multiImageScanGate:          return "multi_image_scan_gate"
        case .settingsUpgrade:             return "settings_upgrade"
        case .voiceAffordanceTapped:       return "voice_affordance_tapped"
        }
    }

    /// Top-of-paywall copy hook. Voice trigger gets the highest-intent hero
    /// per spec §9 (step 6 polishes this).
    var headline: String {
        switch self {
        case .voiceAffordanceTapped:
            return "Cook hands-free. Try Premium free for 7 days."
        case .dinnerSolveQuotaExhausted:
            return "You're out of Dinner Solves for this month. Upgrade to keep going."
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
            return "Try Premium free for 7 days."
        }
    }

    /// Sub-headline / descriptor. Kept short; the feature list below
    /// carries the full value prop.
    var subheadline: String {
        switch self {
        case .voiceAffordanceTapped:
            return "Hands-free voice Cook Mode, 40 Dinner Solves/mo, unlimited favorites, widgets, leftovers."
        default:
            return "40 Dinner Solves/mo, voice Cook Mode (coming soon), saved favorites, widgets, leftovers."
        }
    }
}
