// LeftoversFollowupSchedulerTests
//
// Unit coverage for SCA-65 — the +20h leftovers followup scheduler.
// Each test runs against an isolated UserDefaults suite so cap +
// suppression state never leaks across tests or into the shared
// app group.

import XCTest
@testable import Stir

@MainActor
final class LeftoversFollowupSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        suiteName = "test.leftovers_followup.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // PST so the 10am–7pm clamp checks have a stable timezone
        // regardless of the test runner host.
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        calendar = nil
        super.tearDown()
    }

    // MARK: - nextFireDate clamp

    /// Submit at noon PST — +20h = 8am next day → bump to 10am same day.
    func test_nextFireDate_morningOverflow_bumpsTo10am() {
        let scheduler = LeftoversFollowupScheduler(
            calendar: calendar,
            defaults: defaults,
        )
        let submittedAt = makeDate(year: 2026, month: 5, day: 7, hour: 12, minute: 0)
        let fire = scheduler.nextFireDate(from: submittedAt)
        let comps = calendar.dateComponents([.hour, .minute, .day], from: fire)
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.minute, 0)
        XCTAssertEqual(comps.day, 8, "raw +20h falls 8am next day; clamped to 10am SAME calendar day (the +20h day)")
    }

    /// Submit at 8pm PST — +20h = 4pm next day → in window, return as-is.
    func test_nextFireDate_inWindow_returnsAsIs() {
        let scheduler = LeftoversFollowupScheduler(
            calendar: calendar,
            defaults: defaults,
        )
        let submittedAt = makeDate(year: 2026, month: 5, day: 7, hour: 20, minute: 0)
        let fire = scheduler.nextFireDate(from: submittedAt)
        let comps = calendar.dateComponents([.hour, .day], from: fire)
        XCTAssertEqual(comps.hour, 16)
        XCTAssertEqual(comps.day, 8)
    }

    /// Submit at 1am PST — +20h = 9pm same day → bump to 10am NEXT day.
    func test_nextFireDate_eveningOverflow_bumpsToNext10am() {
        let scheduler = LeftoversFollowupScheduler(
            calendar: calendar,
            defaults: defaults,
        )
        let submittedAt = makeDate(year: 2026, month: 5, day: 7, hour: 1, minute: 0)
        let fire = scheduler.nextFireDate(from: submittedAt)
        let comps = calendar.dateComponents([.hour, .day], from: fire)
        XCTAssertEqual(comps.hour, 10)
        XCTAssertEqual(comps.day, 8)
    }

    // MARK: - HistoryStore

    func test_historyStore_capPerWeek_returnsRecentFires() {
        let store = HistoryStore(defaults: defaults)
        store.recordScheduled(fireAt: Date().addingTimeInterval(-3 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-10 * 86_400))  // outside window
        let recent = store.firesInLastWeek(asOf: Date())
        XCTAssertEqual(recent.count, 2)
    }

    func test_historyStore_unactionedStreakSetsSuppression() {
        let store = HistoryStore(defaults: defaults)
        store.recordScheduled(fireAt: Date().addingTimeInterval(-2 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        XCTAssertNil(store.suppressedUntil, "two unactioned in history; the THIRD scheduling triggers suppression")
        store.recordScheduled(fireAt: Date())
        XCTAssertNotNil(store.suppressedUntil, "third schedule with prior 2 unactioned must arm 14d suppression")
    }

    func test_historyStore_actionClearsSuppression() {
        let store = HistoryStore(defaults: defaults)
        store.recordScheduled(fireAt: Date().addingTimeInterval(-2 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        store.recordScheduled(fireAt: Date())  // suppression armed
        XCTAssertNotNil(store.suppressedUntil)
        store.markMostRecentActioned(at: Date())
        XCTAssertNil(store.suppressedUntil, "user engaged — clear suppression")
    }

    func test_historyStore_actionedRunResetsStreak() {
        let store = HistoryStore(defaults: defaults)
        store.recordScheduled(fireAt: Date().addingTimeInterval(-3 * 86_400))
        store.markMostRecentActioned(at: Date())
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        // One unactioned + one actioned in history; third schedule must NOT arm suppression
        // (the prior-2 streak check only arms when both are unactioned).
        store.recordScheduled(fireAt: Date())
        XCTAssertNil(store.suppressedUntil, "actioned entry breaks the unactioned streak")
    }

    // MARK: - Notification payload

    func test_leftoversFollowupNotification_recognizesPayload() {
        XCTAssertTrue(LeftoversFollowupNotification.isFollowup(from: [
            "stir_notification_kind": "leftovers_followup",
        ]))
        XCTAssertFalse(LeftoversFollowupNotification.isFollowup(from: [
            "stir_notification_kind": "reactivation",
        ]))
        XCTAssertFalse(LeftoversFollowupNotification.isFollowup(from: [:]))
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return calendar.date(from: comps)!
    }
}
