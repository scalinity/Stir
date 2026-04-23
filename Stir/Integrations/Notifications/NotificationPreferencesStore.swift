// NotificationPreferencesStore
//
// Local source of truth for notification-type opt-ins. UserDefaults-
// backed so the toggle state persists across launches and survives
// reinstall (via iCloud Keychain's sync of app defaults when the
// user has that enabled). Settings NotificationPrefsView reads +
// writes through this store; ReactivationScheduler + the async-
// import delivery path each check their own key before scheduling.
//
// Server sync: the step-7 backend `/v1/push/register` accepts a
// `notification_prefs` sub-object but iOS only sends it alongside
// an APNs device token. Until APNs-token acquisition ships (step 8
// AppDelegate-style registration), prefs stay local and inform
// scheduling decisions client-side only. When the server sync lands,
// it'll flush this store's snapshot via AIDispatch.pushRegister.

import Foundation

@MainActor
final class NotificationPreferencesStore {
    static let shared = NotificationPreferencesStore()

    struct Preferences: Equatable, Sendable {
        /// 2-day-before trial reminder (trial_reminder_sent telemetry).
        var trialReminder: Bool
        /// 7-day-after-last-cook "Cook something tonight?" reminder.
        var reactivation: Bool
        /// Async-import completion (>5000 char paste → pgmq worker →
        /// APNs push when parse finishes).
        var importCompletion: Bool

        static let defaults = Preferences(
            trialReminder: true,
            reactivation: true,
            importCompletion: true,
        )
    }

    private let defaults: UserDefaults
    private static let trialKey     = "stir.notif.trialReminder.v1"
    private static let reactKey     = "stir.notif.reactivation.v1"
    private static let importKey    = "stir.notif.importCompletion.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    var preferences: Preferences {
        Preferences(
            trialReminder: readBool(Self.trialKey, default: true),
            reactivation: readBool(Self.reactKey, default: true),
            importCompletion: readBool(Self.importKey, default: true),
        )
    }

    // MARK: - Write

    func setTrialReminder(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.trialKey)
    }

    func setReactivation(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.reactKey)
    }

    func setImportCompletion(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.importKey)
    }

    // MARK: - Bulk replace (used by server sync when it lands)

    func replace(with prefs: Preferences) {
        setTrialReminder(prefs.trialReminder)
        setReactivation(prefs.reactivation)
        setImportCompletion(prefs.importCompletion)
    }

    // MARK: - Private

    /// Distinct-default-read: `UserDefaults.bool(forKey:)` returns false
    /// for unset keys. We want the default to be TRUE for a fresh user
    /// (opt-in UX) so we check `.object(forKey:) != nil` first.
    private func readBool(_ key: String, default defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
