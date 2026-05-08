// WidgetNudgeService
//
// SCA-72 — surface a "Pin Stir to your Home Screen" nudge after the
// user has cooked 3+ times in 14 days but hasn't installed/tapped the
// widget. Spec §8 row 948.
//
// Eligibility:
//   * sessionCount(trailing 14d) >= 3
//   * lastWidgetTap == nil (user has never tapped the widget into the app)
//   * lastNudgeShown < (now - 21 days)  (max once / 21d)
//   * !permanentlyDismissed
//   * client flag `widget_nudge_enabled` = true (PostHog gate)
//
// Storage (UserDefaults):
//   * stir.widget.lastTap.v1               (Date)
//   * stir.widget_nudge.lastShown.v1       (Date)
//   * stir.widget_nudge.permanently_dismissed.v1 (Bool)
//
// Telemetry:
//   * widget_nudge_shown        — capture on visible-presentation
//   * widget_nudge_dismissed    {outcome ∈ {acted, deferred, suppressed}}
//   * widget_nudge_acted        — call when user taps "Show me how"

import Foundation
import OSLog

@MainActor
final class WidgetNudgeService {
    static let shared = WidgetNudgeService()

    private let defaults: UserDefaults
    private let telemetry: PostHogClient

    private static let lastTapKey               = "stir.widget.lastTap.v1"
    private static let lastNudgeShownKey        = "stir.widget_nudge.lastShown.v1"
    private static let permanentlyDismissedKey  = "stir.widget_nudge.permanently_dismissed.v1"

    private static let sessionWindow: TimeInterval = 14 * 86_400
    private static let sessionThreshold: Int = 3
    private static let nudgeCooldown: TimeInterval = 21 * 86_400

    init(
        defaults: UserDefaults = .standard,
        telemetry: PostHogClient = .shared,
    ) {
        self.defaults = defaults
        self.telemetry = telemetry
    }

    // MARK: - Recorders (hooked from app surfaces)

    /// Record that a widget deep-link foregrounded the app. Called from
    /// `StirDeepLinkHandler.handle` for any breadcrumbCategory starting
    /// with "widget.". The presence of this timestamp disqualifies the
    /// user from the nudge — they've already engaged with the widget.
    func recordWidgetTap(at instant: Date = .init()) {
        defaults.set(instant, forKey: Self.lastTapKey)
        Logger.widgetNudge.info("widget tap recorded at \(instant.ISO8601Format(), privacy: .public)")
    }

    var lastWidgetTap: Date? {
        defaults.object(forKey: Self.lastTapKey) as? Date
    }

    /// Mark the nudge as shown. Sets the 21-day cooldown clock.
    func markShown(at instant: Date = .init()) {
        defaults.set(instant, forKey: Self.lastNudgeShownKey)
        telemetry.capture(.widgetNudgeShown, properties: [:])
    }

    var lastNudgeShown: Date? {
        defaults.object(forKey: Self.lastNudgeShownKey) as? Date
    }

    /// Mark the nudge as permanently dismissed. User won't see it again
    /// from this surface; resetting requires an explicit settings toggle
    /// (not surfaced today).
    func markPermanentlyDismissed() {
        defaults.set(true, forKey: Self.permanentlyDismissedKey)
        telemetry.capture(.widgetNudgeDismissed, properties: [
            "outcome": "suppressed",
        ])
    }

    var isPermanentlyDismissed: Bool {
        defaults.bool(forKey: Self.permanentlyDismissedKey)
    }

    /// "Show me how" tap.
    func recordActed() {
        telemetry.capture(.widgetNudgeDismissed, properties: [
            "outcome": "acted",
        ])
    }

    /// Soft "Not now" — re-eligible after the 21d cooldown.
    func recordDeferred() {
        telemetry.capture(.widgetNudgeDismissed, properties: [
            "outcome": "deferred",
        ])
    }

    /// Test seam — wipe all keys.
    func reset() {
        defaults.removeObject(forKey: Self.lastTapKey)
        defaults.removeObject(forKey: Self.lastNudgeShownKey)
        defaults.removeObject(forKey: Self.permanentlyDismissedKey)
    }

    // MARK: - Eligibility decision

    /// Compute eligibility. Caller (Tonight Home) supplies the recent-
    /// session count to avoid coupling this service to
    /// `CookingSessionRepository`. Returns true ONLY when ALL gates
    /// pass; emit-on-show is the caller's responsibility (call
    /// `markShown()` after the visible composition is added).
    func shouldShowNudge(
        now: Date = .init(),
        sessionsInLast14Days: Int,
        flagEnabled: Bool,
    ) -> Bool {
        guard flagEnabled else { return false }
        guard !isPermanentlyDismissed else { return false }
        guard lastWidgetTap == nil else { return false }
        guard sessionsInLast14Days >= Self.sessionThreshold else { return false }
        if let lastShown = lastNudgeShown,
           now.timeIntervalSince(lastShown) < Self.nudgeCooldown {
            return false
        }
        return true
    }
}

// MARK: - Logger

extension Logger {
    static let widgetNudge = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "widget_nudge",
    )
}
