// SolveRepositoryLeftoversTests
//
// SCA-55 — pin SolveRepository.createLeftoversSolveWithDish behavior:
//   - persists ONE dish, not three
//   - sets sourceRecipePlanId to link back to the source recipe
//   - skips constraints + pantrySnapshot (leftovers solves carry neither)
//   - marks the suggested dish selected immediately (no separate
//     selection step downstream — picking the leftovers card IS the
//     commitment)
//   - returns a usable RecipePlan whose ingredients/steps round-trip
//
// CoreData fixtures use the in-memory PersistenceController so saves
// round-trip without touching disk; test-scoped install:test:<uuid>
// per CLAUDE.md "Integration test DB strategy."

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SolveRepositoryLeftoversTests: XCTestCase {
    private var controller: PersistenceController!
    private var householdRepo: HouseholdProfileRepository!
    private var solveRepo: SolveRepository!
    private var household: HouseholdProfile!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        householdRepo = HouseholdProfileRepository(controller: controller)
        solveRepo = SolveRepository(controller: controller)
        household = try householdRepo.ensureHouseholdProfile(
            for: "install:test:\(UUID().uuidString)",
        )
    }

    override func tearDown() async throws {
        controller = nil
        householdRepo = nil
        solveRepo = nil
        household = nil
        try await super.tearDown()
    }

    // MARK: - createLeftoversSolveWithDish

    func test_createLeftoversSolveWithDish_persistsExactlyOneDish() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        XCTAssertEqual(newPlan.title, "Salmon fried rice")
        // Walk back from the persisted plan via its SuggestedDish to its
        // MealSolveRequest — exactly one dish should hang off the solve.
        let dishes = try fetchSuggestedDishes(forRecipePlanId: newPlan.id)
        XCTAssertEqual(dishes.count, 1, "leftovers solve persists ONE dish, not three")
    }

    func test_createLeftoversSolveWithDish_setsSourceRecipePlanId() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: newPlan.id))
        XCTAssertEqual(
            solve.sourceRecipePlanId,
            source.id,
            "leftovers solve must link back to the meal that produced the leftovers",
        )
    }

    func test_createLeftoversSolveWithDish_skipsConstraintsAndPantrySnapshot() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: newPlan.id))
        XCTAssertNil(solve.typedConstraints, "leftovers solves don't carry constraints")
        XCTAssertNil(solve.typedPantrySnapshot, "leftovers solves skip pantry per LeftoversSessionViewModel:187")
    }

    func test_createLeftoversSolveWithDish_marksDishSelected() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: newPlan.id))
        let suggested = try XCTUnwrap(solve.suggestedDishArray.first)
        XCTAssertNotNil(suggested.selectedAt, "leftovers solve marks its dish selected immediately")
        XCTAssertEqual(solve.selectedSuggestedDishId, suggested.id)
    }

    func test_createLeftoversSolveWithDish_roundTripsIngredientsAndSteps() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(
            title: "Salmon fried rice",
            rank: 1,
            ingredientNames: ["Cooked rice", "Leftover salmon", "Soy sauce"],
            stepCount: 4,
        )

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let ings = (newPlan.ingredients as? Set<RecipeIngredient>)?
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap(\.displayName) ?? []
        XCTAssertEqual(ings, ["Cooked rice", "Leftover salmon", "Soy sauce"])

        let steps = (newPlan.steps as? Set<RecipeStep>)?
            .sorted { $0.sortOrder < $1.sortOrder } ?? []
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.map { Int($0.stepNumber) }, [1, 2, 3, 4])
    }

    // SCA-56 S2 / S3 — verify the magic-string `aiVersion = "leftovers"`
    // and magic-confidence 0.9/0.5 from the original implementation are
    // gone; instead, persistence threads the actual prompt version and
    // sets confidence to 0 (no model confidence on leftovers DishCards).
    func test_createLeftoversSolveWithDish_threadsPromptVersionAndZerosConfidence() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-canary",
        )

        XCTAssertEqual(newPlan.aiVersion, "v1.1.0-canary",
                       "leftovers persistence MUST thread the backend prompt version, not a magic 'leftovers' tag")

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: newPlan.id))
        let suggested = try XCTUnwrap(solve.suggestedDishArray.first)
        XCTAssertEqual(suggested.confidence, 0,
                       "leftovers DishCards don't carry a model confidence; persisted value must be 0 (sentinel), not a synthesized 0.9/0.5")
    }

    func test_createLeftoversSolveWithDish_unknownPromptVersionWhenNil() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: nil,
        )

        XCTAssertEqual(newPlan.aiVersion, "unknown",
                       "nil promptVersion (stream errored before done event) falls back to 'unknown' sentinel")
    }

    // SCA-56 (DB1 #8) — verify steps are pre-sorted by stepNumber so
    // wire-order quirks can't desync sortOrder from semantic order.
    func test_createLeftoversSolveWithDish_sortsStepsByStepNumberRegardlessOfWireOrder() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let outOfOrderSteps = [
            DishCard.RecipePlanWire.StepWire(stepNumber: 3, instructionText: "third", timerSeconds: nil, cautionTags: nil),
            DishCard.RecipePlanWire.StepWire(stepNumber: 1, instructionText: "first", timerSeconds: nil, cautionTags: nil),
            DishCard.RecipePlanWire.StepWire(stepNumber: 2, instructionText: "second", timerSeconds: nil, cautionTags: nil),
        ]
        let dish = DishCard(
            rank: 1,
            title: "Out-of-order dish",
            totalTimeMinutes: 10,
            whyItFits: "test",
            missingIngredientCount: 0,
            fitLabelPrimary: "best_fit",
            fitLabelSecondary: nil,
            hardConstraintPass: true,
            recipePlan: DishCard.RecipePlanWire(
                servings: 2, difficulty: 1, cuisine: nil,
                ingredients: [], steps: outOfOrderSteps,
            ),
            reasoningSummary: "test",
        )

        let newPlan = try solveRepo.createLeftoversSolveWithDish(
            on: household, from: source, dish: dish,
            aiRequestId: nil, promptVersion: nil,
        )
        let steps = (newPlan.steps as? Set<RecipeStep>)?
            .sorted { $0.sortOrder < $1.sortOrder } ?? []
        XCTAssertEqual(steps.map(\.instructionText), ["first", "second", "third"])
    }

    // SCA-70: leftovers solves must report isFromLeftovers=true on
    // TonightPick so TonightHomeView can swap the high-match badge
    // for a "FROM YOUR LEFTOVERS" eyebrow on the hero card. Pairs
    // with `test_latestTonightPick_dinnerSolveReportsNotFromLeftovers`
    // in SolveRepositoryTonightPickTests for the negative case.
    func test_createLeftoversSolveWithDish_picksUpAsFromLeftoversTrue() throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        _ = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let pick = try XCTUnwrap(solveRepo.latestTonightPick(for: household))
        XCTAssertTrue(pick.isFromLeftovers,
                      "leftovers solve must surface on Tonight with isFromLeftovers=true")
    }

    func test_createLeftoversSolveWithDish_promotesNewPlanToLatestTonightPick() throws {
        // The contract LeftoversSolveView's helper text promises:
        // "Saving one of these adds it to tomorrow's Tonight." Verify
        // the new leftovers plan IS the latestTonightPick after the call.
        _ = try seedSolveCompletedNow(title: "Earlier dinner")
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Tomorrow's leftover plan", rank: 1)

        _ = try solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let pick = try XCTUnwrap(solveRepo.latestTonightPick(for: household))
        XCTAssertEqual(pick.title, "Tomorrow's leftover plan")
    }

    // MARK: - Helpers

    /// Seed a source RecipePlan that ALREADY exists (the meal the user
    /// just cooked). Doesn't go through `createSolveWithDishes` — just
    /// builds a bare RecipePlan tied to the household.
    private func seedSourceRecipePlan(title: String) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = title
        plan.summary = "summary"
        plan.servings = 2
        plan.difficulty = 1
        plan.estimatedMinutes = 30
        plan.aiVersion = "1.0.0"
        plan.typedOrigin = .ai
        plan.isFavorite = false
        plan.isSaved = false
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try context.save()
        return plan
    }

    /// Seed a completed solve via the standard path so we have a baseline
    /// `latestTonightPick` to assert leftovers OVERTAKES.
    @discardableResult
    private func seedSolveCompletedNow(title: String) throws -> SolveRepository.SolveOutcome {
        let dishInput = SolveRepository.DishInput(
            rank: 0,
            title: title,
            summary: "summary",
            totalTimeMinutes: 25,
            fitLabelPrimary: .bestFit,
            fitLabelSecondary: nil,
            missingIngredientCount: 0,
            hardConstraintPass: true,
            reasoningSummary: "reason",
            confidence: 0.9,
            recipePlan: SolveRepository.RecipePlanInput(
                title: title,
                summary: "summary",
                servings: 2,
                difficulty: 1,
                estimatedMinutes: 25,
                cuisine: nil,
                aiVersion: "1.0.0",
                ingredients: [],
                steps: [],
            ),
        )
        return try solveRepo.createSolveWithDishes(
            on: household,
            constraints: nil,
            pantrySnapshot: MealSolveRequest.PantrySnapshot(ingredients: []),
            dishes: [dishInput],
            aiRequestId: nil,
        )
    }

    private func makeDishCard(
        title: String,
        rank: Int,
        ingredientNames: [String] = ["Salt"],
        stepCount: Int = 1,
    ) -> DishCard {
        let ingredients = ingredientNames.map {
            DishCard.RecipePlanWire.IngredientWire(
                displayName: $0,
                canonicalSlug: nil,
                amountText: "1 unit",
                isOptional: false,
            )
        }
        let steps = (1 ... stepCount).map { idx in
            DishCard.RecipePlanWire.StepWire(
                stepNumber: idx,
                instructionText: "Step \(idx)",
                timerSeconds: nil,
                cautionTags: nil,
            )
        }
        return DishCard(
            rank: rank,
            title: title,
            totalTimeMinutes: 15,
            whyItFits: "Uses your leftovers.",
            missingIngredientCount: 0,
            fitLabelPrimary: "best_fit",
            fitLabelSecondary: nil,
            hardConstraintPass: true,
            recipePlan: DishCard.RecipePlanWire(
                servings: 2,
                difficulty: 1,
                cuisine: nil,
                ingredients: ingredients,
                steps: steps,
            ),
            reasoningSummary: "leftovers reasoning",
        )
    }

    /// Fetch SuggestedDish rows whose `recipePlan.id` matches `id`.
    private func fetchSuggestedDishes(forRecipePlanId id: UUID?) throws -> [SuggestedDish] {
        guard let id else { return [] }
        let request = NSFetchRequest<SuggestedDish>(entityName: "SuggestedDish")
        request.predicate = NSPredicate(format: "recipePlan.id == %@", id as CVarArg)
        return try controller.viewContext.fetch(request)
    }

    /// Walk SuggestedDish.recipePlan == newPlan back to the parent
    /// MealSolveRequest. Returns nil if no SuggestedDish links it.
    private func fetchSolveRequest(forNewRecipePlanId id: UUID?) throws -> MealSolveRequest? {
        try fetchSuggestedDishes(forRecipePlanId: id).first?.solveRequest
    }
}
