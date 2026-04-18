// PostHogClient
//
// Thin singleton wrapper around `PostHogSDK.shared`. Matches the step-2
// prompt's telemetry contract:
//   - Initialize at launch
//   - identify(distinctID:) after canonical key resolves (distinctID = hash)
//   - capture("app_opened", …) on cold start
//   - capture("onboarding_started" / "onboarding_completed" / "app_backgrounded")
//
// CLAUDE.md §"Telemetry events" is the canonical allow-list. Inventing new
// event names in code without updating spec §15 + CLAUDE.md is banned.

import Foundation
import OSLog
import PostHog

final class PostHogClient: @unchecked Sendable {
    static let shared = PostHogClient()
    private var isInitialized = false

    private init() {}

    /// Initialize the PostHog SDK. Idempotent.
    func initialize(apiKey: String, host: URL) {
        guard !isInitialized else { return }
        let config = PostHogConfig(apiKey: apiKey, host: host.absoluteString)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false  // step-2 doesn't want auto screen events
        config.sessionReplay = false        // replays off until we've vetted privacy
        config.flushAt = 10
        config.flushIntervalSeconds = 30
        PostHogSDK.shared.setup(config)
        isInitialized = true
        Logger.telemetry.info("posthog initialized (host=\(host.host ?? "?", privacy: .public))")
    }

    /// Bind the session to a distinct ID (the canonical_user_key_hash).
    func identify(distinctID: String) {
        guard isInitialized else { return }
        PostHogSDK.shared.identify(distinctID)
    }

    /// Emit a typed event. Properties are Sendable JSON-compatible values.
    func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        guard isInitialized else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }
}

/// Canonical event name allow-list. Adding one requires updating both
/// CLAUDE.md §"Telemetry events" and spec §15.
enum TelemetryEvent: String, Sendable, CaseIterable {
    case appOpened = "app_opened"
    case appBackgrounded = "app_backgrounded"
    case onboardingStarted = "onboarding_started"
    case onboardingCompleted = "onboarding_completed"
    case screenErrorShown = "screen_error_shown"
    case syncStateChanged = "sync_state_changed"
    case entitlementStateChanged = "entitlement_state_changed"
}
