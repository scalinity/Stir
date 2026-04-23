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
private let trialReminderID = "stir.trial.reminder.2d"

@MainActor
final class TrialReminderScheduler {
    static let shared = TrialReminderScheduler()

    private let center: any UserNotificationCenterClient
    private let calendar: Calendar

    init(
        center: any UserNotificationCenterClient = UNUserNotificationCenter.current(),
        calendar: Calendar = .current,
    ) {
        self.center = center
        self.calendar = calendar
    }

    /// Schedule a 2-day-before reminder against `expiresAt`. No-op if
    /// expiresAt is <=48h away — a just-in-time user should rely on the
    /// paywall cancel UX, not a local reminder.
    ///
    /// IMPORTANT: guard checks run BEFORE `cancel()`. Earlier version
    /// cancelled first unconditionally, which meant a bootstrap-driven
    /// re-schedule with a past-dated `expiresAt` (e.g. during the final
    /// 48h) would eat the user's previously-valid reminder. Review fix:
    /// validate first, cancel only if we're going to reschedule.
    func ensureReminder(expiresAt: Date, now: Date = .init()) async {
        let fireDate = calendar.date(byAdding: .day, value: -2, to: expiresAt) ?? expiresAt

        guard fireDate > now else {
            Logger.trialReminder.info("fireDate in the past — not scheduling; preserving existing reminder if any")
            return
        }

        let authorized = await requestAuthorizationIfNeeded()
        guard authorized else {
            Logger.trialReminder.info("notification auth denied — skipping trial reminder")
            return
        }

        // Snapshot any existing pending reminder BEFORE cancelling so a
        // failed `center.add(...)` below can roll back to the prior state
        // instead of leaving the user with no reminder at all
        // (pattern `notification_schedule_no_rollback`).
        let prior = await pendingReminder()

        // Only now that we know we can + will schedule a fresh reminder
        // do we clear the prior pending one.
        cancel()

        let content = UNMutableNotificationContent()
        content.title = "Stir Premium trial"
        content.body = "Your Stir Premium trial ends in 2 days. Tap to manage your subscription."
        content.sound = .default
        content.userInfo = [
            "stir_notification_kind": "trial_reminder",
            "days_remaining": 2,
        ]
        content.interruptionLevel = .active

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate,
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(
            identifier: trialReminderID,
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
                "trial reminder add failed: \(error.localizedDescription, privacy: .public) — rolling back",
            )
            // Rollback: re-add the snapshot we cancelled. Best-effort —
            // if re-add also fails, we're no worse off than after the
            // initial `cancel()` call. Skipping this rollback path was the
            // latent `notification_schedule_no_rollback` bug flagged in
            // CA2 audit: a transient UN failure would silently destroy the
            // user's previously-scheduled 2-day reminder.
            if let prior {
                do {
                    try await center.add(prior)
                    Logger.trialReminder.info("trial reminder rollback restored prior request")
                } catch {
                    Logger.trialReminder.warning(
                        "trial reminder rollback failed: \(error.localizedDescription, privacy: .public)",
                    )
                }
            }
        }
    }

    /// Cancel any pending trial reminder. Safe to call when none exists.
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [trialReminderID])
        Logger.trialReminder.debug("cancelled trial reminder (if present)")
    }

    /// Return the currently-pending trial reminder request, if any. Used by
    /// `ensureReminder` to snapshot pre-cancellation state for rollback.
    private func pendingReminder() async -> UNNotificationRequest? {
        let pending = await center.pendingNotificationRequests()
        return pending.first { $0.identifier == trialReminderID }
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
                return try await center.requestAuthorization(options: [.alert, .sound])
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
