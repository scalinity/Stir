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
        // SCA-387: the unconfigured path has no observable side-effect to
        // wait on (no recorder), but the Task spawn inside the coordinator
        // still needs a few yields to actually run. yieldForPostTask is
        // retained ONLY for this branch — there's no expectation to
        // fulfill, so a deterministic wait isn't applicable.
        await yieldForPostTask()
        // No way to assert "no post" without a recorder, but we can prove
        // it via the cache: a successful post writes a snapshot to
        // UserDefaults; absence proves no successful POST landed.
        XCTAssertNil(defaults.data(forKey: "stir.apns.lastPushSnapshot.v1"))
    }

    func test_handleDeviceToken_configured_postsHexToken() async {
        let expect = expectation(description: "POST recorded")
        let recorder = PostRecorder(onRecord: { expect.fulfill() })
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xab, 0xcd, 0x01]))
        await fulfillment(of: [expect], timeout: 5.0)

        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.apnsToken, "abcd01")
        XCTAssertEqual(posts.first?.environment, .sandbox)
    }

    func test_handleDeviceToken_sameTuple_skipsSecondPost() async {
        // SCA-387: only the FIRST POST is expected to land — the second
        // identical token short-circuits via the lastSnapshot cache and
        // never fulfills. expect captures the first POST; we then do a
        // bounded yield window after the second handleDeviceToken to
        // give a faulty implementation a chance to (incorrectly) POST,
        // and finally assert count == 1.
        let expect = expectation(description: "first POST recorded")
        let recorder = PostRecorder(onRecord: { expect.fulfill() })
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await fulfillment(of: [expect], timeout: 5.0)
        coord.handleDeviceToken(Data([0xab, 0xcd]))
        // Bounded yield window so a regression that DOES POST the second
        // token has time to land before we assert. 20 yields >> 5 used
        // pre-fix; tight enough to keep the test fast on the green path.
        for _ in 0 ..< 20 { await Task.yield() }

        let count = await recorder.posts.count
        XCTAssertEqual(count, 1, "second identical token should short-circuit via lastSnapshot cache")
    }

    func test_flushPrefs_changesPrefs_rePosts() async {
        let firstExpect = expectation(description: "first POST recorded")
        let secondExpect = expectation(description: "second POST recorded after prefs change")
        let bothExpects: [XCTestExpectation] = [firstExpect, secondExpect]
        var seen = 0
        let recorder = PostRecorder(onRecord: {
            // Fulfill in order, ignore extras (any "third" POST would be
            // caught by the count assertion below). The order matters —
            // first expect for the token POST, second for the prefs flush.
            if seen < bothExpects.count {
                bothExpects[seen].fulfill()
                seen += 1
            }
        })
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.handleDeviceToken(Data([0xab, 0xcd]))
        await fulfillment(of: [firstExpect], timeout: 5.0)

        prefsStore.setReactivation(false)
        coord.flushPrefs()
        await fulfillment(of: [secondExpect], timeout: 5.0)

        let posts = await recorder.posts
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts[0].notificationPrefs.reactivation)
        XCTAssertFalse(posts[1].notificationPrefs.reactivation)
    }

    func test_flushPrefs_noToken_skipsPost() async {
        // SCA-387: flushPrefs WITHOUT a prior token must NOT POST.
        // There's nothing to fulfill — same shape as
        // test_handleDeviceToken_unconfigured_doesNotPost. yieldForPostTask
        // gives any (faulty) Task time to run before the negative assertion.
        let recorder = PostRecorder()
        let coord = makeCoordinator()
        coord.configure(register: { body in
            await recorder.record(body)
            return PushRegisterResponse(installationID: "i-1", environment: "sandbox")
        })

        coord.flushPrefs()
        for _ in 0 ..< 20 { await Task.yield() }

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
    /// SCA-387: fires after each record() call so tests can await a
    /// deterministic expectation instead of guessing how many
    /// `Task.yield()` calls are enough. Nil for negative-assertion tests
    /// that don't expect any record at all.
    private let onRecord: (@Sendable () -> Void)?

    init(onRecord: (@Sendable () -> Void)? = nil) {
        self.onRecord = onRecord
    }

    func record(_ body: PushRegisterRequest) {
        posts.append(body)
        onRecord?()
    }
}
