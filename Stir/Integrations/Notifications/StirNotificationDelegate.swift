// StirNotificationDelegate
//
// UNUserNotificationCenterDelegate implementation. Responsible for:
//   - Presenting notifications in-foreground with banner + sound.
//   - Swapping the default iOS Tri-tone for a softer "Tink" chime when
//     a Cook Mode timer notification fires while the app is foreground.
//   - Emitting `trial_reminder_sent` when the trial-reminder notification
//     is delivered (spec §15 canonical).
//
// The delegate is installed at launch by StirApp via
// `StirNotificationDelegate.register()`. It's a singleton because
// UNUserNotificationCenter.delegate is a global slot.

import AudioToolbox
import Foundation
import UserNotifications

final class StirNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = StirNotificationDelegate()

    /// SystemSoundID for the foreground timer chime. 1057 is iOS's
    /// "Tink" — a single-note soft chime that's audible without being
    /// startling, suited to a kitchen-cook context. Hoisted as a named
    /// constant so a future swap to a custom-bundled chime only touches
    /// one place. `AudioServicesPlaySystemSound` respects the device
    /// silent switch, so the cue correctly stays silent when muted.
    private static let tinkSoundID: SystemSoundID = 1057

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
    ///
    /// Timer notifications take a custom audio path: the system Tri-tone
    /// is too aggressive for a kitchen-cook chime, so we swap it for the
    /// soft "Tink" SystemSoundID (1057) and suppress the default `.sound`
    /// option. This applies in-foreground only — background / killed
    /// delivery still uses `content.sound = .default` from the original
    /// `UNNotificationRequest` so the user gets a familiar, audible cue
    /// when the app isn't on screen.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        emitTelemetryIfTrialReminder(notification)
        emitTelemetryIfReactivation(notification)

        let userInfo = notification.request.content.userInfo
        if TimerNotification.isTimer(from: userInfo) {
            // Single-note soft chime. We suppress `.sound` from the
            // presentation options so the system doesn't ALSO fire the
            // default Tri-tone on top of our chime.
            AudioServicesPlaySystemSound(Self.tinkSoundID)
            completionHandler([.banner])
            return
        }
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

        // Route through the typed builder (same pattern as step-5/step-7
        // telemetry — prevents property-name drift).
        telemetry.capture(
            .reactivationNotificationOpened,
            properties: StepSevenTelemetry.reactivationNotificationOpened(triggerKind: triggerKind),
        )
    }
}
