// StirAppIntentsGate
//
// Premium+ entitlement gate for every AppIntent Stir exposes.
//
// This is a SNAPPY UX HINT, not authoritative enforcement.
//
// Enforcement happens at three layers:
//   1. Here (soft gate on cached tier) — avoids the perceived latency
//      of a network round-trip per Siri invocation. Reads cross-process
//      via SharedStorage, which the main app writes on every bootstrap.
//   2. Main app auto-refresh — every Stir AppIntent sets
//      `openAppWhenRun = true`, so invocation foregrounds the main app,
//      which runs `refreshEntitlementsOnForeground()` on .active (see
//      RootView.onChange(of: scenePhase)). A modified main app that
//      wrote "premium" to SharedStorage without a real purchase gets
//      its forgery overwritten here on the next foreground (SA2-9).
//   3. Backend entitlement check — every /v1/ai/* Edge Function reads
//      entitlement_snapshots via readEntitlement() and 403s
//      Free callers with the appropriate ENT-* error code. That is
//      the authoritative barrier against any forged client-side gate.
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
    ///
    /// `storage` is injectable so tests can assert the real function
    /// with a controlled UserDefaults suite — prevents the
    /// test-a-replica-not-production hazard CR3-11 flagged.
    @MainActor
    static func isPermitted(storage: SharedStorage = SharedStorage()) -> Bool {
        guard let raw = storage.readTier(),
              let tier = SharedTier(rawValue: raw) else { return false }
        return tier.isPaid
    }

    /// Emit the `shortcut_run` telemetry event. Fires on EVERY
    /// invocation — including gated-blocked ones — so shortcut-gate
    /// conversion funnels can measure how many Free users invoke
    /// before upgrading.
    ///
    /// `analytics` injectable for SpyPostHog-pattern test coverage.
    @MainActor
    static func recordInvocation(
        _ intentName: String,
        analytics: PostHogClient = .shared,
    ) {
        analytics.capture(
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
