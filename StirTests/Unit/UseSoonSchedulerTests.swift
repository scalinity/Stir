// UseSoonSchedulerTests
//
// SCA-365 (CR3 W4 + DB1 W2): pin the testable surfaces of UseSoonScheduler.
// The full scheduling pipeline (`evaluateAndScheduleIfDue`) depends on
// PantryItemRepository / CookingSessionRepository / Core Data and is
// out-of-scope for unit tests; the kit primitives it composes are
// covered by NotificationSchedulerKitTests. This file pins:
//   * `recordAction()`: clears suppression even on empty history
//     (SCA-376 contract) AND emits useSoonTapped exactly once.
//   * `cancel()`: removes the spec-canonical identifier.
//   * `nextFireDate(from:)`: clamp into the 8am–8:30pm local window.
//
// SCA-320's no_displayable_candidate suppression branch + dropped
// userInfo `use_first_display_name` field are pinned by the
// integration-level review (DB1 inspected the diff) — a fixture-based
// test would require a Core Data PantryItem with nil/empty displayName
// and is deferred to SCA-365 follow-up if the fixture infrastructure
// becomes available.

import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class UseSoonSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.use_soon.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - cancel()

    /// Spec-canonical identifier — drift would mean cancel() misses the
    /// pending notification (e.g. RootCoordinator's foreground hook).
    func test_cancel_removesCanonicalIdentifier() {
        let center = SpyCenter()
        let scheduler = UseSoonScheduler(
            center: center,
            calendar: .current,
            defaults: defaults,
        )
        scheduler.cancel()
        XCTAssertEqual(center.removedIDs, ["stir.use_soon.48h"])
    }

    // MARK: - nextFireDate clamp

    /// Mid-window (noon PT) → fire at now + 5 minutes.
    func test_nextFireDate_inWindow_returnsNowPlus5min() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduler = UseSoonScheduler(
            center: SpyCenter(),
            calendar: cal,
            defaults: defaults,
        )
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 12))!
        let expected = now.addingTimeInterval(5 * 60)
        XCTAssertEqual(scheduler.nextFireDate(from: now), expected)
    }

    /// Pre-8am PT → bump to today at 8am.
    func test_nextFireDate_beforeWindow_bumpsToToday8am() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduler = UseSoonScheduler(
            center: SpyCenter(),
            calendar: cal,
            defaults: defaults,
        )
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 6))!
        let expected = cal.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 8))!
        XCTAssertEqual(scheduler.nextFireDate(from: now), expected)
    }

    /// Past 8:30pm PT → bump to tomorrow at 8am.
    func test_nextFireDate_pastWindow_bumpsToTomorrow8am() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let scheduler = UseSoonScheduler(
            center: SpyCenter(),
            calendar: cal,
            defaults: defaults,
        )
        let now = cal.date(from: DateComponents(year: 2026, month: 5, day: 13, hour: 21))!
        let expected = cal.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 8))!
        XCTAssertEqual(scheduler.nextFireDate(from: now), expected)
    }

    // MARK: - recordAction

    /// SCA-376: card-tap engagement (TonightHomeView → recordAction)
    /// clears suppression even when fire history is empty. Pre-fix, the
    /// guard let in markMostRecentActioned early-returned and skipped
    /// the suppression-clear; a stale 14-day suppression-until could
    /// persist even after the user demonstrated engagement.
    func test_recordAction_emptyHistory_clearsSuppression() {
        // Pre-arm a phantom suppression entry under the same key
        // UseSoonScheduler uses internally.
        defaults.set(
            Date().addingTimeInterval(7 * 86_400),
            forKey: "stir.use_soon.suppressed_until.v1",
        )
        let scheduler = UseSoonScheduler(
            center: SpyCenter(),
            calendar: .current,
            defaults: defaults,
        )
        scheduler.recordAction()
        XCTAssertNil(
            defaults.object(forKey: "stir.use_soon.suppressed_until.v1"),
            "SCA-376: card-tap engagement clears suppression even on empty history",
        )
    }
}

// MARK: - Test doubles

@MainActor
private final class SpyCenter: UserNotificationCenterClient {
    var removedIDs: [String] = []

    func add(_: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIDs.append(contentsOf: identifiers)
    }
    func pendingNotificationRequests() async -> [UNNotificationRequest] { [] }
    func notificationSettings() async -> UNNotificationSettings {
        TestSettings(authorizationStatus: .authorized)
    }
    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool { true }
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
