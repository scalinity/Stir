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
        completionHandler()
    }

    private func emitTelemetryIfTrialReminder(_ notification: UNNotification) {
        let userInfo = notification.request.content.userInfo
        guard let days = TrialReminderNotification.daysRemaining(from: userInfo) else { return }
        telemetry.capture(
            .trialReminderSent,
            properties: BillingTelemetryProperties.trialReminderSent(daysRemaining: days),
        )
    }
}
