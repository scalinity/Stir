// StirNotificationDelegateTests
//
// SCA-365 (CR3 W7 + DB1 W3): pin the SCA-318 NotificationKind enum
// (the typed dispatch surface). UNNotification has no public initializer
// so the per-kind dedupe / NotificationKind dispatch path is exercised
// indirectly: this file tests the parser the dispatch loop is built
// on, and pins the wire-contract raw values that must match each
// scheduler's userInfo writes.
//
// The full @MainActor + nonisolated UN-delegate plumbing is currently
// observable only via integration paths (real UNUserNotificationCenter
// delivery during XCUITests, or via the kit's per-scheduler tests).
// Pinning the parser here closes the most common drift footgun: a typo
// in either a scheduler's userInfo write or this enum's raw value.

import XCTest
@testable import Stir

final class StirNotificationDelegateTests: XCTestCase {
    // MARK: - NotificationKind raw-value contract (wire surface)

    /// SCA-318 wire contract: each enum case's raw value MUST match the
    /// literal each scheduler writes into `userInfo["stir_notification_kind"]`.
    /// Drift on either side silently breaks `*_fired` telemetry emission
    /// (the delegate's NotificationKind.from(_:) returns nil → guard-bail
    /// in emitTelemetryIfNeeded).
    func test_notificationKind_rawValues_matchSchedulerLiterals() {
        XCTAssertEqual(NotificationKind.reactivation.rawValue, "reactivation")
        XCTAssertEqual(NotificationKind.leftoversFollowup.rawValue, "leftovers_followup")
        XCTAssertEqual(NotificationKind.useSoon.rawValue, "use_soon")
    }

    /// Sanity: enum is `CaseIterable` so a future kind-add is auto-discoverable
    /// (the `for kind in NotificationKind.allCases` pattern would pick it up
    /// at any iteration site).
    func test_notificationKind_caseIterable_hasThreeCases() {
        XCTAssertEqual(NotificationKind.allCases.count, 3)
        XCTAssertEqual(
            Set(NotificationKind.allCases.map(\.rawValue)),
            ["reactivation", "leftovers_followup", "use_soon"],
        )
    }

    // MARK: - NotificationKind.from(_:) parser

    /// Happy path: each rawValue is recognized.
    func test_notificationKind_from_recognizesValidKinds() {
        XCTAssertEqual(NotificationKind.from(["stir_notification_kind": "reactivation"]), .reactivation)
        XCTAssertEqual(NotificationKind.from(["stir_notification_kind": "leftovers_followup"]), .leftoversFollowup)
        XCTAssertEqual(NotificationKind.from(["stir_notification_kind": "use_soon"]), .useSoon)
    }

    /// Missing key → nil (delegate's emitTelemetryIfNeeded then bails).
    func test_notificationKind_from_missingKey_returnsNil() {
        XCTAssertNil(NotificationKind.from([:]))
        XCTAssertNil(NotificationKind.from(["other_key": "value"]))
    }

    /// Unknown rawValue → nil (a future kind not yet enumerated here
    /// silently no-ops rather than crashing).
    func test_notificationKind_from_unknownValue_returnsNil() {
        XCTAssertNil(NotificationKind.from(["stir_notification_kind": "future_kind"]))
    }

    /// Non-string value → nil (defensive against userInfo poisoning by a
    /// future caller writing the wrong type).
    func test_notificationKind_from_nonStringValue_returnsNil() {
        XCTAssertNil(NotificationKind.from(["stir_notification_kind": 42]))
        XCTAssertNil(NotificationKind.from(["stir_notification_kind": NSNull()]))
    }
}
