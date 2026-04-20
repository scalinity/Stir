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

/// Non-final + `open capture(...)` so tests can subclass with a spy.
/// The singleton is the only caller outside tests, so the virtual
/// dispatch cost is irrelevant in production.
class PostHogClient: @unchecked Sendable {
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

    #if DEBUG
    /// Protected init so tests can subclass with an override of
    /// `capture(...)`. DEBUG-only so production builds can't
    /// accidentally construct an uninitialized instance and bypass
    /// the singleton.
    init(testingOnly: Bool) {}
    #endif
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
    // Step 5 — billing + paywall.
    case paywallViewed = "paywall_viewed"
    case trialStarted = "trial_started"
    case trialReminderSent = "trial_reminder_sent"
    case purchaseStarted = "purchase_started"
    case purchaseCompleted = "purchase_completed"
    case restorePurchasesTapped = "restore_purchases_tapped"
    case favoriteSaved = "favorite_saved"
    // Defined now so step 6 wiring doesn't re-register the enum case.
    // No invocation path in step 5.
    case voiceAffordanceTapped = "voice_affordance_tapped"
    // Step 6 C.4 — voice cook-turn events. Spec §15 verbatim.
    case cookTurnSubmitted = "cook_turn_submitted"
    case cookTurnResolved = "cook_turn_resolved"
    // Reserved for step 8 (reactivation campaigns). CLAUDE.md canonical.
    case reactivationNotificationOpened = "reactivation_notification_opened"
    // Step 7 — import + grocery + widgets/shortcuts. Property names below
    // are spec §15 canonical (destination NOT export_target; parse_quality
    // NOT confidence; edit_required NOT needed_edits). No `widget_tapped`
    // — a widget deep-link tap fires `app_opened` with the URL param.
    case recipeImportStarted = "recipe_import_started"
    case recipeImportCompleted = "recipe_import_completed"
    case widgetAdded = "widget_added"
    case shortcutRun = "shortcut_run"
    case groceryListExported = "grocery_list_exported"
}

/// Typed property-bag helpers for step-7 events. Keeping properties
/// off a loose [String: Any] dict at call sites prevents the
/// `export_target` / `confidence` / `needed_edits` drift that the
/// telemetry snapshot test watches for.
public enum StepSevenTelemetry {
    /// `recipe_import_started` — one event per user-initiated import.
    /// Properties: source_type (spec §15).
    public static func recipeImportStarted(source: RecipeImportSource) -> [String: Any] {
        ["source_type": source.rawValue]
    }

    /// `recipe_import_completed` — fires on final Import Review
    /// acceptance OR on user cancellation OR on AI failure.
    /// Properties: source_type, parse_quality, edit_required (spec §15).
    public static func recipeImportCompleted(
        source: RecipeImportSource,
        parseQuality: String,
        editRequired: Bool,
    ) -> [String: Any] {
        [
            "source_type": source.rawValue,
            "parse_quality": parseQuality,
            "edit_required": editRequired,
        ]
    }

    /// `widget_added` — fired when `WidgetCenter.shared.reloadAllTimelines()`
    /// observes a new widget configuration. Properties: source (spec §15).
    public static func widgetAdded(source: String) -> [String: Any] {
        ["source": source]
    }

    /// `shortcut_run` — AppIntent invocation. Fires on BOTH successful
    /// runs and entitlement-gated no-ops (gate shows up as `intent_name`
    /// + separate entitlement_state_changed). Properties: intent_name.
    public static func shortcutRun(intentName: String) -> [String: Any] {
        ["intent_name": intentName]
    }

    /// `grocery_list_exported` — post-EventKit export success. Also fired
    /// with `destination: "in_app"` when Reminders was denied and the
    /// list stayed in Stir. Properties: item_count, destination.
    public static func groceryListExported(itemCount: Int, destination: Destination) -> [String: Any] {
        [
            "item_count": itemCount,
            "destination": destination.rawValue,
        ]
    }

    /// Destination values match spec §15 verbatim. DO NOT add new values
    /// without updating spec + CLAUDE.md + the snapshot test.
    public enum Destination: String, Sendable, CaseIterable {
        case reminders
        case inApp = "in_app"
    }

    /// `reactivation_notification_opened` — local-notification deep link.
    /// Properties: trigger_kind. Values restricted to spec §8 triggers.
    public static func reactivationNotificationOpened(triggerKind: String) -> [String: Any] {
        ["trigger_kind": triggerKind]
    }
}
