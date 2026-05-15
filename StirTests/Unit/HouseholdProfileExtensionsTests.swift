// HouseholdProfileExtensionsTests
//
// Unit tests for `HouseholdProfile.confirmedActivePantry()` — the
// canonical pantry filter introduced in SCA-431 to consolidate the
// `deletedAt == nil && userConfirmed` predicate that voice, substitution
// (sheet + realtime-function-call), and grocery all use.
//
// Pre-SCA-431 each AI invocation site had its own inline `.filter`. The
// substitution sheet's predicate diverged ("only non-empty displayName")
// and shipped soft-deleted + unconfirmed pantry rows to the model,
// producing the "Use the baguette slices from your pantry"
// hallucination against an empty pantry (SCA-424). Centralising the
// filter to `confirmedActivePantry()` and pinning it here prevents the
// next drift before it starts.
//
// This single test file replaces what would otherwise have been two
// separate suites in `SubstitutionSheetViewModelTests` AND
// `GroceryViewModelTests` — both call sites delegate to the same helper
// now, so one symmetric pin covers them both.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class HouseholdProfileExtensionsTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        household = try repo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
    }

    // MARK: - confirmedActivePantry() — the SCA-431 canonical filter

    func test_confirmedActivePantry_excludesSoftDeletedItems_SCA431() throws {
        try seedPantry([
            (name: "olive oil", deletedAt: nil, userConfirmed: true),
            (name: "ghost baguette", deletedAt: Date(), userConfirmed: true),
        ])
        let result = household.confirmedActivePantry()
        let names = result.compactMap { $0.displayName }
        XCTAssertEqual(names.sorted(), ["olive oil"],
                       "soft-deleted rows must be excluded — they vanished from the user's pantry UI and must vanish from AI context too")
    }

    func test_confirmedActivePantry_excludesUnconfirmedItems_SCA431() throws {
        try seedPantry([
            (name: "olive oil", deletedAt: nil, userConfirmed: true),
            (name: "scan-junk row", deletedAt: nil, userConfirmed: false),
        ])
        let result = household.confirmedActivePantry()
        let names = result.compactMap { $0.displayName }
        XCTAssertEqual(names.sorted(), ["olive oil"],
                       "unconfirmed scan-parse rows must be excluded — the user never accepted them as actually being in their pantry")
    }

    func test_confirmedActivePantry_includesConfirmedActiveItems_SCA431() throws {
        try seedPantry([
            (name: "olive oil", deletedAt: nil, userConfirmed: true),
            (name: "kosher salt", deletedAt: nil, userConfirmed: true),
        ])
        let result = household.confirmedActivePantry()
        let names = Set(result.compactMap { $0.displayName })
        XCTAssertEqual(names, ["olive oil", "kosher salt"],
                       "the filter must not over-exclude — confirmed non-deleted rows MUST reach the AI prompt")
    }

    func test_confirmedActivePantry_excludesBothDeletedAndUnconfirmed_SCA431() throws {
        // Combined regression: a row that's BOTH soft-deleted AND
        // unconfirmed (the scan-junk that was never confirmed AND then
        // tombstoned). Must still be excluded — both predicates fail.
        try seedPantry([
            (name: "olive oil", deletedAt: nil, userConfirmed: true),
            (name: "double-doomed", deletedAt: Date(), userConfirmed: false),
        ])
        let result = household.confirmedActivePantry()
        let names = result.compactMap { $0.displayName }
        XCTAssertEqual(names.sorted(), ["olive oil"])
    }

    func test_confirmedActivePantry_emptyHousehold_returnsEmpty_SCA431() throws {
        let result = household.confirmedActivePantry()
        XCTAssertEqual(result.count, 0,
                       "household with no pantry items returns empty array, not crashes")
    }

    // MARK: - Helpers

    private func seedPantry(_ items: [(name: String, deletedAt: Date?, userConfirmed: Bool)]) throws {
        let context = controller.viewContext
        for item in items {
            let row = PantryItem(context: context)
            row.id = UUID()
            row.household = household
            row.displayName = item.name
            row.canonicalIngredientSlug = nil
            row.deletedAt = item.deletedAt
            row.userConfirmed = item.userConfirmed
            row.typedMemoryState = .remembered
            row.createdAt = Date()
            row.updatedAt = Date()
        }
        try controller.save()
    }
}
