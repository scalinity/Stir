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
        let store = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.leftovers_followup.history.v1",
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
        )
        store.recordScheduled(fireAt: Date().addingTimeInterval(-3 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-10 * 86_400))  // outside window
        let recent = store.firesInLastWeek(asOf: Date())
        XCTAssertEqual(recent.count, 2)
    }

    func test_historyStore_unactionedStreakSetsSuppression() {
        let store = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.leftovers_followup.history.v1",
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
        )
        store.recordScheduled(fireAt: Date().addingTimeInterval(-2 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        XCTAssertNil(store.suppressedUntil, "two unactioned in history; the THIRD scheduling triggers suppression")
        store.recordScheduled(fireAt: Date())
        XCTAssertNotNil(store.suppressedUntil, "third schedule with prior 2 unactioned must arm 14d suppression")
    }

    func test_historyStore_actionClearsSuppression() {
        let store = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.leftovers_followup.history.v1",
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
        )
        store.recordScheduled(fireAt: Date().addingTimeInterval(-2 * 86_400))
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        store.recordScheduled(fireAt: Date())  // suppression armed
        XCTAssertNotNil(store.suppressedUntil)
        store.markMostRecentActioned(at: Date())
        XCTAssertNil(store.suppressedUntil, "user engaged — clear suppression")
    }

    /// SCA-376 + SCA-418: `markMostRecentActioned` clears the
    /// suppression key UNCONDITIONALLY, even when history is empty.
    /// Pre-SCA-376 the unconditional clear sat behind the
    /// `guard let last = entries.indices.last else { return }` so an
    /// empty-history call (e.g. SCA-317 use-soon card-tap routing
    /// after a defaults reset) silently left the suppression armed.
    /// SCA-418 pins the contract so a future "optimization" that
    /// reverts the order surfaces in tests immediately.
    func test_historyStore_markMostRecentActioned_emptyHistory_clearsSuppression() {
        let store = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.leftovers_followup.history.v1",
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
        )
        // Arm suppression manually (no history entries).
        defaults.set(
            Date().addingTimeInterval(7 * 86_400),
            forKey: "stir.leftovers_followup.suppressed_until.v1",
        )
        XCTAssertNotNil(store.suppressedUntil, "precondition: suppression manually armed")
        XCTAssertEqual(store.firesInLastWeek(asOf: Date()).count, 0, "precondition: history empty")

        // SCA-376 contract: clears suppression even though entries.last is nil.
        store.markMostRecentActioned(at: Date())
        XCTAssertNil(
            store.suppressedUntil,
            "SCA-376/SCA-418: markMostRecentActioned must clear suppression UNCONDITIONALLY (empty-history path).",
        )
    }

    func test_historyStore_actionedRunResetsStreak() {
        let store = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.leftovers_followup.history.v1",
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
        )
        store.recordScheduled(fireAt: Date().addingTimeInterval(-3 * 86_400))
        store.markMostRecentActioned(at: Date())
        store.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        // One unactioned + one actioned in history; third schedule must NOT arm suppression
        // (the prior-2 streak check only arms when both are unactioned).
        store.recordScheduled(fireAt: Date())
        XCTAssertNil(store.suppressedUntil, "actioned entry breaks the unactioned streak")
    }

    // MARK: - SCA-374: decode failure telemetry

    func test_historyStore_decodeFailure_emitsTelemetryAndReturnsEmpty() {
        // Pre-populate the stateKey with garbage so JSONDecoder throws on
        // load(). Asserts the SCA-374 contract: load() returns [] AND
        // captures `notification_history_decode_failed` with both the
        // discriminating state_key AND a closed-vocab error_reason.
        // SCA-398: property is `error_reason` (HistoryDecodeErrorReason
        // rawValue) not raw `error_description`.
        let stateKey = "stir.leftovers_followup.history.v1"
        defaults.set(Data([0x00, 0xFF, 0x42, 0x99]), forKey: stateKey)
        let spy = SpyPostHogForHistory()
        let store = NotificationHistoryStore(
            defaults: defaults,
            stateKey: stateKey,
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
            telemetry: spy,
        )
        let recent = store.firesInLastWeek(asOf: Date())
        XCTAssertEqual(recent.count, 0, "decode failure must reset to []")
        XCTAssertEqual(spy.captured.count, 1, "decode failure must emit exactly once")
        XCTAssertEqual(spy.captured.first?.event, .notificationHistoryDecodeFailed)
        XCTAssertEqual(spy.captured.first?.properties["state_key"] as? String, stateKey)
        // SCA-398: must be a closed-vocab rawValue, not a raw description.
        let reason = spy.captured.first?.properties["error_reason"] as? String
        XCTAssertNotNil(reason)
        if let reason {
            XCTAssertTrue(
                HistoryDecodeErrorReason.allCases.map(\.rawValue).contains(reason),
                "SCA-398: error_reason must be a HistoryDecodeErrorReason rawValue (closed-vocab); got \(reason)",
            )
        }
        // Negative half: pre-fix this property was `error_description`. The
        // closed-vocab rename is a wire-contract change; the old key should
        // never appear post-SCA-398.
        XCTAssertNil(
            spy.captured.first?.properties["error_description"],
            "SCA-398: error_description property removed in favor of error_reason",
        )
    }

    /// SCA-398: HistoryDecodeErrorReason.classify maps each
    /// DecodingError case to its corresponding closed-vocab rawValue.
    /// Anything non-DecodingError → `.unknown`.
    func test_historyDecodeErrorReason_classify_knownAndUnknown() {
        let ctx = DecodingError.Context(codingPath: [], debugDescription: "test")
        XCTAssertEqual(
            HistoryDecodeErrorReason.classify(DecodingError.dataCorrupted(ctx)),
            .dataCorrupted,
        )
        let key = TestCodingKey(stringValue: "fireAt")!
        XCTAssertEqual(
            HistoryDecodeErrorReason.classify(DecodingError.keyNotFound(key, ctx)),
            .keyNotFound,
        )
        XCTAssertEqual(
            HistoryDecodeErrorReason.classify(DecodingError.typeMismatch(Date.self, ctx)),
            .typeMismatch,
        )
        XCTAssertEqual(
            HistoryDecodeErrorReason.classify(DecodingError.valueNotFound(Bool.self, ctx)),
            .valueNotFound,
        )
        XCTAssertEqual(
            HistoryDecodeErrorReason.classify(NSError(domain: "test.synthetic", code: 1)),
            .unknown,
        )
    }

    func test_historyStore_validBlob_doesNotEmitDecodeFailure() {
        // Round-trip a real entry so load() succeeds. Asserts the
        // negative half of the SCA-374 contract: a healthy decode path
        // emits ZERO `notification_history_decode_failed` events.
        let stateKey = "stir.leftovers_followup.history.v1"
        let spy = SpyPostHogForHistory()
        let store = NotificationHistoryStore(
            defaults: defaults,
            stateKey: stateKey,
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
            telemetry: spy,
        )
        store.recordScheduled(fireAt: Date())
        _ = store.firesInLastWeek(asOf: Date())
        XCTAssertTrue(
            spy.captured.allSatisfy { $0.event != .notificationHistoryDecodeFailed },
            "successful decode must NOT emit decode-failed telemetry",
        )
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

// MARK: - Test spy

/// SCA-374 — minimal PostHog spy that records `capture(_:properties:)`
/// invocations. Subclasses `PostHogClient` via the DEBUG `init(testingOnly:)`
/// seam so production code sees a real-looking client (no protocol leakage)
/// while tests can assert on `captured`.
private final class SpyPostHogForHistory: PostHogClient, @unchecked Sendable {
    struct Captured { let event: TelemetryEvent; let properties: [String: Any] }
    private(set) var captured: [Captured] = []
    init() { super.init(testingOnly: true) }
    override func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        captured.append(Captured(event: event, properties: properties))
    }
}

/// SCA-398 — test-only `CodingKey` so we can build a
/// `DecodingError.keyNotFound` without dragging in a real Codable
/// value type.
private struct TestCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}
