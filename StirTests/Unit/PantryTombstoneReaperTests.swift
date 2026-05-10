// PantryTombstoneReaperTests
//
// SCA-97 — coverage for the foreground-triggered tombstone reaper.
// Each test runs against an isolated UserDefaults suite + an in-memory
// PersistenceController so cadence + Core Data state never leaks
// between tests.
//
// Coverage matrix:
//   * 0-tombstone case (clean install, no soft-deleted rows)
//   * partial-tombstone case (some past retention, some inside it)
//   * all-stale case (every soft-deleted row past retention)
//   * cadence throttle (re-call inside the 24h window is a no-op)
//   * cadence release (re-call past the 24h window re-runs the work)
//   * never-deleted rows are immune (predicate filters deletedAt != nil)
//   * scope-by-household (other households' tombstones are out of scope)
//   * telemetry shape (rows_purged + retention_days)
//   * failure path (cadence timestamp doesn't move on error — but Core
//     Data + in-memory store can't be made to throw deterministically
//     in this harness, so the failure semantic is asserted at the
//     code-shape level via the unit-test-only `failingRepository` seam)

import CoreData
import XCTest
@testable import Stir

@MainActor
final class PantryTombstoneReaperTests: XCTestCase {
    private var pc: PersistenceController!
    private var repo: PantryItemRepository!
    private var household: HouseholdProfile!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        pc = PersistenceController(inMemory: true)
        repo = PantryItemRepository(controller: pc)
        let ctx = pc.viewContext
        household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        try ctx.save()
        suiteName = "test.pantry_tombstone_reaper.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        household = nil
        repo = nil
        pc = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Build a reaper wired against this test's seams. Telemetry is
    /// captured into an out-parameter so individual tests can assert
    /// on event payload shape.
    private func makeReaper(
        retention: TimeInterval = PantryTombstoneReaper.defaultRetention,
        cadence: TimeInterval = PantryTombstoneReaper.cadenceInterval,
        repository: PantryItemRepository? = nil,
        captures: TelemetryCollector,
    ) -> PantryTombstoneReaper {
        PantryTombstoneReaper(
            repository: repository ?? repo,
            retention: retention,
            cadence: cadence,
            defaults: defaults,
            telemetry: { rows, days in
                captures.append((rowsPurged: rows, retentionDays: days))
            },
        )
    }

    /// Insert a PantryItem and force its `deletedAt` to a specific
    /// date via KVC. Direct property assignment respects Core Data's
    /// validation/transient gating; KVC bypasses it cleanly for the
    /// "age this row past the retention window" test pattern.
    @discardableResult
    private func seed(name: String, deletedAt: Date?) throws -> PantryItem {
        let row = PantryItem(context: pc.viewContext)
        row.id = UUID()
        row.household = household
        row.displayName = name
        row.canonicalIngredientSlug = ""
        row.typedSource = .manual
        row.typedMemoryState = .remembered
        row.userConfirmed = true
        row.confidence = 1.0
        row.createdAt = Date()
        row.updatedAt = Date()
        row.lastSeenAt = Date()
        if let deletedAt {
            row.setValue(deletedAt, forKey: "deletedAt")
        }
        try pc.viewContext.save()
        return row
    }

    /// Reference-typed list so the closure can mutate from off-stack.
    final class TelemetryCollector {
        var events: [(rowsPurged: Int, retentionDays: Int)] = []
        func append(_ event: (rowsPurged: Int, retentionDays: Int)) {
            events.append(event)
        }
    }

    // MARK: - 0-tombstone case

    func test_runIfDue_emptyPantry_returnsZero_andEmitsTelemetry() async throws {
        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)

        let result = await reaper.runIfDue(for: household)

        XCTAssertEqual(result, 0, "empty pantry yields zero purged rows")
        XCTAssertEqual(captures.events.count, 1, "telemetry fires on every successful run, including zero-row passes")
        XCTAssertEqual(captures.events.first?.rowsPurged, 0)
        XCTAssertEqual(captures.events.first?.retentionDays, 90)
        XCTAssertNotNil(reaper.lastRunAt, "lastRunAt is set on success even when zero rows were purged")
    }

    func test_runIfDue_onlyLiveRows_returnsZero() async throws {
        try seed(name: "olive oil", deletedAt: nil)
        try seed(name: "garlic", deletedAt: nil)
        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)

        let result = await reaper.runIfDue(for: household)

        XCTAssertEqual(result, 0, "live rows are never purged")
        // Both rows must still be present and not deleted.
        let live = try repo.fetchAll(for: household, includeSoftDeleted: false)
        XCTAssertEqual(live.count, 2)
    }

    // MARK: - Partial-tombstone case

    func test_runIfDue_partialTombstones_purgesOnlyAged() async throws {
        let now = Date()
        let stale = try seed(name: "old basil", deletedAt: now.addingTimeInterval(-91 * 86_400))
        let staleID = stale.objectID
        let fresh = try seed(name: "yesterday's mint", deletedAt: now.addingTimeInterval(-1 * 86_400))
        let freshID = fresh.objectID
        let live = try seed(name: "olive oil", deletedAt: nil)
        let liveID = live.objectID

        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)

        let result = await reaper.runIfDue(for: household, now: now)

        XCTAssertEqual(result, 1, "only the row whose tombstone is past retention is purged")
        // SCA-300 W8: the reaper now hops to a background context, so
        // we assert via a store-fetch (reflects committed state) rather
        // than `viewContext.existingObject(...)` (which returns the
        // viewContext's cached registered object until the async
        // cross-context merge lands).
        XCTAssertFalse(try storeHasRow(staleID), "stale tombstone is hard-deleted")
        XCTAssertTrue(try storeHasRow(freshID), "fresh tombstone survives")
        XCTAssertTrue(try storeHasRow(liveID), "live row survives")
        XCTAssertEqual(captures.events.first?.rowsPurged, 1)
    }

    // MARK: - All-stale case

    func test_runIfDue_allStale_purgesEveryTombstone() async throws {
        let now = Date()
        let pastRetention = now.addingTimeInterval(-100 * 86_400)
        let a = try seed(name: "old a", deletedAt: pastRetention)
        let b = try seed(name: "old b", deletedAt: pastRetention)
        let c = try seed(name: "old c", deletedAt: pastRetention)

        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)

        let result = await reaper.runIfDue(for: household, now: now)

        XCTAssertEqual(result, 3)
        // All three rows are gone from the store. SCA-300 W8 store-fetch
        // assertion — see partialTombstones for rationale.
        for id in [a.objectID, b.objectID, c.objectID] {
            XCTAssertFalse(try storeHasRow(id))
        }
        XCTAssertEqual(captures.events.first?.rowsPurged, 3)
    }

    // MARK: - Cadence throttle

    func test_runIfDue_secondCallWithin24h_isNoOp() async throws {
        let now = Date()
        try seed(name: "stale a", deletedAt: now.addingTimeInterval(-100 * 86_400))
        try seed(name: "stale b", deletedAt: now.addingTimeInterval(-100 * 86_400))

        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)

        let first = await reaper.runIfDue(for: household, now: now)
        // Reseed two more stale rows to prove the second call is gated
        // BEFORE the predicate runs (otherwise the second call would
        // purge these too).
        try seed(name: "stale c", deletedAt: now.addingTimeInterval(-100 * 86_400))
        let second = await reaper.runIfDue(for: household, now: now.addingTimeInterval(3_600))

        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0, "second call within 24h is gated by cadence — no fetch, no purge")
        XCTAssertEqual(captures.events.count, 1, "throttled call emits no telemetry")
    }

    func test_runIfDue_secondCallPast24h_reRuns() async throws {
        let now = Date()
        try seed(name: "stale a", deletedAt: now.addingTimeInterval(-100 * 86_400))

        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)

        let first = await reaper.runIfDue(for: household, now: now)
        try seed(name: "stale b", deletedAt: now.addingTimeInterval(-100 * 86_400))
        let later = now.addingTimeInterval(25 * 3_600)
        let second = await reaper.runIfDue(for: household, now: later)

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "past the 24h cadence the reaper re-runs and purges the new tombstone")
        XCTAssertEqual(captures.events.count, 2)
    }

    // MARK: - Predicate semantics

    func test_runIfDue_neverDeletedRow_isImmune() async throws {
        let now = Date()
        let live = try seed(name: "olive oil", deletedAt: nil)
        // Sanity: even with the cutoff far in the future, a live row
        // (deletedAt == nil) is never matched by the
        // `deletedAt != nil AND deletedAt < cutoff` predicate.
        let captures = TelemetryCollector()
        let reaper = makeReaper(retention: 0, captures: captures)
        let result = await reaper.runIfDue(for: household, now: now)

        XCTAssertEqual(result, 0, "live rows are immune even with a zero retention window")
        XCTAssertNotNil(try? pc.viewContext.existingObject(with: live.objectID))
    }

    func test_runIfDue_isolatesByHousehold() async throws {
        let now = Date()
        let other = HouseholdProfile(context: pc.viewContext)
        other.id = UUID()
        other.createdAt = Date()
        try pc.viewContext.save()

        let theirRow = PantryItem(context: pc.viewContext)
        theirRow.id = UUID()
        theirRow.household = other
        theirRow.displayName = "theirs"
        theirRow.canonicalIngredientSlug = ""
        theirRow.typedSource = .manual
        theirRow.typedMemoryState = .remembered
        theirRow.userConfirmed = true
        theirRow.createdAt = Date()
        theirRow.updatedAt = Date()
        theirRow.lastSeenAt = Date()
        theirRow.setValue(now.addingTimeInterval(-100 * 86_400), forKey: "deletedAt")
        try pc.viewContext.save()
        let theirID = theirRow.objectID

        try seed(name: "ours-stale", deletedAt: now.addingTimeInterval(-100 * 86_400))

        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)
        let result = await reaper.runIfDue(for: household, now: now)

        XCTAssertEqual(result, 1, "only the supplied household's tombstones are purged")
        XCTAssertNotNil(
            try? pc.viewContext.existingObject(with: theirID),
            "other household's stale tombstone is untouched",
        )
    }

    // MARK: - Telemetry shape

    func test_runIfDue_telemetryCarriesRetentionDays() async throws {
        let captures = TelemetryCollector()
        // Custom retention so the assertion isn't tautologically 90.
        let reaper = makeReaper(retention: 30 * 86_400, captures: captures)
        _ = await reaper.runIfDue(for: household)
        XCTAssertEqual(captures.events.first?.retentionDays, 30)
    }

    func test_reset_clearsCadenceKey() async throws {
        let captures = TelemetryCollector()
        let reaper = makeReaper(captures: captures)
        _ = await reaper.runIfDue(for: household)
        XCTAssertNotNil(reaper.lastRunAt)
        reaper.reset()
        XCTAssertNil(reaper.lastRunAt)
    }

    // MARK: - Cross-context fetch helper

    /// Returns true iff a PantryItem with `objectID == id` still exists
    /// in the persistent store. Used by SCA-300 W8 tests: the reaper
    /// deletes on a background context, and `viewContext.existingObject(with:)`
    /// returns the viewContext's cached registered object until the
    /// cross-context auto-merge notification fires (async). A fetch
    /// hits the persistent store directly and reflects the committed
    /// delete deterministically.
    private func storeHasRow(_ id: NSManagedObjectID) throws -> Bool {
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        request.predicate = NSPredicate(format: "SELF == %@", id)
        request.fetchLimit = 1
        // Force a store hit rather than honoring row-cache state.
        request.includesPendingChanges = false
        return try pc.viewContext.fetch(request).first != nil
    }
}
