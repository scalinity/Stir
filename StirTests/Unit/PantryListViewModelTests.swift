// PantryListViewModelTests
//
// Coverage for the in-memory list model that drives PantryListView.
// Exercises load, search filter, manual-add quota gate, ephemeral
// bypass, edit/delete happy + failure paths, last-row-empty fallback,
// and rememberedCount projection.

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
        entitlements = EntitlementService(keychain: MockKeychain())
        // Free tier (cap 25) is the default state of EntitlementService
        // when no hydrate runs. MockKeychain ensures no cached snapshot
        // from a prior test or live build leaks tier=.premium/.pro and
        // silently degrades the cap-boundary test.
        XCTAssertEqual(entitlements.tier, .free)
    }

    override func tearDown() async throws {
        pc = nil
        household = nil
        repo = nil
        entitlements = nil
        try await super.tearDown()
    }

    // MARK: - load + search

    func test_load_populatesItemsFromRepo() async throws {
        try seedManual("olive oil")
        try seedManual("flour")
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.filteredItems.count, 2)
    }

    func test_search_filtersCaseInsensitive() async throws {
        try seedManual("Olive Oil")
        try seedManual("flour")
        let vm = makeVM()
        vm.load()
        vm.searchText = "OLIVE"
        XCTAssertEqual(vm.filteredItems.map(\.displayName), ["Olive Oil"])
        vm.searchText = ""
        XCTAssertEqual(vm.filteredItems.count, 2)
    }

    // MARK: - addItem

    func test_addItem_succeedsBelowCapAndReloads() async throws {
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.items.count, 0)
        let result = vm.addItem(displayName: "olive oil", amountText: "1 bottle")
        XCTAssertEqual(result, .added)
        XCTAssertEqual(vm.items.count, 1, "vm.load() ran after success")
        XCTAssertEqual(vm.items.first?.displayName, "olive oil")
    }

    func test_addItem_returnsCapReachedAtCapWithoutWriting() async throws {
        for i in 0 ..< 25 {
            try seedManual("item-\(i)")
        }
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.filteredItems.count, 25)

        let result = vm.addItem(displayName: "over-cap", amountText: nil)
        XCTAssertEqual(result, .capReached, "add at-cap returns .capReached")
        vm.load()
        XCTAssertEqual(vm.filteredItems.count, 25, "no row was written")
    }

    func test_addItem_ephemeralBypassesCap() async throws {
        for i in 0 ..< 25 {
            try seedManual("item-\(i)")
        }
        let vm = makeVM()
        let result = vm.addItem(displayName: "fresh basil", amountText: nil, memoryState: .ephemeral)
        XCTAssertEqual(result, .added, "ephemeral items don't count against the standing cap")
    }

    func test_addItem_atCap_reAddingExistingRoutesToAddedNotCapReached() async throws {
        // Review C4: re-typing an existing remembered name at cap
        // upserts (no row added) instead of being routed to paywall.
        for i in 0 ..< 25 {
            try seedManual("item-\(i)")
        }
        let vm = makeVM()
        let result = vm.addItem(displayName: "item-0", amountText: "2 bottles")
        XCTAssertEqual(result, .added, "at-cap re-add of existing remembered row should upsert")
        vm.load()
        XCTAssertEqual(vm.items.count, 25, "no new row created")
    }

    func test_addItem_failedSetsErrorMessageAndEvent() async throws {
        // An empty-after-trim displayName routes through repo's
        // .validation guard → caught by the VM → .failed +
        // errorMessage set. View routes to a toast.
        let vm = makeVM()
        let result = vm.addItem(displayName: "   ", amountText: nil)
        XCTAssertEqual(result, .failed)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNotNil(vm.errorEvent, "errorEvent UUID stamped for toast re-fire")
    }

    // MARK: - editItem

    func test_editItem_updatesRowAndReloads() async throws {
        let row = try seedManual("olive oil", amount: "1 bottle")
        let vm = makeVM()
        vm.load()
        let ok = vm.editItem(
            row,
            displayName: "extra-virgin olive oil",
            amountText: "2 bottles",
            memoryState: .remembered,
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(row.displayName, "extra-virgin olive oil")
        XCTAssertEqual(row.amountText, "2 bottles")
    }

    func test_editItem_nilMemoryStatePreservesOriginal() async throws {
        // Review C3: passing memoryState=nil means "preserve the row's
        // existing memoryState" — used by PantryEditSheet when the
        // user didn't move the segmented picker. Without this, an
        // .expired row that was merely renamed would silently flip to
        // .remembered.
        let row = try seedManual("stale flour", memoryState: .expired)
        let vm = makeVM()
        vm.load()
        let ok = vm.editItem(
            row,
            displayName: "stale flour (renamed)",
            amountText: nil,
            memoryState: nil,
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(row.typedMemoryState, .expired, "untouched picker preserves original state")
        XCTAssertEqual(row.displayName, "stale flour (renamed)")
    }

    func test_editItem_failedSetsErrorMessage() async throws {
        let row = try seedManual("olive oil")
        let vm = makeVM()
        let ok = vm.editItem(
            row,
            displayName: "",  // triggers .validation
            amountText: nil,
            memoryState: .remembered,
        )
        XCTAssertFalse(ok)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNotNil(vm.errorEvent)
    }

    // MARK: - deleteItem

    func test_deleteItem_softDeletesAndReloads() async throws {
        let row = try seedManual("olive oil")
        try seedManual("flour")
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.items.count, 2)
        let ok = vm.deleteItem(row)
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.items.count, 1, "soft-deleted row dropped from list")
        XCTAssertEqual(vm.items.first?.displayName, "flour")
    }

    func test_deleteItem_emptiesListWhenLastRowRemoved() async throws {
        let row = try seedManual("olive oil")
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertTrue(vm.deleteItem(row))
        XCTAssertTrue(vm.items.isEmpty, "empty-state fallback triggers when last row removed")
    }

    // MARK: - rememberedCount projection

    func test_rememberedCount_excludesEphemeralAndExpiredFromHeader() async throws {
        // Review C2: header used to show vm.items.count which
        // includes ephemeral/expired/unknown. rememberedCount mirrors
        // the cap predicate so the header doesn't lie.
        try seedManual("standing-1", memoryState: .remembered)
        try seedManual("standing-2", memoryState: .remembered)
        try seedManual("today-1", memoryState: .ephemeral)
        try seedManual("expired-1", memoryState: .expired)
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.items.count, 4, "items includes everything non-deleted")
        XCTAssertEqual(vm.rememberedCount, 2, "rememberedCount mirrors cap predicate")
    }

    // MARK: - errorEvent reset

    func test_errorMessage_resetsAtHeadOfNextMutation() async throws {
        let vm = makeVM()
        // First, induce a failure.
        _ = vm.addItem(displayName: "  ", amountText: nil)
        XCTAssertNotNil(vm.errorMessage)
        // A subsequent successful mutation clears the prior error.
        let result = vm.addItem(displayName: "olive oil", amountText: nil)
        XCTAssertEqual(result, .added)
        XCTAssertNil(vm.errorMessage, "successful mutation clears stale errorMessage")
    }

    // MARK: - Helpers

    private func makeVM() -> PantryListViewModel {
        PantryListViewModel(
            household: household,
            repo: repo,
            entitlements: entitlements,
            sentry: NoOpSentryReporter(),
        )
    }

    @discardableResult
    private func seedManual(
        _ name: String,
        amount: String? = nil,
        memoryState: PantryItem.MemoryState = .remembered,
    ) throws -> PantryItem {
        // For .expired, can't go through insertManual (the sheet
        // doesn't expose .expired); seed via direct CD insert
        // matching what fetchAll sees.
        if memoryState == .expired {
            let row = PantryItem(context: pc.viewContext)
            row.id = UUID()
            row.household = household
            row.displayName = name
            row.canonicalIngredientSlug = ""
            row.amountText = amount
            row.confidence = 1.0
            row.userConfirmed = true
            row.typedSource = .manual
            row.typedMemoryState = .expired
            row.lastSeenAt = Date()
            row.createdAt = Date()
            row.updatedAt = Date()
            try pc.viewContext.save()
            return row
        }
        let outcome = try repo.insertManual(
            displayName: name,
            amountText: amount,
            memoryState: memoryState,
            on: household,
        )
        switch outcome {
        case .inserted(let row): return row
        case .upserted(let row): return row
        case .capReached:
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "unexpected .capReached in seedManual — seed beneath the cap"])
        }
    }
}
