// PantryItemRepositoryTests
//
// Coverage for read + manual-write + edit + count APIs added for the
// pantry management surface (ADR 0028). Uses an in-memory persistent
// store via `PersistenceController(inMemory: true)`.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class PantryItemRepositoryTests: XCTestCase {
    private var pc: PersistenceController!
    private var household: HouseholdProfile!
    private var repo: PantryItemRepository!

    override func setUp() async throws {
        try await super.setUp()
        pc = PersistenceController(inMemory: true)
        repo = PantryItemRepository(controller: pc)
        let ctx = pc.viewContext
        household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        try ctx.save()
    }

    override func tearDown() async throws {
        pc = nil
        household = nil
        repo = nil
        try await super.tearDown()
    }

    // MARK: - Read

    func test_fetchAll_returnsRowsExcludingSoftDeleted() throws {
        try seedItem(name: "olive oil", deleted: false)
        try seedItem(name: "flour", deleted: true)
        let rows = try repo.fetchAll(for: household, includeSoftDeleted: false)
        XCTAssertEqual(rows.map(\.displayName), ["olive oil"])
    }

    func test_countRemembered_excludesEphemeralAndDeleted() throws {
        try seedItem(name: "olive oil", memoryState: .remembered)
        try seedItem(name: "garlic", memoryState: .remembered)
        try seedItem(name: "fresh basil", memoryState: .ephemeral)
        try seedItem(name: "stale flour", memoryState: .remembered, deleted: true)
        let count = try repo.countRemembered(for: household)
        XCTAssertEqual(count, 2, "only non-deleted .remembered rows count toward the cap")
    }

    func test_fetchAll_isolatesByHousehold() throws {
        let other = HouseholdProfile(context: pc.viewContext)
        other.id = UUID()
        other.createdAt = Date()
        try pc.viewContext.save()

        try seedItem(name: "ours", deleted: false)
        let ourCount = try repo.fetchAll(for: household).count
        XCTAssertEqual(ourCount, 1)

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
        try pc.viewContext.save()

        XCTAssertEqual(try repo.fetchAll(for: household).map(\.displayName), ["ours"])
        XCTAssertEqual(try repo.fetchAll(for: other).map(\.displayName), ["theirs"])
        XCTAssertEqual(try repo.countRemembered(for: household), 1)
        XCTAssertEqual(try repo.countRemembered(for: other), 1)
    }

    func test_fetchAll_sortsByLastSeenDescThenNameAsc() throws {
        let now = Date()
        try seedItem(name: "older", lastSeenAt: now.addingTimeInterval(-3600))
        try seedItem(name: "alpha-newest", lastSeenAt: now)
        try seedItem(name: "beta-newest", lastSeenAt: now)
        let names = try repo.fetchAll(for: household).map(\.displayName)
        XCTAssertEqual(names, ["alpha-newest", "beta-newest", "older"])
    }

    func test_fetchAll_includeSoftDeleted_surfacesDeletedRows() throws {
        try seedItem(name: "live")
        try seedItem(name: "tombstone", deleted: true)
        let withDeleted = try repo.fetchAll(for: household, includeSoftDeleted: true)
        XCTAssertEqual(Set(withDeleted.map(\.displayName)), ["live", "tombstone"])
    }

    // MARK: - insertManual

    func test_insertManual_persistsRowAndDedupesAgainstExisting() throws {
        let first = try insertedRow(displayName: "olive oil", amount: "1 bottle")
        XCTAssertEqual(first.displayName, "olive oil")
        XCTAssertEqual(first.typedSource, .manual)
        XCTAssertEqual(first.typedMemoryState, .remembered)

        let secondOutcome = try repo.insertManual(
            displayName: "olive oil",
            amountText: "2 bottles",
            memoryState: .remembered,
            on: household,
        )
        guard case .upserted = secondOutcome else {
            return XCTFail("expected .upserted on dedupe; got \(secondOutcome)")
        }
        let rows = try repo.fetchAll(for: household)
        XCTAssertEqual(rows.count, 1, "case-insensitive name dedupe")
        XCTAssertEqual(rows.first?.amountText, "2 bottles", "amount overwrites on dedupe")
    }

    /// Review C5 regression test — manual entry first, then a scan
    /// row with a canonical slug for the same item must dedupe to
    /// the manual row instead of producing a duplicate.
    func test_fetchExisting_slugFallsBackToNameWhenSlugMisses() throws {
        _ = try insertedRow(displayName: "olive oil", amount: nil)
        // Now upsert via the scan path (slug-aware) — should resolve
        // back to the manual row by name fallback.
        let outcome = try repo.upsertFromScan(
            [
                PantryItemRepository.ScanIngredient(
                    displayName: "olive oil",
                    canonicalSlug: "olive_oil",
                    amountText: "1 bottle",
                    confidence: 0.9,
                    parseConfidence: .confirmed,
                ),
            ],
            on: household,
        )
        XCTAssertEqual(outcome.rows.count, 1)
        let allRows = try repo.fetchAll(for: household)
        XCTAssertEqual(allRows.count, 1, "manual + scan dedupe via name fallback")
    }

    /// Review C4 regression test — at-cap re-add of an EXISTING
    /// remembered row must upsert (no row added), not return
    /// `.capReached`.
    func test_insertManual_atCap_reAddingExistingUpsertsInsteadOfPaywall() throws {
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "item-\(i)", amount: nil)
        }
        let outcome = try repo.insertManual(
            displayName: "item-0",
            amountText: nil,
            memoryState: .remembered,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        guard case .upserted = outcome else {
            return XCTFail("at-cap re-add of existing row should upsert; got \(outcome)")
        }
        XCTAssertEqual(try repo.fetchAll(for: household).count, 25, "no new row was created")
    }

    func test_insertManual_atCap_newNameReturnsCapReached() throws {
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "item-\(i)", amount: nil)
        }
        let outcome = try repo.insertManual(
            displayName: "over-cap",
            amountText: nil,
            memoryState: .remembered,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        guard case .capReached = outcome else {
            return XCTFail("new-name at cap should be .capReached; got \(outcome)")
        }
        XCTAssertEqual(try repo.fetchAll(for: household).count, 25, "no row written")
    }

    func test_insertManual_ephemeralBypassesCap() throws {
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "item-\(i)", amount: nil)
        }
        let outcome = try repo.insertManual(
            displayName: "fresh basil",
            amountText: nil,
            memoryState: .ephemeral,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        guard case .inserted = outcome else {
            return XCTFail("ephemeral at cap should insert; got \(outcome)")
        }
    }

    func test_insertManual_throwsValidationOnEmptyDisplayName() throws {
        XCTAssertThrowsError(try repo.insertManual(
            displayName: "   ",
            amountText: nil,
            on: household,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    func test_insertManual_throwsValidationOnOverlongDisplayName() throws {
        let tooLong = String(repeating: "a", count: PantryItemRepository.maxDisplayNameLength + 1)
        XCTAssertThrowsError(try repo.insertManual(
            displayName: tooLong,
            amountText: nil,
            on: household,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    func test_insertManual_throwsValidationOnOverlongAmountText() throws {
        let tooLong = String(repeating: "a", count: PantryItemRepository.maxAmountTextLength + 1)
        XCTAssertThrowsError(try repo.insertManual(
            displayName: "olive oil",
            amountText: tooLong,
            on: household,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    // MARK: - update

    func test_update_setsFieldsAndBumpsUpdatedAt() async throws {
        let row = try insertedRow(displayName: "olive oil", amount: "1 bottle")
        let originalUpdate = row.updatedAt
        try await Task.sleep(nanoseconds: 50_000_000)
        try repo.update(
            row,
            displayName: "extra-virgin olive oil",
            amountText: "2 bottles",
            memoryState: .remembered,
        )
        XCTAssertEqual(row.displayName, "extra-virgin olive oil")
        XCTAssertEqual(row.amountText, "2 bottles")
        XCTAssertGreaterThan(row.updatedAt ?? .distantPast, originalUpdate ?? .distantPast)
    }

    func test_update_throwsValidationOnEmptyDisplayName() throws {
        let row = try insertedRow(displayName: "olive oil", amount: nil)
        XCTAssertThrowsError(try repo.update(
            row,
            displayName: "",
            amountText: nil,
            memoryState: .remembered,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    /// Review W9 — previously asserted `XCTAssertThrowsError` without
    /// inspecting the error case, which would have passed for any
    /// thrown value. Now pattern-matches `.validation`.
    func test_update_throwsValidationOnSoftDeletedItem() throws {
        let row = try insertedRow(displayName: "olive oil", amount: nil)
        try repo.softDelete(row)
        XCTAssertThrowsError(try repo.update(
            row,
            displayName: "EVOO",
            amountText: nil,
            memoryState: .remembered,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    func test_update_throwsValidationOnOverlongDisplayName() throws {
        let row = try insertedRow(displayName: "olive oil", amount: nil)
        let tooLong = String(repeating: "a", count: PantryItemRepository.maxDisplayNameLength + 1)
        XCTAssertThrowsError(try repo.update(
            row,
            displayName: tooLong,
            amountText: nil,
            memoryState: .remembered,
        )) { error in
            guard case StirError.validation = error else {
                XCTFail("expected .validation, got \(error)")
                return
            }
        }
    }

    // MARK: - upsertFromScan cap-aware

    /// Review C1 regression test — `.likelyStaple` rows past the cap
    /// downgrade to `.ephemeral` instead of silently exceeding it.
    func test_upsertFromScan_downgradesStaplesPastCapToEphemeral() throws {
        // Seed up to the cap with manual remembered rows.
        for i in 0 ..< 25 {
            _ = try insertedRow(displayName: "manual-\(i)", amount: nil)
        }
        // Scan adds 3 staples — all would-be `.remembered`.
        let scan = (0 ..< 3).map { i in
            PantryItemRepository.ScanIngredient(
                displayName: "scan-\(i)",
                canonicalSlug: "scan_\(i)",
                amountText: nil,
                confidence: 0.9,
                parseConfidence: .likelyStaple,
            )
        }
        let outcome = try repo.upsertFromScan(
            scan,
            on: household,
            usedRemembered: 25,
            cap: 25,
        )
        XCTAssertEqual(outcome.truncatedToEphemeral, 3)
        XCTAssertEqual(try repo.countRemembered(for: household), 25, "cap respected")
        let scanRows = try repo.fetchAll(for: household).filter { ($0.displayName ?? "").hasPrefix("scan-") }
        XCTAssertEqual(scanRows.count, 3)
        XCTAssertTrue(scanRows.allSatisfy { $0.typedMemoryState == .ephemeral })
    }

    func test_upsertFromScan_belowCapKeepsStaplesRemembered() throws {
        let scan = [
            PantryItemRepository.ScanIngredient(
                displayName: "olive oil",
                canonicalSlug: "olive_oil",
                amountText: nil,
                confidence: 0.9,
                parseConfidence: .likelyStaple,
            ),
        ]
        let outcome = try repo.upsertFromScan(
            scan,
            on: household,
            usedRemembered: 0,
            cap: 25,
        )
        XCTAssertEqual(outcome.truncatedToEphemeral, 0)
        XCTAssertEqual(try repo.countRemembered(for: household), 1)
    }

    // MARK: - Helpers

    /// Unwraps an `InsertManualOutcome.inserted(row)` for tests that
    /// only care about the produced row. Fails the test on any other
    /// outcome — call sites that genuinely want `.upserted` /
    /// `.capReached` switch on the outcome directly.
    private func insertedRow(
        displayName: String,
        amount: String?,
        memoryState: PantryItem.MemoryState = .remembered,
    ) throws -> PantryItem {
        let outcome = try repo.insertManual(
            displayName: displayName,
            amountText: amount,
            memoryState: memoryState,
            on: household,
        )
        switch outcome {
        case .inserted(let row): return row
        case .upserted(let row): return row
        case .capReached:
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected .capReached in insertedRow helper — pass cap arg explicitly to test cap behavior"])
        }
    }

    @discardableResult
    private func seedItem(
        name: String,
        slug: String? = nil,
        memoryState: PantryItem.MemoryState = .remembered,
        deleted: Bool = false,
        lastSeenAt: Date? = nil,
    ) throws -> PantryItem {
        let row = PantryItem(context: pc.viewContext)
        row.id = UUID()
        row.household = household
        row.displayName = name
        row.canonicalIngredientSlug = slug ?? ""
        row.typedSource = .manual
        row.typedMemoryState = memoryState
        row.userConfirmed = true
        row.createdAt = Date()
        row.updatedAt = Date()
        row.lastSeenAt = lastSeenAt ?? Date()
        if deleted { row.deletedAt = Date() }
        try pc.viewContext.save()
        return row
    }
}
