// WidgetNudgeServiceTests
//
// SCA-72 — coverage for the eligibility decision matrix. Each test
// runs against an isolated UserDefaults suite so widget-tap +
// last-shown + permanently-dismissed state never leaks across tests.

import XCTest
@testable import Stir

@MainActor
final class WidgetNudgeServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var service: WidgetNudgeService!

    override func setUp() {
        super.setUp()
        suiteName = "test.widget_nudge.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        service = WidgetNudgeService(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Eligibility matrix

    func test_eligible_when_threeSessions_noTap_flagOn() {
        XCTAssertTrue(service.shouldShowNudge(
            sessionsInLast14Days: 3, flagEnabled: true,
        ))
    }

    func test_ineligible_when_flagOff() {
        XCTAssertFalse(service.shouldShowNudge(
            sessionsInLast14Days: 3, flagEnabled: false,
        ))
    }

    func test_ineligible_when_userHasTappedWidget() {
        service.recordWidgetTap()
        XCTAssertFalse(service.shouldShowNudge(
            sessionsInLast14Days: 5, flagEnabled: true,
        ))
    }

    func test_ineligible_when_belowSessionThreshold() {
        XCTAssertFalse(service.shouldShowNudge(
            sessionsInLast14Days: 2, flagEnabled: true,
        ))
    }

    func test_ineligible_when_permanentlyDismissed() {
        service.markPermanentlyDismissed()
        XCTAssertFalse(service.shouldShowNudge(
            sessionsInLast14Days: 5, flagEnabled: true,
        ))
    }

    // MARK: - Cooldown (21d)

    func test_ineligible_within_21d_after_lastShown() {
        let now = Date()
        service.markShown(at: now.addingTimeInterval(-10 * 86_400))
        XCTAssertFalse(service.shouldShowNudge(
            now: now, sessionsInLast14Days: 5, flagEnabled: true,
        ))
    }

    func test_eligible_after_21d_cooldown() {
        let now = Date()
        service.markShown(at: now.addingTimeInterval(-22 * 86_400))
        XCTAssertTrue(service.shouldShowNudge(
            now: now, sessionsInLast14Days: 5, flagEnabled: true,
        ))
    }

    // MARK: - State recording

    func test_recordWidgetTap_persists() {
        let now = Date()
        service.recordWidgetTap(at: now)
        XCTAssertNotNil(service.lastWidgetTap)
    }

    func test_markShown_persists() {
        let now = Date()
        service.markShown(at: now)
        XCTAssertNotNil(service.lastNudgeShown)
    }

    func test_markPermanentlyDismissed_persists() {
        XCTAssertFalse(service.isPermanentlyDismissed)
        service.markPermanentlyDismissed()
        XCTAssertTrue(service.isPermanentlyDismissed)
    }

    func test_reset_clearsAll() {
        service.recordWidgetTap()
        service.markShown()
        service.markPermanentlyDismissed()
        service.reset()
        XCTAssertNil(service.lastWidgetTap)
        XCTAssertNil(service.lastNudgeShown)
        XCTAssertFalse(service.isPermanentlyDismissed)
    }
}
