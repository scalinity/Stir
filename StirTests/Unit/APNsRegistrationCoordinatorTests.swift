// APNsRegistrationCoordinatorTests
//
// Pin SCA-316 step-8 wiring:
//   - registerForRemoteNotificationsIfAuthorized fires only when status
//     is one of {.authorized, .provisional, .ephemeral}
//   - handleDeviceToken hex-encodes the bytes and POSTs once
//   - same (token, prefs) tuple short-circuits the second POST
//   - flushPrefs re-POSTs when prefs change
//   - handleRegistrationFailure logs but doesn't POST

import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class APNsRegistrationCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var center: SpyCenter!
    private var prefsStore: NotificationPreferencesStore!
    private var prefsDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.apns_coordinator.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        prefsDefaults = UserDefaults(suiteName: "\(suiteName!).prefs")
        prefsStore = NotificationPreferencesStore(defaults: prefsDefaults)
        center = SpyCenter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        prefsDefaults.removePersistentDomain(forName: "\(suiteName!).prefs")
        defaults = nil
        prefsDefaults = nil
        prefsStore = nil
        center = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - registerForRemoteNotificationsIfAuthorized

    func test_register_authorized_callsRegisterForRemote() async {
        center.status = .authorized
        var registerCalls = 0
        let coord = makeCoordinator(registerForRemote: { registerCalls += 1 })

        await coord.registerForRemoteNotificationsIfAuthorized()

        XCTAssertEqual(registerCalls, 1)
    }

    func test_register_provisional_callsRegisterForRemote() async {
        center.status = .provisional
        var registerCalls = 0
        let coord = makeCoordinator(registerForRemote: { registerCalls += 1 })

        await coord.registerForRemoteNotificationsIfAuthorized()

        XCTAssertEqual(registerCalls, 1)
    }

    func test_register_notDetermined_skips() async {
        center.status = .notDetermined
        var registerCalls = 0
        let coord = makeCoordinator(registerForRemote: { registerCalls += 1 })

        await coord.registerForRemoteNotificationsIfAuthorized()

        XCTAssertEqual(registerCalls, 0)
    }

    func test_register_denied_skips() async {
        center.status = .denied
        var registerCalls = 0
        let coord = makeCoordinator(registerForRemote: { registerCalls += 1 })

        await coord.registerForRemoteNotificationsIfAuthorized()

        XCTAssertEqual(registerCalls, 0)
    }

    // MARK: - handleDeviceToken / postIfChanged

    func test_handleDeviceToken_unconfigured_doesNotPost() async {
        let coord = makeCoordinator()
        // No configure() call.
        coord.handleDeviceToken(Data([0xab, 0xcd, 0x01]))
        await yieldForPostTask()
        // No way to assert "no post" without a recorder, but we can prove
        // it via the cache: a successful post writes a snapshot to
        // UserDefaults; absence proves no successful POST landed.
        // SCA-350: cache key bumped to .v2 to invalidate SCA-316/317-era
        // 4-key Snapshot payloads on upgrade.
        XCTAssertNil(defaults.data(forKey: "stir.apns.lastPushSnapshot.v2"))
    }

    /// SCA-350: an SCA-316/317-era cache payload (4 keys, missing
    /// `cookReminder`/`billingGrace`) under the LEGACY .v1 key must
    /// neither crash nor be read by the new coordinator. The .v2 rename
    /// guarantees a clean reseed on first launch under post-SCA-322
    /// builds, with one (idempotent) re-POST instead of an indefinite
    /// retry-spam loop.
    func test_legacyV1Snapshot_isIgnored_noCrash() async {
        // Seed UserDefaults with the SCA-316/317-era 4-key shape.
        let legacy = #"""
            {"token":"deadbeef","environment":"sandbox","importCompletion":true,"reactivation":true}
            """#
        defaults.set(legacy.data(using: .utf8), forKey: "stir.apns.lastPushSnapshot.v1")

        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xde, 0xad, 0xbe, 0xef]))
        await yieldForPostTask()

        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 1, "first post under .v2 build is the natural reseed")
        XCTAssertNotNil(defaults.data(forKey: "stir.apns.lastPushSnapshot.v2"),
                        ".v2 cache is now seeded")
        // .v1 payload is left in place (we don't garbage-collect old
        // keys) but is never read again.
        XCTAssertNotNil(defaults.data(forKey: "stir.apns.lastPushSnapshot.v1"))
    }

    /// SCA-351: AppDelegate's `didRegisterForRemoteNotificationsWithDeviceToken`
    /// can fire BEFORE StirApp.init's `configure(register:)` runs (iOS-17+
    /// fast path returns the cached token in <100ms). Pre-fix: token was
    /// stashed in `currentTokenHex` but `postIfChanged` short-circuited at
    /// `not_configured` and there was no replay — token silently dropped
    /// for the process lifetime. Post-fix: `configure` itself replays
    /// `postIfChanged` if a token is already cached.
    func test_configure_afterTokenReceived_replaysPost() async {
        let recorder = PostRecorder()
        let coord = makeCoordinator()

        // 1. Token arrives BEFORE configure (the race the SCA-351 fix targets).
        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await yieldForPostTask()

        // 2. Pre-replay: cache is empty, no posts recorded.
        XCTAssertNil(defaults.data(forKey: "stir.apns.lastPushSnapshot.v2"))
        let preCount = await recorder.posts.count
        XCTAssertEqual(preCount, 0, "no post lands while unconfigured")

        // 3. Now configure — fix replays postIfChanged because
        //    currentTokenHex is non-nil.
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })
        await yieldForPostTask()

        // 4. Replay landed exactly once with the original token bytes.
        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 1, "configure-replay POST lands exactly once")
        XCTAssertEqual(posts.first?.apnsToken, "abcd")
    }

    func test_handleDeviceToken_configured_postsHexToken() async {
        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xab, 0xcd, 0x01]))
        await yieldForPostTask()

        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.apnsToken, "abcd01")
        XCTAssertEqual(posts.first?.environment, .sandbox)
    }

    func test_handleDeviceToken_sameTuple_skipsSecondPost() async {
        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await yieldForPostTask()
        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await yieldForPostTask()

        let count = await recorder.posts.count
        XCTAssertEqual(count, 1, "second identical token should short-circuit via lastSnapshot cache")
    }

    func test_flushPrefs_changesPrefs_rePosts() async {
        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await yieldForPostTask()

        prefsStore.setReactivation(false)
        coord.flushPrefs()
        await yieldForPostTask()

        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts[0].notificationPrefs.reactivation)
        XCTAssertFalse(posts[1].notificationPrefs.reactivation)
    }

    func test_flushPrefs_noToken_skipsPost() async {
        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.flushPrefs()
        await yieldForPostTask()

        let count = await recorder.posts.count
        XCTAssertEqual(count, 0)
    }

    /// SCA-365 (CR3 W2): when AIDispatch.pushRegister throws, the
    /// snapshot cache MUST NOT be written — otherwise the next foreground
    /// would short-circuit on the (token, prefs) tuple and never retry.
    func test_handleDeviceToken_registerThrows_doesNotWriteSnapshot() async {
        struct FakeError: Error {}
        let coord = makeCoordinator()
        var attempts = 0
        coord.configure(register: { _ in
            attempts += 1
            throw FakeError()
        })

        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await yieldForPostTask()

        XCTAssertEqual(attempts, 1, "registerFn was called")
        XCTAssertNil(
            defaults.data(forKey: "stir.apns.lastPushSnapshot.v2"),
            "snapshot must NOT be cached on register-fn throw — next call must retry",
        )
    }

    /// SCA-365 (CR3 W3): when iOS rotates the device token (different
    /// bytes), the coordinator MUST re-POST. Snapshot equality includes
    /// the token field per the SCA-322-shaped Snapshot struct.
    func test_handleDeviceToken_differentToken_rePosts() async {
        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await yieldForPostTask()
        coord.handleDeviceToken(Data([0xde, 0xad, 0xbe, 0xef]))
        await yieldForPostTask()

        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 2, "token rotation must re-POST")
        XCTAssertEqual(posts[0].apnsToken, "abcd")
        XCTAssertEqual(posts[1].apnsToken, "deadbeef")
    }

    /// SCA-354: rapid burst of flushPrefs() calls (user fat-fingers
    /// toggles in quick succession) should COALESCE to a single in-flight
    /// POST instead of N concurrent ones. The cancel-and-replace pattern
    /// in `schedulePost` cancels each prior Task before spawning the
    /// next; only the final POST lands. Prior shape: 4 toggles → 4
    /// concurrent Tasks all reading the same stale snapshot → 4 actual
    /// POSTs against the `ip:push_register_hourly = 20` rate budget.
    func test_flushPrefs_rapidBurst_coalescesToSinglePost() async {
        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        // Seed a token so postIfChanged is allowed to fire.
        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await yieldForPostTask()
        let baselinePosts = await recorder.posts.count
        XCTAssertEqual(baselinePosts, 1, "token receipt seeds the cache with the first POST")

        // Burst: mutate prefs + flush 4 times in quick succession with
        // NO yield between calls. Each schedulePost cancels its
        // predecessor; only the final one survives to the await on
        // registerFn.
        let store = NotificationPreferencesStore(defaults: prefsDefaults)
        store.setReactivation(false)
        coord.flushPrefs()
        store.setReactivation(true)
        coord.flushPrefs()
        store.setImportCompletion(false)
        coord.flushPrefs()
        store.setImportCompletion(true)
        coord.flushPrefs()

        await yieldForPostTask()

        // Token + final-state-of-prefs matches baseline → idempotency
        // guard short-circuits, no extra POST. If burst had raced, we'd
        // see >0 additional POSTs.
        let totalPosts = await recorder.posts.count
        XCTAssertEqual(totalPosts, 1, "burst coalesces to zero additional POSTs (prefs round-tripped to original)")
    }

    // MARK: - Failure handling

    func test_handleRegistrationFailure_doesNotCrash() {
        let coord = makeCoordinator()
        struct DummyErr: Error {}
        coord.handleRegistrationFailure(DummyErr())
        // Logged-only; no observable side effect to assert beyond "no
        // crash". The integration smoke is that no exception escapes.
    }

    // MARK: - Helpers

    private func makeCoordinator(
        registerForRemote: @escaping @MainActor () -> Void = {},
    ) -> APNsRegistrationCoordinator {
        APNsRegistrationCoordinator(
            prefsStore: prefsStore,
            center: center,
            defaults: defaults,
            registerForRemote: registerForRemote,
        )
    }

    /// Lets the Task { } in handleDeviceToken / flushPrefs run.
    private func yieldForPostTask() async {
        for _ in 0 ..< 5 { await Task.yield() }
    }
}

// MARK: - Test doubles

@MainActor
private final class SpyCenter: UserNotificationCenterClient {
    var status: UNAuthorizationStatus = .authorized

    func add(_ request: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }

    func notificationSettings() async -> UNNotificationSettings {
        // UNNotificationSettings has no public init; subclass + override
        // matches the pattern used by NotificationSchedulerKitTests.
        TestSettings(authorizationStatus: status)
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }
}

private final class TestSettings: UNNotificationSettings, @unchecked Sendable {
    private let _authStatus: UNAuthorizationStatus

    init(authorizationStatus: UNAuthorizationStatus) {
        self._authStatus = authorizationStatus
        super.init(coder: NSKeyedUnarchiver(forReadingWith: Data()))!
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var authorizationStatus: UNAuthorizationStatus { _authStatus }
}

private actor PostRecorder {
    private(set) var posts: [PushRegisterRequest] = []

    func record(_ body: PushRegisterRequest) {
        posts.append(body)
    }
}
