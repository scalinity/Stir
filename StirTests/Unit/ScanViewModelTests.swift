// ScanViewModelTests
//
// Exercises the synchronous review-phase state transitions without
// spinning up AIDispatch:
//   - editIngredient flips confidence to confirmed
//   - deleteIngredient removes by id
//   - addIngredientManually appends a confirmed item
//   - resetToPrimer clears state
//
// Parse-phase tests that actually call AIDispatch require a mock
// server and are gated behind STIR_RUN_AI_INTEGRATION_TESTS in the
// backend tests; ViewModel-side parse paths are not retested here.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class ScanViewModelTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        household = try repo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
    }

    private func makeVM() -> ScanViewModel {
        // Use a placeholder AppConfig-free AIDispatch by wiring through a
        // real SupabaseSessionClient. None of the tests below call the
        // network path; we only need a non-nil reference.
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
        let ai = AIDispatch(session: session, config: config)
        let store = CurrentHouseholdStore()
        store.set(household)
        let entitlements = EntitlementService(keychain: MockKeychain())
        return ScanViewModel(
            aiDispatch: ai,
            pantryRepo: PantryItemRepository(controller: controller),
            householdStore: store,
            entitlements: entitlements,
        )
    }

    func test_editIngredient_flipsConfidenceToConfirmed() {
        let vm = makeVM()
        let id = UUID()
        vm.__injectForTests(ingredients: [
            .init(id: id, displayName: "tomato", confidence: .needsReview),
        ])
        vm.editIngredient(id: id, newName: "Roma tomato")
        XCTAssertEqual(vm.ingredients.first?.displayName, "Roma tomato")
        XCTAssertEqual(vm.ingredients.first?.confidence, .confirmed)
    }

    func test_deleteIngredient_removesById() {
        let vm = makeVM()
        let a = UUID()
        let b = UUID()
        vm.__injectForTests(ingredients: [
            .init(id: a, displayName: "tomato", confidence: .confirmed),
            .init(id: b, displayName: "basil", confidence: .confirmed),
        ])
        vm.deleteIngredient(id: a)
        XCTAssertEqual(vm.ingredients.count, 1)
        XCTAssertEqual(vm.ingredients.first?.displayName, "basil")
    }

    func test_addIngredientManually_appendsConfirmed() {
        let vm = makeVM()
        vm.addIngredientManually("olive oil")
        XCTAssertEqual(vm.ingredients.count, 1)
        XCTAssertEqual(vm.ingredients.first?.displayName, "olive oil")
        XCTAssertEqual(vm.ingredients.first?.confidence, .confirmed)
    }

    func test_addIngredientManually_ignoresWhitespaceOnlyName() {
        let vm = makeVM()
        vm.addIngredientManually("   ")
        XCTAssertEqual(vm.ingredients.count, 0)
    }

    func test_resetToPrimer_clearsState() {
        let vm = makeVM()
        vm.__injectForTests(ingredients: [
            .init(id: UUID(), displayName: "x", confidence: .confirmed),
        ])
        vm.resetToPrimer()
        XCTAssertEqual(vm.ingredients.count, 0)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.parseID)
    }

    func test_confirmFromReview_persistsPantryItemsAndReturnsLite() async throws {
        let vm = makeVM()
        vm.__injectForTests(ingredients: [
            .init(id: UUID(), displayName: "tomato", canonicalSlug: "tomato", confidence: .confirmed),
            .init(id: UUID(), displayName: "basil", confidence: .confirmed),
        ])
        let lite = await vm.confirmFromReview()
        XCTAssertEqual(lite.count, 2)
        XCTAssertEqual(lite.first?.displayName, "tomato")
        XCTAssertEqual(vm.phase, .confirmed)

        // Verify persistence into Core Data.
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        let saved = try controller.viewContext.fetch(request)
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { $0.userConfirmed })
        XCTAssertTrue(saved.allSatisfy { $0.typedSource == .scan })
    }
}

// MARK: - Test-only injection hook on ScanViewModel

extension ScanViewModel {
    /// Internal test hook — directly seed the ingredient array. Avoids a
    /// round trip through AIDispatch that would need network mocking.
    func __injectForTests(ingredients: [Ingredient]) {
        // Mirrors submitCapturedImage's success-path tail.
        self.__setIngredientsForTests(ingredients)
    }
}
