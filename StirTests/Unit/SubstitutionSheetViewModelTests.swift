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

    // MARK: - Analytics emission (pre-dispatch)

    func test_submit_emitsSubstitutionRequestedBeforeDispatch() async {
        // 2026-04-22 prod regression: 4 substitution_accepted(unsafe_acknowledged)
        // events landed on PostHog from the sheet VM in the last hour, but
        // zero substitution_requested despite BOTH being emitted from the
        // same class, same analytics instance, same submit → unsafe → ack
        // flow. Pin the pre-dispatch emission here so a regression shows
        // up loud at CI time instead of as a funnel drop-off in prod.
        let spy = SpyPostHog()
        let vm = makeVM(analytics: spy)
        vm.freeTextName = "out of heavy cream"

        // Kick off the submit. The AI dispatch will fail against
        // test.invalid, but that's fine — substitution_requested fires
        // BEFORE the dispatch (line 97 of the VM, immediately after
        // state = .requesting and before the SubstitutionRequest is
        // even constructed). The capture should land regardless of
        // dispatch outcome.
        await vm.submit()

        let requested = spy.captures.filter { $0.event == "substitution_requested" }
        XCTAssertEqual(requested.count, 1,
                       "substitutionRequested must fire exactly once per submit — got \(requested.count)")
        let props = requested.first?.properties ?? [:]
        XCTAssertEqual(props["invocation"] as? String, "sheet")
        XCTAssertEqual(props["problem_type"] as? String, "free_text")
        XCTAssertNotNil(props["sub_event_id"] as? String,
                        "sub_event_id must be populated so the funnel joins to the paired accepted event")
    }

    // MARK: - SCA-424 pantry snapshot filter
    //
    // The substitution prompt explicitly tells the model to "prefer
    // ingredients already present in the pantry_snapshot." Any
    // soft-deleted or unconfirmed row that leaks into the snapshot
    // gives the model material to say "from your pantry" about an item
    // the user can't actually see in their pantry UI. Voice path was
    // fixed to filter `deletedAt == nil && userConfirmed` via
    // `voiceContextSnapshot()`; the SHEET substitution path drifted
    // with only `!name.isEmpty`. This pins the corrected filter.

    func test_buildHouseholdContext_excludesSoftDeletedPantryItems_SCA424() throws {
        try seedPantry([
            (name: "olive oil", deletedAt: nil, userConfirmed: true),
            (name: "ghost baguette", deletedAt: Date(), userConfirmed: true),
        ])
        let vm = makeVM()
        let ctx = vm.buildHouseholdContext()
        let names = ctx.pantrySnapshot.map(\.displayName)
        XCTAssertEqual(names.sorted(), ["olive oil"],
                       "soft-deleted rows must not reach the substitution model — that's the SCA-424 hallucination source")
    }

    func test_buildHouseholdContext_excludesUnconfirmedPantryItems_SCA424() throws {
        try seedPantry([
            (name: "olive oil", deletedAt: nil, userConfirmed: true),
            (name: "scan-junk row", deletedAt: nil, userConfirmed: false),
        ])
        let vm = makeVM()
        let ctx = vm.buildHouseholdContext()
        let names = ctx.pantrySnapshot.map(\.displayName)
        XCTAssertEqual(names.sorted(), ["olive oil"],
                       "unconfirmed scan-parse rows must not reach the model — the user never accepted them as actually being in their pantry")
    }

    func test_buildHouseholdContext_includesConfirmedActivePantryItems_SCA424() throws {
        try seedPantry([
            (name: "olive oil", deletedAt: nil, userConfirmed: true),
            (name: "kosher salt", deletedAt: nil, userConfirmed: true),
        ])
        let vm = makeVM()
        let ctx = vm.buildHouseholdContext()
        let names = Set(ctx.pantrySnapshot.map(\.displayName))
        XCTAssertEqual(names, ["olive oil", "kosher salt"],
                       "the filter must not over-exclude: confirmed non-deleted rows MUST reach the model")
    }

    // MARK: - SCA-425 recipe steps projection

    func test_buildRecipeContext_populatesRecipeSteps_SCA425() throws {
        try replaceRecipeStepArray([
            (number: 1, instruction: "Whisk flour, salt, and water; rest 10 min.", timer: 600),
            (number: 2, instruction: "Roll dough into thin flatbreads.", timer: 0),
            (number: 3, instruction: "Cook each on a hot skillet 60s/side.", timer: 120),
        ])
        let vm = makeVM()
        let ctx = vm.buildRecipeContext()
        XCTAssertEqual(ctx.recipeSteps.count, 3)
        XCTAssertEqual(ctx.recipeSteps[0].stepNumber, 1)
        XCTAssertEqual(ctx.recipeSteps[0].instruction, "Whisk flour, salt, and water; rest 10 min.")
        XCTAssertEqual(ctx.recipeSteps[0].timerSeconds, 600)
        // 0-second timer in Core Data → nil on the wire (Zod nullable;
        // gives the model an explicit "untimed" signal instead of a
        // misleading 0-second timer reading).
        XCTAssertNil(ctx.recipeSteps[1].timerSeconds,
                     "0-second timer must be projected as nil so the model reads 'no timer', not '0-second timer'")
        XCTAssertEqual(ctx.recipeSteps[2].timerSeconds, 120)
    }

    func test_buildRecipeContext_skipsStepsWithEmptyInstruction_SCA425() throws {
        try replaceRecipeStepArray([
            (number: 1, instruction: "valid step", timer: 0),
            (number: 2, instruction: "   ", timer: 0),           // whitespace-only
            (number: 3, instruction: "", timer: 0),              // empty
            (number: 4, instruction: "another valid step", timer: 0),
        ])
        let vm = makeVM()
        let ctx = vm.buildRecipeContext()
        // 2 valid + 2 empty → 2 wire rows, preserving original step_number.
        XCTAssertEqual(ctx.recipeSteps.map(\.stepNumber), [1, 4],
                       "empty/whitespace-only instructions must be dropped — backend Zod enforces min(1) on instruction")
    }

    func test_buildRecipeContext_clampsLongInstructionToWireBound_SCA425() throws {
        let huge = String(repeating: "x", count: 2500)
        try replaceRecipeStepArray([
            (number: 1, instruction: huge, timer: 0),
        ])
        let vm = makeVM()
        let ctx = vm.buildRecipeContext()
        XCTAssertEqual(ctx.recipeSteps.count, 1)
        XCTAssertEqual(ctx.recipeSteps[0].instruction.count, 2000,
                       "instructions over 2000 chars MUST be clamped client-side or backend Zod trips VAL-01")
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

    private func replaceRecipeStepArray(
        _ steps: [(number: Int, instruction: String, timer: Int)],
    ) throws {
        let context = controller.viewContext
        // Clear any existing steps so the test owns the full set.
        for existing in recipePlan.stepArray {
            context.delete(existing)
        }
        for (idx, step) in steps.enumerated() {
            let row = RecipeStep(context: context)
            row.id = UUID()
            row.recipePlan = recipePlan
            row.stepNumber = Int16(step.number)
            row.sortOrder = Int16(idx)
            row.instructionText = step.instruction
            row.timerSeconds = Int32(step.timer)
        }
        try controller.save()
    }

    private func makeVM(
        onFinished: @escaping () -> Void = {},
        analytics: PostHogClient? = nil,
    ) -> SubstitutionSheetViewModel {
        SubstitutionSheetViewModel(
            recipePlan: recipePlan,
            household: household,
            session: session,
            currentStep: nil,
            aiDispatch: aiDispatch,
            repository: SubstitutionRepository(controller: controller),
            pantryRepository: PantryItemRepository(controller: controller),
            analytics: analytics ?? .shared,
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

/// Spy analytics subclass for asserting captures in tests. Uses the
/// `#if DEBUG` `init(testingOnly:)` protected init on PostHogClient so
/// production builds can't accidentally construct one.
private final class SpyPostHog: PostHogClient, @unchecked Sendable {
    struct Capture: Sendable {
        let event: String
        let properties: [String: Any]
    }
    private let lock = NSLock()
    private var _captures: [Capture] = []
    var captures: [Capture] {
        lock.lock(); defer { lock.unlock() }
        return _captures
    }
    init() {
        super.init(testingOnly: true)
    }
    override func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        _captures.append(Capture(event: event.rawValue, properties: properties))
    }
}
