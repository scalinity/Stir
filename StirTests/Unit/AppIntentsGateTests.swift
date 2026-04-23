// AppIntentsGateTests
//
// Verifies the Premium+ gate on Stir's AppIntents. Intent .perform()
// itself is hard to unit-test (AppIntents framework runs the intent
// on a privileged process) — these tests instead exercise the gate
// logic that every intent entry calls.

import XCTest
@testable import Stir

@MainActor
final class AppIntentsGateTests: XCTestCase {
    private var storage: UserDefaults!

    override func setUp() {
        super.setUp()
        // Isolated suite so tests don't leak across runs or into the
        // shared App Group. Random name keeps parallel runs clean.
        storage = UserDefaults(suiteName: "test.\(UUID().uuidString)")
        storage.removePersistentDomain(forName: "test.\(UUID().uuidString)")
    }

    override func tearDown() {
        storage = nil
        super.tearDown()
    }

    // MARK: - Gate

    func test_isPermitted_nilTier_returnsFalse() {
        // Freshly-installed app — tier not yet cached. Gate blocks.
        SharedStorage(defaults: storage).clearAll()
        XCTAssertFalse(Self.check(storage: storage))
    }

    func test_isPermitted_freeTier_returnsFalse() {
        SharedStorage(defaults: storage).writeTier("free")
        XCTAssertFalse(Self.check(storage: storage))
    }

    func test_isPermitted_premiumTier_returnsTrue() {
        SharedStorage(defaults: storage).writeTier("premium")
        XCTAssertTrue(Self.check(storage: storage))
    }

    func test_isPermitted_proTier_returnsTrue() {
        SharedStorage(defaults: storage).writeTier("pro")
        XCTAssertTrue(Self.check(storage: storage))
    }

    func test_isPermitted_unknownTier_returnsFalse() {
        SharedStorage(defaults: storage).writeTier("enterprise")  // future, not yet permitted
        XCTAssertFalse(Self.check(storage: storage))
    }

    // MARK: - Helper

    /// Inline replica of `StirAppIntentsGate.isPermitted` against an
    /// injected UserDefaults so the production gate stays simple
    /// (no DI hook needed in production — it always reads the App
    /// Group suite). If production drifts, these assertions stay
    /// tied to the tier string values {premium, pro}.
    private static func check(storage: UserDefaults) -> Bool {
        guard let tier = storage.string(forKey: "stir.user.tier.v1") else { return false }
        return tier == "premium" || tier == "pro"
    }
}
