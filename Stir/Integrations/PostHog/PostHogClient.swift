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
    private let lock = NSLock()
    private var _isInitialized = false

    private var isInitialized: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isInitialized
    }

    private init() {}

    /// Initialize the PostHog SDK. Idempotent under concurrent callers — the
    /// lock + double-check prevents two racing initializers from both
    /// getting past the guard and double-configuring the SDK.
    func initialize(apiKey: String, host: URL) {
        lock.lock()
        if _isInitialized { lock.unlock(); return }
        _isInitialized = true
        lock.unlock()

        let config = PostHogConfig(apiKey: apiKey, host: host.absoluteString)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false  // step-2 doesn't want auto screen events
        config.sessionReplay = false        // replays off until we've vetted privacy
        config.flushAt = 10
        config.flushIntervalSeconds = 30
        PostHogSDK.shared.setup(config)
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
    // Step 3 — scan + solve
    case cameraPermissionResult = "camera_permission_result"
    case scanStarted = "scan_started"
    case scanSubmitted = "scan_submitted"
    case scanParseCompleted = "scan_parse_completed"
    case ingredientCorrected = "ingredient_corrected"
    case constraintsSet = "constraints_set"
    case dinnerSolveRequested = "dinner_solve_requested"
    case dinnerSolveCompleted = "dinner_solve_completed"
    case suggestedDishSelected = "suggested_dish_selected"
    case aiRequestCompleted = "ai_request_completed"
    case aiRequestFailed = "ai_request_failed"
    // Step 4 — tap Cook Mode + substitution + outcome feedback.
    case cookModeStarted = "cook_mode_started"
    case cookStepAdvanced = "cook_step_advanced"
    case timerStarted = "timer_started"
    case substitutionRequested = "substitution_requested"
    case substitutionAccepted = "substitution_accepted"
    case cookSessionCompleted = "cook_session_completed"
    case mealRated = "meal_rated"
}
