// PantryListViewModelTests
//
// Coverage for the in-memory list model that drives PantryListView.
// Exercises load, search filter, manual-add quota gate, and ephemeral
// bypassing the cap.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class PantryListViewModelTests: XCTestCase {
    private var pc: PersistenceController!
    private var household: HouseholdProfile!
    private var repo: PantryItemRepository!
    private var entitlements: EntitlementService!

    override func setUp() async throws {
        try await super.setUp()
        pc = PersistenceController(inMemory: true)
        repo = PantryItemRepository(controller: pc)
        let ctx = pc.viewContext
        household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        try ctx.save()
        entitlements = EntitlementService()
        // Free tier (cap 25) is the default state of EntitlementService
        // when no hydrate runs.
        XCTAssertEqual(entitlements.tier, .free)
    }

    override func tearDown() async throws {
        pc = nil
        household = nil
        repo = nil
        entitlements = nil
        try await super.tearDown()
    }

    func test_load_populatesItemsFromRepo() async throws {
        try repo.insertManual(displayName: "olive oil", amountText: nil, on: household)
        try repo.insertManual(displayName: "flour", amountText: nil, on: household)
        let vm = PantryListViewModel(
            household: household,
            repo: repo,
            entitlements: entitlements,
        )
        vm.load()
        XCTAssertEqual(vm.filteredItems.count, 2)
    }

    func test_search_filtersCaseInsensitive() async throws {
        try repo.insertManual(displayName: "Olive Oil", amountText: nil, on: household)
        try repo.insertManual(displayName: "flour", amountText: nil, on: household)
        let vm = PantryListViewModel(
            household: household,
            repo: repo,
            entitlements: entitlements,
        )
        vm.load()
        vm.searchText = "OLIVE"
        XCTAssertEqual(vm.filteredItems.map(\.displayName), ["Olive Oil"])
        vm.searchText = ""
        XCTAssertEqual(vm.filteredItems.count, 2)
    }

    func test_addItem_returnsFalseAtCapWithoutWriting() async throws {
        // Seed 25 items — Free cap (default tier on EntitlementService).
        for i in 0 ..< 25 {
            try repo.insertManual(displayName: "item-\(i)", amountText: nil, on: household)
        }
        let vm = PantryListViewModel(
            household: household,
            repo: repo,
            entitlements: entitlements,
        )
        vm.load()
        XCTAssertEqual(vm.filteredItems.count, 25)

        let ok = vm.addItem(displayName: "over-cap", amountText: nil)
        XCTAssertFalse(ok, "add at-cap returns false")
        vm.load()
        XCTAssertEqual(vm.filteredItems.count, 25, "no row was written")
    }

    func test_addItem_ephemeralBypassesCap() async throws {
        for i in 0 ..< 25 {
            try repo.insertManual(displayName: "item-\(i)", amountText: nil, on: household)
        }
        let vm = PantryListViewModel(
            household: household,
            repo: repo,
            entitlements: entitlements,
        )
        let ok = vm.addItem(displayName: "fresh basil", amountText: nil, memoryState: .ephemeral)
        XCTAssertTrue(ok, "ephemeral items don't count against the standing cap")
    }
}
