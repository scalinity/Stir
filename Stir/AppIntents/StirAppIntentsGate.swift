// StirAppIntentsGate
//
// Premium+ entitlement gate for every AppIntent Stir exposes.
// Reads the tier cached in SharedStorage (written on every
// EntitlementService.hydrate). Intents can't dependency-inject
// EntitlementService directly (they run outside the SwiftUI
// environment); SharedStorage is the cross-process accessor
// built for exactly this — widget + intent gating.
//
// Step-7 prompt invariant:
//   Premium+ gated at intent entry — non-Premium invocation is a
//   silent no-op with PostHog `shortcut_run` event showing the
//   gate fired.
//
// v1 softens "silent" to a brief dialog ("Shortcuts are a Premium
// feature") so Siri doesn't fall back to its generic failure
// voice-over. Telemetry fires regardless so shortcut-gate
// conversion can be measured.

import AppIntents
import Foundation

enum StirAppIntentsGate {
    /// True when the cached tier entitles the user to AppIntents.
    /// Premium or Pro qualify; Free / nil fall through to the
    /// paywall dialog.
    @MainActor
    static func isPermitted() -> Bool {
        guard let tier = SharedStorage().readTier() else { return false }
        return tier == "premium" || tier == "pro"
    }

    /// Emit the `shortcut_run` telemetry event. Fires on EVERY
    /// invocation — including gated-blocked ones — so shortcut-gate
    /// conversion funnels can measure how many Free users invoke
    /// before upgrading.
    @MainActor
    static func recordInvocation(_ intentName: String) {
        PostHogClient.shared.capture(
            .shortcutRun,
            properties: StepSevenTelemetry.shortcutRun(intentName: intentName),
        )
    }

    /// Dialog returned when a non-Premium user invokes a gated intent.
    /// Shown by Siri as the voice-over fallback.
    static let upgradeDialog = IntentDialog(
        "Shortcuts are a Premium feature. Open Stir to upgrade.",
    )
}
