// StirNotificationDelegate
//
// UNUserNotificationCenterDelegate implementation. Responsible for:
//   - Presenting notifications in-foreground with banner + sound.
//   - Emitting `trial_reminder_sent` when the trial-reminder notification
//     is delivered (spec §15 canonical).
//
// The delegate is installed at launch by StirApp via
// `StirNotificationDelegate.register()`. It's a singleton because
// UNUserNotificationCenter.delegate is a global slot.

import Foundation
import UserNotifications

final class StirNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = StirNotificationDelegate()

    private let telemetry: PostHogClient
    /// Identifiers we've already emitted `trial_reminder_sent` for this
    /// process lifetime. Guards against double-emission when a single
    /// notification triggers both `willPresent` (foreground delivery) AND
    /// `didReceive` (user subsequently taps the banner). The set stays
    /// bounded — trial reminders use a singleton identifier so this is
    /// a 1-entry set in practice.
    private var emittedReminderIDs: Set<String> = []
    private let emitLock = NSLock()

    init(telemetry: PostHogClient = .shared) {
        self.telemetry = telemetry
        super.init()
    }

    /// Install as the center's delegate. Idempotent — calling twice just
    /// overwrites the global slot with the same object.
    static func register() {
        UNUserNotificationCenter.current().delegate = shared
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Delivery while app is foregrounded. Show banner + play sound so the
    /// user notices, and emit `trial_reminder_sent` if this is the trial
    /// reminder payload.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        emitTelemetryIfTrialReminder(notification)
        emitTelemetryIfReactivation(notification)
        completionHandler([.banner, .sound])
    }

    /// Delivery when user taps a notification in-background → app foregrounds.
    /// We emit `trial_reminder_sent` on delivery (not on tap) so the
    /// telemetry value counts users who SAW the reminder, not users who
    /// tapped through. Tap-through is covered separately via
    /// reactivation_notification_opened in step 8.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        emitTelemetryIfTrialReminder(response.notification)
        emitTelemetryIfReactivation(response.notification)
        completionHandler()
    }

    private func emitTelemetryIfTrialReminder(_ notification: UNNotification) {
        let userInfo = notification.request.content.userInfo
        guard let days = TrialReminderNotification.daysRemaining(from: userInfo) else { return }

        // Dedup: a foreground-delivered trial reminder fires `willPresent`
        // at delivery AND `didReceive` on tap-through. Emitting both would
        // double-count the "saw the reminder" event in PostHog. Track by
        // notification identifier so a single delivery produces exactly
        // one `trial_reminder_sent`.
        let id = notification.request.identifier
        emitLock.lock()
        let shouldEmit = emittedReminderIDs.insert(id).inserted
        emitLock.unlock()
        guard shouldEmit else { return }

        telemetry.capture(
            .trialReminderSent,
            properties: BillingTelemetryProperties.trialReminderSent(daysRemaining: days),
        )
    }

    /// Emit `reactivation_notification_opened` with `trigger_kind` when the
    /// 7-day cook-reminder fires (delivery OR tap-through). Dedupe on the
    /// shared `emittedReminderIDs` set since reactivation uses its own
    /// singleton identifier (`stir.reactivation.cook.7d`) so same-ID
    /// double-invocation can't fire the event twice.
    private func emitTelemetryIfReactivation(_ notification: UNNotification) {
        let userInfo = notification.request.content.userInfo
        guard let triggerKind = ReactivationNotification.triggerKind(from: userInfo) else { return }

        let id = notification.request.identifier
        emitLock.lock()
        let shouldEmit = emittedReminderIDs.insert(id).inserted
        emitLock.unlock()
        guard shouldEmit else { return }

        telemetry.capture(
            .reactivationNotificationOpened,
            properties: ["trigger_kind": triggerKind],
        )
    }
}
