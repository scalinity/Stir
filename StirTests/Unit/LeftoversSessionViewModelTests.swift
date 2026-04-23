// LeftoversSessionViewModelTests
//
// Unit tests for the step-7 Leftovers flow. The VM is the integration
// point between OutcomeFeedback.leftoverCount > 0 (the trigger) and
// /v1/ai/dinner-solve with context_hint=leftovers. Tests focus on:
//
//   - Seeded items come from the just-cooked recipe's ingredient list,
//     starting unselected so the user opts in per ingredient.
//   - toggle / setAmount / addCustomItem mutate correctly.
//   - selectedItems filters correctly.
//
// Backend-integration tests (solve streaming, telemetry emission) are
// out of scope for this unit test — those live in the backend Deno
// suite. This unit covers the VM's state machine only.

import XCTest
@testable import Stir

@MainActor
final class LeftoversSessionViewModelTests: XCTestCase {
    // MARK: - Seeding

    func test_init_seedsItemsFromRecipeIngredientsUnselected() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [
                ("Salmon", "salmon", "2 fillets"),
                ("Rice", "rice-jasmine", "1 cup"),
                ("Lemon", "lemon", "1"),
            ],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        XCTAssertEqual(vm.items.count, 3)
        XCTAssertEqual(vm.items.map(\.displayName), ["Salmon", "Rice", "Lemon"])
        XCTAssertEqual(vm.items.map(\.canonicalSlug), ["salmon", "rice-jasmine", "lemon"])
        XCTAssertTrue(vm.items.allSatisfy { !$0.isSelected }, "user must opt in per ingredient")
    }

    func test_init_skipsEmptyIngredientNames() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [
                ("", "x", nil),        // empty display name — skipped
                ("Chicken", "chicken", "4 thighs"),
            ],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        XCTAssertEqual(vm.items.count, 1)
        XCTAssertEqual(vm.items.first?.displayName, "Chicken")
    }

    // MARK: - Toggle / setAmount

    func test_toggle_flipsSelection() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [("Rice", "rice", "1 cup")],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        let entry = vm.items[0]
        XCTAssertFalse(vm.items[0].isSelected)
        vm.toggle(entry)
        XCTAssertTrue(vm.items[0].isSelected)
        vm.toggle(entry)
        XCTAssertFalse(vm.items[0].isSelected)
    }

    func test_setAmount_updatesAmountText_nilsWhitespace() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [("Rice", "rice", "1 cup")],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        let entry = vm.items[0]
        vm.setAmount("3 portions", for: entry)
        XCTAssertEqual(vm.items[0].approximateAmountText, "3 portions")
        vm.setAmount("   ", for: entry)
        XCTAssertNil(vm.items[0].approximateAmountText, "whitespace-only amount clears to nil")
    }

    func test_addCustomItem_appendsSelectedRow() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [("Rice", "rice", "1 cup")],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        vm.addCustomItem(name: "Kale", amount: "half a bunch")
        XCTAssertEqual(vm.items.count, 2)
        let custom = vm.items[1]
        XCTAssertEqual(custom.displayName, "Kale")
        XCTAssertEqual(custom.approximateAmountText, "half a bunch")
        XCTAssertTrue(custom.isSelected, "custom items start selected — user just typed them")
        XCTAssertNil(custom.canonicalSlug, "free-text custom items have no canonical mapping")
    }

    func test_addCustomItem_ignoresEmptyName() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [("Rice", "rice", "1 cup")],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        vm.addCustomItem(name: "   ", amount: "1 cup")
        XCTAssertEqual(vm.items.count, 1, "whitespace-only name is ignored")
    }

    func test_selectedItems_onlyReturnsIsSelectedTrue() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [
                ("Salmon", "salmon", nil),
                ("Rice", "rice", nil),
                ("Lemon", "lemon", nil),
            ],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        vm.toggle(vm.items[0])
        vm.toggle(vm.items[2])
        let selected = vm.selectedItems
        XCTAssertEqual(selected.count, 2)
        XCTAssertEqual(selected.map(\.displayName).sorted(), ["Lemon", "Salmon"])
    }

    // MARK: - Stage machine

    func test_initialStage_isPrompt() throws {
        let (plan, household) = try seedRecipePlan(
            ingredients: [("Rice", "rice", nil)],
        )
        let vm = LeftoversSessionViewModel(
            recipePlan: plan,
            household: household,
            aiDispatch: AIDispatch.stub,
        )
        XCTAssertEqual(vm.stage, .prompt)
    }

    // MARK: - Helpers

    /// Build an in-memory RecipePlan + HouseholdProfile for test use. Uses
    /// PersistenceController.inMemory to avoid hitting CloudKit-configured
    /// production container during unit tests.
    private func seedRecipePlan(
        ingredients: [(String, String?, String?)],
    ) throws -> (RecipePlan, HouseholdProfile) {
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
        return (plan, household)
    }
}

// MARK: - AIDispatch stub

private extension AIDispatch {
    /// Inert AIDispatch for unit tests that only exercise VM state
    /// mutations. Matches the shape ScanViewModelTests uses — real
    /// SupabaseSessionClient, bogus URL, no network path engaged.
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
