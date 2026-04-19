// TrialReminderScheduler
//
// Local notification scheduling for the 2-day-remaining trial reminder.
//
// Flow:
//   - `ensureReminder(expiresAt:)` called after `trial_started` or when
//     the coordinator observes a trial entitlement on bootstrap. Idempotent
//     — re-scheduling cancels the prior request and re-adds.
//   - `cancel()` called when trial ends (cancellation / conversion / expiry).
//   - UNUserNotificationCenter delegate (in the coordinator) catches
//     delivery and emits `trial_reminder_sent` telemetry.
//
// Authorization is requested on first `ensureReminder` call. Denial is
// treated as non-fatal — user can still convert, just without the
// reminder.
//
// Timezone / clock skew: we schedule against `expiresAt - 2 days` in the
// user's local time. If the user changes timezones mid-trial, the
// 2-day buffer absorbs it (per step-5 assumption note).

import Foundation
import UserNotifications
import OSLog

/// ID under which the trial reminder is scheduled. Singleton — one
/// reminder per user per trial. If multiple trials are started (upgrade
/// then downgrade), the latest wins.
private let kTrialReminderID = "stir.trial.reminder.2d"

@MainActor
final class TrialReminderScheduler {
    static let shared = TrialReminderScheduler()

    private let center: UNUserNotificationCenter
    private let calendar: Calendar

    init(
        center: UNUserNotificationCenter = .current(),
        calendar: Calendar = .current,
    ) {
        self.center = center
        self.calendar = calendar
    }

    /// Schedule a 2-day-before reminder against `expiresAt`. Cancels any
    /// prior reminder first. No-op if expiresAt is <=48h away (the event
    /// window has already passed) — a just-in-time user should rely on
    /// the paywall cancel UX, not a local reminder.
    func ensureReminder(expiresAt: Date, now: Date = .init()) async {
        cancel()

        let fireDate = calendar.date(byAdding: .day, value: -2, to: expiresAt) ?? expiresAt

        guard fireDate > now else {
            Logger.trialReminder.info("fireDate in the past — not scheduling")
            return
        }

        let authorized = await requestAuthorizationIfNeeded()
        guard authorized else {
            Logger.trialReminder.info("notification auth denied — skipping trial reminder")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Stir Premium trial"
        content.body = "Your Stir Premium trial ends in 2 days. Tap to manage your subscription."
        content.sound = .default
        content.userInfo = [
            "stir_notification_kind": "trial_reminder",
            "days_remaining": 2,
        ]
        content.interruptionLevel = .timeSensitive

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate,
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: kTrialReminderID,
            content: content,
            trigger: trigger,
        )

        do {
            try await center.add(request)
            Logger.trialReminder.info(
                "scheduled trial reminder fireDate=\(fireDate.ISO8601Format(), privacy: .public)",
            )
        } catch {
            Logger.trialReminder.warning(
                "trial reminder add failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }

    /// Cancel any pending trial reminder. Safe to call when none exists.
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [kTrialReminderID])
        Logger.trialReminder.debug("cancelled trial reminder (if present)")
    }

    /// Returns true if the user has authorization to schedule notifications.
    /// Requests authorization on first call; subsequent calls short-circuit
    /// to the cached status.
    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .timeSensitive])
            } catch {
                Logger.trialReminder.warning(
                    "auth request failed: \(error.localizedDescription, privacy: .public)",
                )
                return false
            }
        @unknown default:
            return false
        }
    }
}

// MARK: - Logger

extension Logger {
    static let trialReminder = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "trial_reminder",
    )
}

// MARK: - Payload parsing for telemetry

/// Inspect a delivered notification's userInfo to decide whether it was
/// our trial reminder (so the delegate can emit `trial_reminder_sent`).
enum TrialReminderNotification {
    static func daysRemaining(from userInfo: [AnyHashable: Any]) -> Int? {
        guard
            let kind = userInfo["stir_notification_kind"] as? String,
            kind == "trial_reminder"
        else { return nil }
        return userInfo["days_remaining"] as? Int
    }
}
