// SubstitutionSheetViewModelTests
//
// Exercises view-model logic that doesn't depend on the AIDispatch
// network round-trip: canSubmit gating, accept/reject early-return when
// no event has been persisted, and the analytics+dismiss behavior on the
// "acknowledge unsafe" path.
//
// The Gemini-call paths (.requesting → .safe / .unsafe / .error) are
// covered server-side by Backend/supabase/tests/substitution_test.ts and
// would require either MockURLProtocol wiring + a SupabaseSessionClient
// or extracting AIDispatch behind a protocol — both beyond the scope of
// this incremental coverage pass per the CR3 SCOPE RULE.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SubstitutionSheetViewModelTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var session: CookingSession!
    private var aiDispatch: AIDispatch!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household, ingredientNames: ["heavy cream", "garlic"])
        session = try CookingSessionRepository(controller: controller)
            .createSession(on: household, for: recipePlan, entryPoint: .solve)
        aiDispatch = makeAIDispatch()
    }

    // MARK: - canSubmit

    func test_canSubmit_falseWhenNoIngredientPickedAndNoFreeText() {
        let vm = makeVM()
        vm.selectedIngredientID = nil
        vm.freeTextName = ""
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_trueWhenIngredientPicked() {
        let vm = makeVM()
        let ingredient = recipePlan.ingredientArray.first
        XCTAssertNotNil(ingredient?.id)
        vm.selectedIngredientID = ingredient?.id
        vm.freeTextName = ""
        XCTAssertTrue(vm.canSubmit)
    }

    func test_canSubmit_trueWhenFreeTextProvided() {
        let vm = makeVM()
        vm.selectedIngredientID = nil
        vm.freeTextName = "my blender broke"
        XCTAssertTrue(vm.canSubmit)
    }

    func test_canSubmit_falseWhenFreeTextIsOnlyWhitespace() {
        let vm = makeVM()
        vm.selectedIngredientID = nil
        vm.freeTextName = "   "
        XCTAssertFalse(vm.canSubmit)
    }

    // MARK: - Accept / Reject early-return

    func test_accept_dismissesEarlyWhenNoSafeStateOrPersistedEvent() async {
        let expect = expectation(description: "onFinished called")
        let vm = makeVM(onFinished: { expect.fulfill() })
        // state is .idle, persistedEvent nil → accept() should just call onFinished.
        await vm.accept()
        await fulfillment(of: [expect], timeout: 1.0)
    }

    func test_reject_dismissesEarlyWhenNoPersistedEvent() async {
        let expect = expectation(description: "onFinished called")
        let vm = makeVM(onFinished: { expect.fulfill() })
        // No persistedEvent → reject() short-circuits to onFinished.
        await vm.reject()
        await fulfillment(of: [expect], timeout: 1.0)
    }

    func test_acknowledgeUnsafe_alwaysDismisses() async {
        let expect = expectation(description: "onFinished called")
        let vm = makeVM(onFinished: { expect.fulfill() })
        await vm.acknowledgeUnsafe()
        await fulfillment(of: [expect], timeout: 1.0)
    }

    // MARK: - Helpers

    private func makeVM(onFinished: @escaping () -> Void = {}) -> SubstitutionSheetViewModel {
        SubstitutionSheetViewModel(
            recipePlan: recipePlan,
            household: household,
            session: session,
            currentStep: nil,
            aiDispatch: aiDispatch,
            repository: SubstitutionRepository(controller: controller),
            onFinished: onFinished,
        )
    }

    private func makeAIDispatch() -> AIDispatch {
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

    private func makeRecipePlan(household: HouseholdProfile, ingredientNames: [String]) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Substitution Test"
        plan.servings = 2
        plan.estimatedMinutes = 25
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()

        for (idx, name) in ingredientNames.enumerated() {
            let ing = RecipeIngredient(context: context)
            ing.id = UUID()
            ing.recipePlan = plan
            ing.displayName = name
            ing.sortOrder = Int16(idx)
            ing.amountText = "1 cup"
            ing.isOptional = false
        }
        try controller.save()
        return plan
    }
}

private final class DismissBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func flip() { lock.lock(); _value = true; lock.unlock() }
}
