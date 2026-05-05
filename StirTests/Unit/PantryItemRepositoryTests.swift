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
    }

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

    func test_insertManual_persistsRowAndDedupesAgainstExisting() throws {
        let first = try repo.insertManual(
            displayName: "olive oil",
            amountText: "1 bottle",
            memoryState: .remembered,
            on: household,
        )
        XCTAssertEqual(first.displayName, "olive oil")
        XCTAssertEqual(first.typedSource, .manual)
        XCTAssertEqual(first.typedMemoryState, .remembered)

        _ = try repo.insertManual(
            displayName: "olive oil",
            amountText: "2 bottles",
            memoryState: .remembered,
            on: household,
        )
        let rows = try repo.fetchAll(for: household)
        XCTAssertEqual(rows.count, 1, "case-insensitive name dedupe")
        XCTAssertEqual(rows.first?.amountText, "2 bottles", "amount overwrites on dedupe")
    }

    func test_update_setsFieldsAndBumpsUpdatedAt() async throws {
        let row = try repo.insertManual(
            displayName: "olive oil",
            amountText: "1 bottle",
            on: household,
        )
        let originalUpdate = row.updatedAt
        try await Task.sleep(nanoseconds: 10_000_000)
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

    @discardableResult
    private func seedItem(
        name: String,
        slug: String? = nil,
        memoryState: PantryItem.MemoryState = .remembered,
        deleted: Bool = false,
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
        row.lastSeenAt = Date()
        if deleted { row.deletedAt = Date() }
        try pc.viewContext.save()
        return row
    }
}
