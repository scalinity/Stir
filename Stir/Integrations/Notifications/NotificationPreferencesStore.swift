// NotificationPreferencesStore
//
// Local source of truth for notification-type opt-ins. UserDefaults-
// backed so the toggle state persists across launches and survives
// reinstall (via iCloud Keychain's sync of app defaults when the
// user has that enabled). Settings NotificationPrefsView reads +
// writes through this store; ReactivationScheduler + the async-
// import delivery path each check their own key before scheduling.
//
// Server sync: SCA-316 wired `APNsRegistrationCoordinator.flushPrefs()`
// to push this store's snapshot to `/v1/push/register` on every toggle
// change AND on first APNs token grant. Idempotency on the server
// short-circuits no-op POSTs.
//
// SCA-322 widening: `cookReminder` and `billingGrace` added so iOS
// covers every category in `APNsCategory` (Backend/_shared/apns.ts).
// `cook_reminder` has no backend enqueue path today; `billing_grace`
// is enqueued by `revenuecat-webhook` on BILLING_ISSUE events and
// gated server-side on `notification_prefs_json.billing_grace`. All
// four prefs default TRUE (opt-in UX) and surface as Settings
// toggles in NotificationPrefsView.

import Foundation

@MainActor
final class NotificationPreferencesStore {
    static let shared = NotificationPreferencesStore()

    struct Preferences: Equatable, Sendable {
        /// 7-day-after-last-cook "Cook something tonight?" reminder.
        var reactivation: Bool
        /// Async-import completion (>5000 char paste → pgmq worker →
        /// APNs push when parse finishes).
        var importCompletion: Bool
        /// Cook reminder push (no backend enqueue path today; field
        /// reserved for the future cook_reminder template).
        var cookReminder: Bool
        /// Billing grace push fired by revenuecat-webhook when Apple's
        /// auto-renew throws BILLING_ISSUE during the grace window.
        var billingGrace: Bool

        static let defaults = Preferences(
            reactivation: true,
            importCompletion: true,
            cookReminder: true,
            billingGrace: true,
        )
    }

    private let defaults: UserDefaults
    private static let reactKey         = "stir.notif.reactivation.v1"
    private static let importKey        = "stir.notif.importCompletion.v1"
    private static let cookReminderKey  = "stir.notif.cookReminder.v1"
    private static let billingGraceKey  = "stir.notif.billingGrace.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Read

    var preferences: Preferences {
        Preferences(
            reactivation: readBool(Self.reactKey, default: true),
            importCompletion: readBool(Self.importKey, default: true),
            cookReminder: readBool(Self.cookReminderKey, default: true),
            billingGrace: readBool(Self.billingGraceKey, default: true),
        )
    }

    // MARK: - Write

    func setReactivation(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.reactKey)
    }

    func setImportCompletion(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.importKey)
    }

    func setCookReminder(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.cookReminderKey)
    }

    func setBillingGrace(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.billingGraceKey)
    }

    // MARK: - Bulk replace (used by server sync when it lands)

    func replace(with prefs: Preferences) {
        setReactivation(prefs.reactivation)
        setImportCompletion(prefs.importCompletion)
        setCookReminder(prefs.cookReminder)
        setBillingGrace(prefs.billingGrace)
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
