// AppIntentsGateTests
//
// Verifies the Premium+ gate on Stir's AppIntents. Intent .perform()
// itself is hard to unit-test (AppIntents framework runs the intent
// on a privileged process) — these tests instead exercise the gate
// logic that every intent entry calls.
//
// Pre-fix the tests called an inline `check(storage:)` replica of the
// production `isPermitted` — any drift in production (new tier, key
// rename, enterprise tier) passed the tests while breaking the real
// gate (CR3-11). Now they call the real function through its DI seam.

import XCTest
import Foundation
@testable import Stir

@MainActor
final class AppIntentsGateTests: XCTestCase {
    private var storage: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // Isolated suite so tests don't leak across runs or into the
        // shared App Group. Random name keeps parallel runs clean.
        suiteName = "test.appintents.\(UUID().uuidString)"
        storage = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        storage.removePersistentDomain(forName: suiteName)
        storage = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Gate

    func test_isPermitted_nilTier_returnsFalse() {
        SharedStorage(defaults: storage).clearAll()
        XCTAssertFalse(StirAppIntentsGate.isPermitted(storage: Stir.SharedStorage(defaults: storage)))
    }

    func test_isPermitted_freeTier_returnsFalse() {
        SharedStorage(defaults: storage).writeTier("free")
        XCTAssertFalse(StirAppIntentsGate.isPermitted(storage: Stir.SharedStorage(defaults: storage)))
    }

    func test_isPermitted_premiumTier_returnsTrue() {
        SharedStorage(defaults: storage).writeTier("premium")
        XCTAssertTrue(StirAppIntentsGate.isPermitted(storage: Stir.SharedStorage(defaults: storage)))
    }

    func test_isPermitted_proTier_returnsTrue() {
        SharedStorage(defaults: storage).writeTier("pro")
        XCTAssertTrue(StirAppIntentsGate.isPermitted(storage: Stir.SharedStorage(defaults: storage)))
    }

    func test_isPermitted_unknownTier_returnsFalse() {
        SharedStorage(defaults: storage).writeTier("enterprise")
        XCTAssertFalse(StirAppIntentsGate.isPermitted(storage: Stir.SharedStorage(defaults: storage)))
    }

    // MARK: - recordInvocation telemetry

    func test_recordInvocation_emitsShortcutRun() {
        let spy = SpyPostHog()
        StirAppIntentsGate.recordInvocation("ShowTonightsIdea", analytics: spy)
        XCTAssertEqual(spy.captures.count, 1)
        XCTAssertEqual(spy.captures.first?.event, "shortcut_run")
        XCTAssertEqual(
            spy.captures.first?.properties["intent_name"] as? String,
            "ShowTonightsIdea",
        )
    }

    func test_recordInvocation_firesOnEveryCall_evenWhenGateBlocked() {
        // Gate-blocked invocations still emit so the conversion funnel
        // sees the "Free user tried the shortcut" signal.
        let spy = SpyPostHog()
        SharedStorage(defaults: storage).writeTier("free")
        XCTAssertFalse(StirAppIntentsGate.isPermitted(storage: Stir.SharedStorage(defaults: storage)))
        StirAppIntentsGate.recordInvocation("AddToGrocery", analytics: spy)
        XCTAssertEqual(spy.captures.count, 1)
        XCTAssertEqual(spy.captures.first?.properties["intent_name"] as? String, "AddToGrocery")
    }
}

// MARK: - SpyPostHog

/// Test-local PostHogClient spy. Subclasses PostHogClient via the
/// `#if DEBUG` `init(testingOnly:)` protected init so production builds
/// can't accidentally construct one. Mirrors the shape in
/// SubstitutionSheetViewModelTests — kept private-per-file until a
/// shared test helper module lands.
private final class SpyPostHog: PostHogClient, @unchecked Sendable {
    struct Capture: Sendable {
        let event: String
        let properties: [String: Any]
    }
    private let lock = NSLock()
    private var _captures: [Capture] = []
    var captures: [Capture] {
        lock.lock(); defer { lock.unlock() }
        return _captures
    }
    init() {
        super.init(testingOnly: true)
    }
    override func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        _captures.append(Capture(event: event.rawValue, properties: properties))
    }
}
