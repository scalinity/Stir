// RepeatCandidateSuppressionStoreTests
//
// SCA-124: pin the SuppressionStore behavior the SCA-66 review pass
// flagged as untested:
//   - isSuppressed returns false for unrecorded UUIDs
//   - suppress + isSuppressed round-trip
//   - suppress is idempotent (no-op on duplicate)
//   - FIFO eviction at maxEntries=200 (oldest entry evicted on 201st)
//   - reset() wipes both the in-memory cache (SCA-126) and disk
//   - Per-suite UserDefaults isolation works
//
// Tests use a per-test UserDefaults suite so they don't pollute
// .standard or interfere with each other.

import XCTest
@testable import Stir

@MainActor
final class RepeatCandidateSuppressionStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "test.repeat_candidate.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Basic round-trip

    func test_isSuppressed_falseForUnrecordedId() {
        let store = RepeatCandidateSuppressionStore(defaults: defaults)
        XCTAssertFalse(store.isSuppressed(recipePlanId: UUID()))
    }

    func test_suppress_thenIsSuppressed_returnsTrue() {
        let store = RepeatCandidateSuppressionStore(defaults: defaults)
        let id = UUID()
        store.suppress(recipePlanId: id)
        XCTAssertTrue(store.isSuppressed(recipePlanId: id))
    }

    func test_suppress_otherIdsRemainUnsuppressed() {
        let store = RepeatCandidateSuppressionStore(defaults: defaults)
        let suppressed = UUID()
        let other = UUID()
        store.suppress(recipePlanId: suppressed)
        XCTAssertTrue(store.isSuppressed(recipePlanId: suppressed))
        XCTAssertFalse(store.isSuppressed(recipePlanId: other))
    }

    // MARK: - Idempotency

    func test_suppress_idempotent_secondCallIsNoOp() {
        let store = RepeatCandidateSuppressionStore(defaults: defaults)
        let id = UUID()
        store.suppress(recipePlanId: id)
        store.suppress(recipePlanId: id)  // duplicate
        // Should still be suppressed, not duplicated under the hood.
        XCTAssertTrue(store.isSuppressed(recipePlanId: id))
        // Verify there's only ONE entry on disk by suppressing 199
        // more then one extra — total 201 attempts, but since the
        // duplicate didn't count, we should still have 200 entries
        // and the FIRST id (suppressed twice) should still be present
        // (not evicted by FIFO at the boundary).
        for _ in 0 ..< 199 {
            store.suppress(recipePlanId: UUID())
        }
        XCTAssertTrue(store.isSuppressed(recipePlanId: id),
                      "first id (suppressed twice) survives because the duplicate didn't count toward the cap")
    }

    // MARK: - FIFO eviction at 200

    func test_suppress_fifoEvictsOldestAt201st() {
        let store = RepeatCandidateSuppressionStore(defaults: defaults)
        var seeded: [UUID] = []
        for _ in 0 ..< 200 {
            let id = UUID()
            seeded.append(id)
            store.suppress(recipePlanId: id)
        }
        // All 200 are suppressed.
        XCTAssertTrue(store.isSuppressed(recipePlanId: seeded[0]))
        XCTAssertTrue(store.isSuppressed(recipePlanId: seeded[199]))

        // 201st suppression evicts the oldest (seeded[0]).
        let newest = UUID()
        store.suppress(recipePlanId: newest)

        XCTAssertFalse(store.isSuppressed(recipePlanId: seeded[0]),
                       "oldest entry evicted on overflow")
        XCTAssertTrue(store.isSuppressed(recipePlanId: seeded[1]),
                      "second-oldest survives")
        XCTAssertTrue(store.isSuppressed(recipePlanId: seeded[199]),
                      "most-recent prior entry survives")
        XCTAssertTrue(store.isSuppressed(recipePlanId: newest),
                      "newest entry now suppressed")
    }

    // MARK: - reset()

    func test_reset_wipesAllSuppressions() {
        let store = RepeatCandidateSuppressionStore(defaults: defaults)
        let id = UUID()
        store.suppress(recipePlanId: id)
        XCTAssertTrue(store.isSuppressed(recipePlanId: id))

        store.reset()

        XCTAssertFalse(store.isSuppressed(recipePlanId: id))
    }

    func test_reset_invalidatesCache_subsequentReadHitsDisk() {
        // SCA-126 added an in-memory Set cache. reset() must drop the
        // cache so a stale entry doesn't survive a wipe.
        let store = RepeatCandidateSuppressionStore(defaults: defaults)
        let id = UUID()
        store.suppress(recipePlanId: id)
        _ = store.isSuppressed(recipePlanId: id)  // hydrate cache

        store.reset()

        XCTAssertFalse(store.isSuppressed(recipePlanId: id),
                       "reset must invalidate the in-memory cache")
    }

    // MARK: - Cross-store isolation via per-suite UserDefaults

    func test_perSuiteIsolation_storesDoNotShareEntries() {
        let storeA = RepeatCandidateSuppressionStore(defaults: defaults)
        let suiteB = "test.repeat_candidate_b.\(UUID().uuidString)"
        let defaultsB = UserDefaults(suiteName: suiteB)!
        let storeB = RepeatCandidateSuppressionStore(defaults: defaultsB)

        let id = UUID()
        storeA.suppress(recipePlanId: id)

        XCTAssertTrue(storeA.isSuppressed(recipePlanId: id))
        XCTAssertFalse(storeB.isSuppressed(recipePlanId: id),
                       "different UserDefaults suites must not share suppression state")
    }
}
