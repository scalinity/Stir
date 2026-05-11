// ReactivationScheduler
//
// Local notification scheduling for the step-7 7-day reactivation
// reminder. Fires if the user hasn't cooked in a week, with body
// "Cook something tonight?" and a deep link to Tonight Home.
//
// Contract:
//   - `scheduleAfterCook(now:)` called on CookingSession.markCompleted.
//     Idempotent — re-scheduling cancels the prior request first.
//   - `cancel()` called on app open (RootCoordinator foreground hook).
//     Ensures the user never receives a reminder while actively using
//     the app.
//   - Gated by `NotificationPreferencesStore.reactivation`. User can
//     disable the whole reactivation flow in Settings.
//
// Telemetry: on delivery tap, `reactivation_notification_opened` with
// `trigger_kind="cook_reminder"` per spec §15. The delivery handler
// lives in the existing StirNotificationDelegate (registered at
// StirApp init) alongside the trial-reminder emitter.

import Foundation
import UserNotifications
import OSLog

private let reactivationReminderID = "stir.reactivation.cook.7d"

@MainActor
final class ReactivationScheduler {
    static let shared = ReactivationScheduler()

    private let center: any UserNotificationCenterClient
    private let calendar: Calendar
    private let preferences: NotificationPreferencesStore
    private let telemetry: PostHogClient

    init(
        center: any UserNotificationCenterClient = UNUserNotificationCenter.current(),
        calendar: Calendar = .current,
        preferences: NotificationPreferencesStore = .shared,
        telemetry: PostHogClient = .shared,
    ) {
        self.center = center
        self.calendar = calendar
        self.preferences = preferences
        self.telemetry = telemetry
    }

    /// Schedule the 7-day reminder against `now + 7 days`. No-op when
    /// the user has opted out in Settings. Idempotent — re-scheduling
    /// after a second cook-in-the-same-week resets the 7-day clock.
    ///
    /// SCA-318: routes through `NotificationSchedulerKit.addWithRollback`
    /// for the dual-failure observability that SCA-309 added for
    /// leftovers/use-soon. When primary `add` AND rollback re-add both
    /// throw, this scheduler now emits
    /// `notification_schedule_rollback_failed` with
    /// `scheduler_id="reactivation"` instead of the prior silent
    /// rollback.
    func scheduleAfterCook(now: Date = .init()) async {
        guard preferences.preferences.reactivation else {
            Logger.reactivation.info("reactivation disabled in prefs — skipping schedule")
            return
        }
        let fireDate = calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 86_400)

        let authorized = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: .reactivation,
        )
        guard authorized else {
            Logger.reactivation.info("notification auth denied — skipping reactivation reminder")
            return
        }

        let prior = await NotificationSchedulerKit.pendingRequest(
            identifier: reactivationReminderID,
            center: center,
        )
        cancel()

        let content = UNMutableNotificationContent()
        content.title = "Cook something tonight?"
        content.body = "Haven't opened Stir in a week. Point it at your fridge — we'll figure out dinner."
        content.sound = .default
        content.userInfo = [
            "stir_notification_kind": "reactivation",
            "trigger_kind": "cook_reminder",
        ]
        content.interruptionLevel = .active

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate,
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: reactivationReminderID,
            content: content,
            trigger: trigger,
        )

        let added = await NotificationSchedulerKit.addWithRollback(
            request,
            prior: prior,
            center: center,
            logger: .reactivation,
            contextLabel: "reactivation reminder",
            schedulerId: "reactivation",
            onRollbackFailure: { [telemetry] schedulerId, identifier, errorDescription in
                telemetry.capture(.notificationScheduleRollbackFailed, properties: [
                    "scheduler_id": schedulerId,
                    "identifier": identifier,
                    "error_description": errorDescription,
                ])
            },
        )
        if added {
            Logger.reactivation.info(
                "scheduled reactivation reminder fireDate=\(fireDate.ISO8601Format(), privacy: .public)",
            )
        }
    }

    /// Cancel any pending reactivation reminder. Called on app open so
    /// active users never receive the "haven't opened Stir" message.
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [reactivationReminderID])
    }
}

// MARK: - Payload parsing for telemetry

/// Inspect a delivered notification's userInfo to decide whether it was
/// the reactivation reminder (so the delegate can emit
/// `reactivation_notification_opened` with trigger_kind=cook_reminder).
enum ReactivationNotification {
    static func triggerKind(from userInfo: [AnyHashable: Any]) -> String? {
        guard
            let kind = userInfo["stir_notification_kind"] as? String,
            kind == "reactivation"
        else { return nil }
        return userInfo["trigger_kind"] as? String
    }
}

// MARK: - Logger

extension Logger {
    static let reactivation = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "reactivation",
    )
}
