// APNsRegistrationCoordinator
//
// Step-8 APNs token plumbing (SCA-316). Owns the lifecycle:
//   1. Authorization gate via UNUserNotificationCenter.
//   2. UIApplication.shared.registerForRemoteNotifications() trigger.
//   3. AppDelegate-forwarded device-token receipt → hex-encode → POST to
//      /v1/push/register via AIDispatch.
//   4. Re-POST on Settings prefs change (idempotent server-side).
//
// Idempotency: caches the last successfully-POSTed (token, prefs, env)
// snapshot in UserDefaults so cold-launches don't double-fire when iOS
// returns the same token. The server is also idempotent, but skipping
// the round-trip avoids the rate-limit budget (`ip:push_register_hourly`).
//
// Test seam: `register: PushRegisterFn` closure is injected so tests can
// stub the network call without spinning up AIDispatch + URLProtocol.
// `clock` defaulted to `.now` for cache-staleness tests.
//
// AppDelegate wiring lives in `Stir/App/StirAppDelegate.swift`. The
// coordinator stays inert until `configure(register:)` is called by
// `RootCoordinator` after AIDispatch is built.

import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class APNsRegistrationCoordinator {
    static let shared = APNsRegistrationCoordinator()

    typealias PushRegisterFn = (PushRegisterRequest) async throws -> PushRegisterResponse

    /// `aps-environment` entitlement is hardcoded to `development`, so iOS
    /// always receives a sandbox-class token (the only kind APNs will mint
    /// for that entitlement value). When App Store distribution lands,
    /// flip the entitlement to `production` (or per-config) AND change
    /// this constant to derive from `#if DEBUG`. The server CHECK
    /// constraint accepts only `production` / `sandbox` (NOT `development`).
    static let environment: PushRegisterRequest.Environment = .sandbox

    private let prefsStore: NotificationPreferencesStore
    private let center: UserNotificationCenterClient
    private let defaults: UserDefaults
    private let registerForRemote: @MainActor () -> Void
    private var registerFn: PushRegisterFn?

    /// Latest hex-encoded device token, set on AppDelegate callback.
    /// Held in-memory for the process lifetime; not persisted because
    /// APNs may rotate the token at any cold launch and the source of
    /// truth is the OS callback, not our cache.
    private var currentTokenHex: String?

    /// Last successfully-POSTed (token, prefs) snapshot. Coalesces
    /// no-op POSTs across cold launches and prefs-toggle re-flushes.
    ///
    /// SCA-350: bumped to `.v2` because SCA-322 added two required
    /// `let` properties (`cookReminder`, `billingGrace`) to `Snapshot`.
    /// Decoding an SCA-316/317-era 4-key payload threw the missing-key
    /// error, `try?` collapsed to `nil`, and the no-op short-circuit
    /// at `postIfChanged` lost effect — every cold launch + prefs flush
    /// re-POSTed against the `ip:push_register_hourly = 20` cap. The
    /// `.v2` rename naturally invalidates the old payload; one clean
    /// re-POST seeds the new shape on first launch under this build.
    /// Future field additions to `Snapshot` MUST bump this key (or use
    /// `decodeIfPresent` with sane defaults — pick one explicitly).
    private static let lastPushKey = "stir.apns.lastPushSnapshot.v2"

    init(
        prefsStore: NotificationPreferencesStore = .shared,
        center: UserNotificationCenterClient = UNUserNotificationCenter.current(),
        defaults: UserDefaults = .standard,
        registerForRemote: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
    ) {
        self.prefsStore = prefsStore
        self.center = center
        self.defaults = defaults
        self.registerForRemote = registerForRemote
    }

    /// Wire the coordinator to a live AIDispatch.pushRegister(...). Called
    /// from `RootCoordinator.init` after AIDispatch is constructed. Until
    /// configured, every code path is a no-op (logged at debug).
    func configure(register: @escaping PushRegisterFn) {
        registerFn = register
        Logger.notifications.info("apns_coordinator_configured")
    }

    /// AppDelegate forwards `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// Hex-encodes the token, caches it in-memory, and POSTs the current
    /// prefs snapshot. Same (token, prefs) tuple as last successful POST
    /// short-circuits the round-trip.
    func handleDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        currentTokenHex = hex
        Logger.notifications.info("apns_device_token_received len=\(data.count, privacy: .public)")
        Task { await postIfChanged(reason: "token_received") }
    }

    /// AppDelegate forwards `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// Logged via OSLog; no Sentry capture (transient APNs reachability
    /// issues are routine and would just generate noise). No retry — iOS
    /// re-invokes register on next foreground when network conditions
    /// improve.
    func handleRegistrationFailure(_ error: Error) {
        Logger.notifications.warning(
            "apns_registration_failed err=\(error.localizedDescription, privacy: .public)",
        )
    }

    /// Trigger UIApplication.registerForRemoteNotifications() iff iOS has
    /// granted notification permission. Safe to call repeatedly — iOS
    /// short-circuits the request when a token already exists this run.
    /// Called from RootCoordinator on phase=.ready and from
    /// NotificationPrefsView when the user grants permission via the
    /// in-app prompt.
    func registerForRemoteNotificationsIfAuthorized() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Logger.notifications.info("apns_registering_for_remote")
            registerForRemote()
        case .notDetermined, .denied:
            Logger.notifications.debug(
                "apns_skip_register status=\(String(describing: settings.authorizationStatus), privacy: .public)",
            )
        @unknown default:
            Logger.notifications.debug("apns_skip_register status=unknown")
        }
    }

    /// Called from NotificationPrefsView toggle handlers. Re-POSTs the
    /// current prefs snapshot if we have a token; idempotency guard
    /// short-circuits when nothing changed (e.g., user toggled twice).
    func flushPrefs() {
        Task { await postIfChanged(reason: "prefs_flush") }
    }

    // MARK: - Private

    private func postIfChanged(reason: String) async {
        guard let registerFn else {
            Logger.notifications.debug("apns_post_skipped reason=not_configured")
            return
        }
        guard let token = currentTokenHex else {
            Logger.notifications.debug("apns_post_skipped reason=no_token")
            return
        }
        let prefs = prefsStore.preferences
        let snapshot = Snapshot(
            token: token,
            environment: Self.environment.rawValue,
            importCompletion: prefs.importCompletion,
            reactivation: prefs.reactivation,
            cookReminder: prefs.cookReminder,
            billingGrace: prefs.billingGrace,
        )
        if let last = readLastSnapshot(), last == snapshot {
            Logger.notifications.debug("apns_post_skipped reason=unchanged trigger=\(reason, privacy: .public)")
            return
        }
        let body = PushRegisterRequest(
            apnsToken: token,
            environment: Self.environment,
            notificationPrefs: .init(
                importCompletion: prefs.importCompletion,
                reactivation: prefs.reactivation,
                cookReminder: prefs.cookReminder,
                billingGrace: prefs.billingGrace,
            ),
        )
        do {
            _ = try await registerFn(body)
            writeLastSnapshot(snapshot)
            Logger.notifications.info(
                "apns_post_ok trigger=\(reason, privacy: .public) env=\(Self.environment.rawValue, privacy: .public)",
            )
        } catch {
            Logger.notifications.warning(
                "apns_post_failed trigger=\(reason, privacy: .public) err=\(error.localizedDescription, privacy: .public)",
            )
        }
    }

    // MARK: - Snapshot persistence

    private struct Snapshot: Codable, Equatable {
        let token: String
        let environment: String
        let importCompletion: Bool
        let reactivation: Bool
        let cookReminder: Bool
        let billingGrace: Bool
    }

    private func readLastSnapshot() -> Snapshot? {
        guard let data = defaults.data(forKey: Self.lastPushKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func writeLastSnapshot(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.lastPushKey)
    }
}
