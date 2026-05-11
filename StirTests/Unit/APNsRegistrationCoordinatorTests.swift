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
        XCTAssertNil(defaults.data(forKey: "stir.apns.lastPushSnapshot.v1"))
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
