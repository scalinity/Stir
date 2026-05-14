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

import CryptoKit
import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
final class APNsRegistrationCoordinator {
    static let shared = APNsRegistrationCoordinator()

    typealias PushRegisterFn = (PushRegisterRequest) async throws -> PushRegisterResponse

    /// SCA-368: derive from `#if DEBUG` so the wire-side `environment`
    /// flips automatically with build configuration — matches the
    /// `SentryReporter` pattern in `StirApp.swift:33-37`.
    ///
    /// The `aps-environment` entitlement (`Stir.entitlements`) and this
    /// constant MUST agree on the APNs class. Today entitlement is
    /// `development` (sandbox-class tokens) and this returns `.sandbox`
    /// in DEBUG. Pre-prod release will require flipping the entitlement
    /// to `production` (Release Xcode config); this constant then
    /// auto-resolves to `.production`. If the entitlement flip is
    /// forgotten, the wire-side environment will mismatch what APNs
    /// minted the token for and registration will fail loudly in
    /// dev/QA — the desired failure mode.
    ///
    /// Server CHECK constraint accepts only `production` / `sandbox`
    /// (NOT `development`).
    static var environment: PushRegisterRequest.Environment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }

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
    /// SCA-393 — superseded `.v1` key that Codable-stored the raw
    /// 64-char hex APNs token at field `tokenHex`. SCA-372 bumped to
    /// `.v2` (SHA-256 hex at `tokenHash`) but never SCRUBBED `.v1`,
    /// so every upgrader from SCA-316/317 → SCA-371 carried the
    /// plaintext token in UserDefaults indefinitely
    /// (`NSFileProtectionCompleteUntilFirstUserAuthentication`,
    /// readable by anyone with first-unlock access). `init` removes
    /// the legacy key once per process; idempotent (no-op when
    /// already scrubbed). No legitimate `.v1` reader remains. CWE-312.
    private static let legacyV1Key = "stir.apns.lastPushSnapshot.v1"

    /// SCA-354: single in-flight POST Task. `schedulePost` cancels
    /// any previous Task before spawning a new one, serializing
    /// concurrent token-rotation / burst-toggle calls so they can't
    /// race the snapshot cache (read+write across an `await
    /// registerFn(...)` suspension previously interleaved between two
    /// concurrent `postIfChanged` calls, both reading the same stale
    /// snapshot, both POSTing, and the older response winning the
    /// snapshot-cache write).
    ///
    /// `postIfChanged` already short-circuits when nothing changed,
    /// so cancel-and-replace is cheap: the inner work-loop checks
    /// `Task.isCancelled` cooperatively at the next suspension point
    /// (the await on `registerFn`).
    private var inFlightPost: Task<Void, Never>?

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
        // SCA-393: scrub the SCA-372-superseded `.v1` snapshot key so
        // upgraders no longer carry the plaintext APNs token in
        // UserDefaults. Idempotent — `removeObject` on an absent key
        // is a no-op. See `legacyV1Key` docstring above for the CWE.
        defaults.removeObject(forKey: Self.legacyV1Key)
    }

    /// Wire the coordinator to a live AIDispatch.pushRegister(...). Called
    /// from `RootCoordinator.init` after AIDispatch is constructed. Until
    /// configured, every code path is a no-op (logged at debug).
    ///
    /// SCA-351: if a device token has already arrived (handleDeviceToken
    /// fired BEFORE configure on the iOS-17+ fast path), replay the post
    /// now. Three independent reviewers (CR1/CA2/DB1) flagged that the
    /// prior shape silently dropped first-launch tokens when the
    /// AppDelegate's didRegister Task ran ahead of StirApp.init's
    /// configure. The server-side push-register is idempotent so a
    /// configure-replay is safe to run unconditionally.
    func configure(register: @escaping PushRegisterFn) {
        registerFn = register
        Logger.notifications.info("apns_coordinator_configured")
        if currentTokenHex != nil {
            schedulePost(reason: "configure_replay")
        }
    }

    /// AppDelegate forwards `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// Hex-encodes the token, caches it in-memory, and POSTs the current
    /// prefs snapshot. Same (token, prefs) tuple as last successful POST
    /// short-circuits the round-trip.
    func handleDeviceToken(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        currentTokenHex = hex
        Logger.notifications.info("apns_device_token_received len=\(data.count, privacy: .public)")
        schedulePost(reason: "token_received")
    }

    /// AppDelegate forwards `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    /// Logged via OSLog; no Sentry capture (transient APNs reachability
    /// issues are routine and would just generate noise). No retry — iOS
    /// re-invokes register on next foreground when network conditions
    /// improve.
    func handleRegistrationFailure(_ error: Error) {
        Logger.notifications.warning(
            // SCA-366: error.localizedDescription marked .private to match
            // sibling lines (NotificationSchedulerKit.swift:99,200,220).
            // URLSession + APNs errors can carry URLs/hostnames in the
            // localizedDescription; .public would leak them into
            // sysdiagnose / Console.app capture.
            "apns_registration_failed err=\(error.localizedDescription, privacy: .private)",
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
    ///
    /// SCA-354: routes through `schedulePost` so a burst-toggle
    /// (user fat-fingers 4 toggles in 5s) coalesces to a single
    /// in-flight POST instead of N concurrent ones racing the
    /// snapshot cache.
    func flushPrefs() {
        schedulePost(reason: "prefs_flush")
    }

    // MARK: - Private

    /// SCA-354: cancel any in-flight POST and replace with a fresh
    /// Task. Serializes concurrent calls into a single POST pipeline
    /// so the read+write across an `await registerFn(...)` suspension
    /// can't race two callers reading the same stale snapshot, both
    /// POSTing, and the older response winning the snapshot-cache
    /// write (which would defeat SCA-321's per-install keying
    /// invariant). `postIfChanged` short-circuits on unchanged
    /// snapshot so cancel-and-replace pays no extra round-trip cost.
    private func schedulePost(reason: String) {
        inFlightPost?.cancel()
        inFlightPost = Task { [weak self] in
            await self?.postIfChanged(reason: reason)
        }
    }

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
            // SCA-372: persist the SHA-256 hex of the token rather than
            // the raw bytes. Equality semantics intact (compare hashes);
            // removes the plaintext-at-rest exposure surface in
            // UserDefaults (NSFileProtectionCompleteUntilFirstUserAuth-
            // entication, not encrypted at rest). The raw token stays
            // in `currentTokenHex` (in-memory only) for this process
            // lifetime.
            tokenHash: Self.sha256Hex(token),
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
            // SCA-370: severity tiers based on error class —
            //   * AUTH-01 user_stale → .error (genuine recovery
            //     signal: server says user row is gone; iOS should
            //     re-bootstrap to mint a fresh JWT instead of
            //     looping silently on the same stale JWT).
            //   * StirError.unknown wrapping RootCoordinatorDeallocated
            //     (SCA-371) → .fault (invariant violation; RC is
            //     documented to live for app lifetime).
            //   * everything else (transient network, etc.) → .warning
            //     as before.
            let severity = classifyPostFailure(error)
            // SCA-366: err marked .private (URL/host content); trigger
            // remains .public (closed-vocabulary string).
            switch severity {
            case .userStale:
                Logger.notifications.error(
                    "apns_post_failed_user_stale trigger=\(reason, privacy: .public) err=\(error.localizedDescription, privacy: .private) — iOS should re-bootstrap",
                )
            case .invariantViolation:
                Logger.notifications.fault(
                    "apns_post_failed_invariant trigger=\(reason, privacy: .public) err=\(error.localizedDescription, privacy: .private)",
                )
            case .transient:
                Logger.notifications.warning(
                    "apns_post_failed trigger=\(reason, privacy: .public) err=\(error.localizedDescription, privacy: .private)",
                )
            }
        }
    }

    private enum PostFailureSeverity {
        case userStale
        case invariantViolation
        case transient
    }

    /// SCA-370: classify a `postIfChanged` catch-block error into the
    /// right OSLog severity. user_stale is recoverable via re-bootstrap;
    /// invariant violations should surface in fault logs; everything
    /// else is treated as transient.
    private func classifyPostFailure(_ error: Error) -> PostFailureSeverity {
        if let stirError = error as? StirError {
            switch stirError {
            case let .auth(reason, _):
                if reason == .userStale {
                    return .userStale
                }
                return .transient
            case let .unknown(underlying):
                // SCA-371: the configure-closure throws .unknown wrapping
                // a typed marker when RootCoordinator deallocates. That's
                // an invariant violation, not a routine error.
                let typeName = String(describing: type(of: underlying))
                if typeName.contains("RootCoordinatorDeallocated") {
                    return .invariantViolation
                }
                return .transient
            default:
                return .transient
            }
        }
        return .transient
    }

    // MARK: - Snapshot persistence

    /// SCA-372: persists the SHA-256 hex of the token, not the raw hex
    /// bytes — UserDefaults is not encrypted at rest, and a stolen
    /// device-token + the provider signing key would let an attacker
    /// push to the device. The hash gives equality-based short-circuit
    /// without the plaintext exposure. SCA-350's .v2 cache key remains;
    /// SCA-372 lands on the same key (token contents change shape, but
    /// Codable JSON keys are unchanged because we renamed the field).
    private struct Snapshot: Codable, Equatable {
        let tokenHash: String
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

    /// SCA-372: SHA-256 hex of an arbitrary input string. Used to
    /// persist token hashes in the `Snapshot` cache without storing
    /// raw APNs device tokens in plaintext UserDefaults.
    private static func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
