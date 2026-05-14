// ReactivationSchedulerTests
//
// SCA-365 (CR3 W4 + DB1 W1): pin the SCA-318 wiring of ReactivationScheduler
// onto NotificationSchedulerKit.addWithRollback. Specifically pins:
//   * the wire-contract userInfo shape (`stir_notification_kind=reactivation`,
//     `trigger_kind=cook_reminder`) — a typo on either side would silently
//     stop the StirNotificationDelegate from emitting
//     `reactivation_notification_opened` telemetry.
//   * the prefs gate (cancel + skip when `preferences.reactivation = false`).
//
// Notification scheduling pipeline depths (auth, rollback) are exercised
// by NotificationSchedulerKitTests; this file pins the scheduler's
// composition.

import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class ReactivationSchedulerTests: XCTestCase {
    private var prefsDefaults: UserDefaults!
    private var suiteName: String!
    private var prefsStore: NotificationPreferencesStore!

    override func setUp() {
        super.setUp()
        suiteName = "test.reactivation.\(UUID().uuidString)"
        prefsDefaults = UserDefaults(suiteName: suiteName)
        prefsStore = NotificationPreferencesStore(defaults: prefsDefaults)
    }

    override func tearDown() {
        prefsDefaults.removePersistentDomain(forName: suiteName)
        prefsDefaults = nil
        prefsStore = nil
        suiteName = nil
        super.tearDown()
    }

    /// SCA-318: when prefs.reactivation = false, the scheduler must NOT
    /// add a notification request. (The integration-level rollback /
    /// onRollbackFailure paths are exercised by NotificationSchedulerKitTests;
    /// this is the scheduler-side gate.)
    func test_scheduleAfterCook_disabledByPrefs_doesNothing() async {
        prefsStore.setReactivation(false)
        let center = SpyCenter(authStatus: .authorized)
        let scheduler = ReactivationScheduler(
            center: center,
            calendar: .current,
            preferences: prefsStore,
        )
        await scheduler.scheduleAfterCook(now: Date())
        XCTAssertEqual(center.added.count, 0)
        XCTAssertEqual(center.removedIDs.count, 0)
    }

    /// SCA-318 wire contract: userInfo MUST carry the keys the
    /// StirNotificationDelegate's NotificationKind enum reads. A typo
    /// either side silently breaks reactivation_notification_opened
    /// telemetry.
    func test_scheduleAfterCook_writesUserInfo_matchingNotificationKind() async {
        prefsStore.setReactivation(true)
        let center = SpyCenter(authStatus: .authorized)
        let scheduler = ReactivationScheduler(
            center: center,
            calendar: .current,
            preferences: prefsStore,
        )
        await scheduler.scheduleAfterCook(now: Date())
        XCTAssertEqual(center.added.count, 1)

        let userInfo = center.added.first?.content.userInfo ?? [:]
        XCTAssertEqual(
            userInfo["stir_notification_kind"] as? String,
            "reactivation",
            "kind matches NotificationKind.reactivation rawValue",
        )
        XCTAssertEqual(
            userInfo["trigger_kind"] as? String,
            "cook_reminder",
            "trigger_kind matches the spec §15 reactivation_notification_opened property contract",
        )
    }

    /// SCA-318 wire contract: identifier MUST be the spec-canonical
    /// "stir.reactivation.cook.7d". A drift would mean cancel() (called
    /// from RootCoordinator on app open per its docstring) misses the
    /// pending notification.
    func test_scheduleAfterCook_usesCanonicalIdentifier() async {
        prefsStore.setReactivation(true)
        let center = SpyCenter(authStatus: .authorized)
        let scheduler = ReactivationScheduler(
            center: center,
            calendar: .current,
            preferences: prefsStore,
        )
        await scheduler.scheduleAfterCook(now: Date())
        XCTAssertEqual(center.added.first?.identifier, "stir.reactivation.cook.7d")
    }
}

// MARK: - Test doubles

@MainActor
private final class SpyCenter: UserNotificationCenterClient {
    private let authStatus: UNAuthorizationStatus
    var added: [UNNotificationRequest] = []
    var removedIDs: [String] = []

    init(authStatus: UNAuthorizationStatus) {
        self.authStatus = authStatus
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIDs.append(contentsOf: identifiers)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }

    func notificationSettings() async -> UNNotificationSettings {
        TestSettings(authorizationStatus: authStatus)
    }

    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
        authStatus == .authorized
    }
}

private final class TestSettings: UNNotificationSettings, @unchecked Sendable {
    private let _authStatus: UNAuthorizationStatus

    init(authorizationStatus: UNAuthorizationStatus) {
        self._authStatus = authorizationStatus
        super.init(coder: NSKeyedUnarchiver(forReadingWith: Data()))!
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("not used") }

    override var authorizationStatus: UNAuthorizationStatus { _authStatus }
}
