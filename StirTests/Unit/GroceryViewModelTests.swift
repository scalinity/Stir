// GroceryViewModelTests
//
// Unit tests focused on VM state machine + aisle-grouping logic.
// Network-path tests (grocery-generate streaming, Reminders EventKit
// export) live in the backend Deno suite + device manual verification
// — EKEventStore + real network are outside unit-test scope.
//
// SCA-191 W1 footgun reminder: `GroceryViewModel` still defaults its
// `groceryRepo` parameter to `GroceryRepository(controller: .shared)`
// (default-arg expression, not nil-fallback — so the SCA-189 closure
// doesn't apply here). A test that omits `groceryRepo:` silently
// writes to `.shared` even when the rest of the VM was wired to a
// custom controller. Until that VM signature is tightened (could be
// a follow-up if needed), every GroceryViewModel construction in
// THIS file must pass `groceryRepo: GroceryRepository(controller:
// controller)`. The seedRecipePlan helper returns the controller
// alongside the seeded objects so callers can wire the pair
// without re-creating the controller. SCA-180 hardened this on
// 2026-05-08 after the original SCA-179 import crash.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class GroceryViewModelTests: XCTestCase {
    // MARK: - Initial state

    func test_initialStage_isGenerating() throws {
        let (plan, household, controller) = try seedRecipePlan(ingredients: [("Rice", "rice", "1 cup")])
        let vm = GroceryViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
            groceryRepo: GroceryRepository(controller: controller),
        )
        XCTAssertEqual(vm.stage, .generating)
        XCTAssertNil(vm.list, "list only materializes after successful generate")
        XCTAssertEqual(vm.missingCount, 0)
        XCTAssertTrue(vm.groupedItems.isEmpty)
    }

    // MARK: - Grouping

    func test_groupedItems_sortsByAisleOrder() throws {
        // Hand-build a GroceryList with items across 4 aisles to verify
        // ordering: produce (0) → meat (1) → dairy (2) → frozen (3) →
        // pantry (4) → other (5). Inserted in non-aisle order; must come
        // out aisle-sorted.
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.viewContext
        let household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        household.servingsDefault = 2

        let plan = RecipePlan(context: ctx)
        plan.id = UUID()
        plan.title = "Sheet pan salmon"
        plan.createdAt = Date()
        try ctx.save()

        let list = GroceryList(context: ctx)
        list.id = UUID()
        list.household = household
        list.createdAt = Date()
        list.setStatus(.draft)
        for (idx, (name, cat)) in [
            ("Pastina", GroceryCategory.pantry),
            ("Kale", GroceryCategory.produce),
            ("Parm", GroceryCategory.dairy),
            ("Salmon", GroceryCategory.meat),
        ].enumerated() {
            let row = GroceryItem(context: ctx)
            row.id = UUID()
            row.list = list
            row.displayName = name
            row.setCategory(cat)
            row.setPriority(.normal)
            row.sortOrder = Int16(idx)
        }
        try ctx.save()

        let vm = GroceryViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
            groceryRepo: GroceryRepository(controller: controller),
        )
        vm._debugApplyReady(list: list)

        XCTAssertEqual(vm.stage, .ready)
        XCTAssertEqual(vm.missingCount, 4)

        let groups = vm.groupedItems.map(\.category)
        XCTAssertEqual(
            groups,
            [.produce, .meat, .dairy, .pantry],
            "groups ordered by GroceryCategory.aisleOrder (produce=0, meat=1, dairy=2, pantry=4)",
        )
    }

    func test_groupedItems_skipsEmptyCategories() throws {
        // Only one category populated; other categories should NOT appear
        // as empty section headers.
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.viewContext
        let household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()

        let plan = RecipePlan(context: ctx)
        plan.id = UUID()
        plan.title = "Simple"
        plan.createdAt = Date()

        let list = GroceryList(context: ctx)
        list.id = UUID()
        list.household = household
        list.createdAt = Date()
        list.setStatus(.draft)
        let row = GroceryItem(context: ctx)
        row.id = UUID()
        row.list = list
        row.displayName = "Kale"
        row.setCategory(.produce)
        row.setPriority(.normal)
        row.sortOrder = 0
        try ctx.save()

        let vm = GroceryViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
            groceryRepo: GroceryRepository(controller: controller),
        )
        vm._debugApplyReady(list: list)

        XCTAssertEqual(vm.groupedItems.map(\.category), [.produce])
        XCTAssertEqual(vm.groupedItems.count, 1, "no empty section headers for unpopulated aisles")
    }

    // MARK: - Reminders title helper

    func test_reminderTitle_concatenatesQuantityWhenPresent() {
        let item = GroceryRemindersService.InputItem(
            id: UUID(), displayName: "Salmon fillets", quantityText: "2",
        )
        XCTAssertEqual(GroceryRemindersService.reminderTitle(for: item), "Salmon fillets — 2")
    }

    func test_reminderTitle_omitsQuantityWhenEmptyOrWhitespace() {
        let nilQty = GroceryRemindersService.InputItem(
            id: UUID(), displayName: "Parmesan", quantityText: nil,
        )
        let whitespace = GroceryRemindersService.InputItem(
            id: UUID(), displayName: "Parmesan", quantityText: "   ",
        )
        XCTAssertEqual(GroceryRemindersService.reminderTitle(for: nilQty), "Parmesan")
        XCTAssertEqual(GroceryRemindersService.reminderTitle(for: whitespace), "Parmesan")
    }

    // MARK: - Helpers

    private func seedRecipePlan(
        ingredients: [(String, String?, String?)],
    ) throws -> (RecipePlan, HouseholdProfile, PersistenceController) {
        let controller = PersistenceController(inMemory: true)
        let ctx = controller.viewContext
        let household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()
        household.servingsDefault = 2
        let plan = RecipePlan(context: ctx)
        plan.id = UUID()
        plan.title = "Salmon"
        plan.createdAt = Date()
        for (idx, (name, slug, amount)) in ingredients.enumerated() {
            let ing = RecipeIngredient(context: ctx)
            ing.id = UUID()
            ing.displayName = name
            ing.canonicalIngredientSlug = slug
            ing.amountText = amount
            ing.sortOrder = Int16(idx)
            ing.recipePlan = plan
        }
        try ctx.save()
        // SCA-180: returned alongside the seeded objects so callers
        // can pass `GroceryRepository(controller: controller)` into
        // the VM. Dropping the controller reference would let the
        // production-defaulted repo write to the wrong store.
        return (plan, household, controller)
    }
}

// MARK: - AIDispatch stub (shared shape with other feature tests)

private extension AIDispatch {
    static var stub: AIDispatch {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            build: "1.0.0 (1)",
            osVersion: "17.5",
        )
        let session = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: .shared,
            sentry: NoOpSentryReporter(),
        )
        return AIDispatch(session: session, config: config)
    }
}
