// SolveRepositoryLeftoversTests
//
// SCA-55 — pin SolveRepository.createLeftoversSolveWithDish behavior:
//   - persists ONE dish, not three
//   - sets sourceRecipePlan (relationship, SCA-110) to link back to the
//     source recipe — was a bare UUID `sourceRecipePlanId` attribute
//     pre-SCA-110 (lightweight migration). Tests assert via the new
//     relationship's `.id`.
//   - skips constraints + pantrySnapshot (leftovers solves carry neither)
//   - marks the suggested dish selected immediately (no separate
//     selection step downstream — picking the leftovers card IS the
//     commitment)
//   - returns a usable RecipePlan whose ingredients/steps round-trip
//
// SCA-106 — the function is now async and saves on a background
// NSManagedObjectContext. Tests await the call and read `.recipePlan`
// off the returned `LeftoversSolveOutcome`. Adds the
// `test_createLeftoversSolveWithDish_pathologicalDishPersists` case
// that exercises a 50-ingredient fixture to ensure the bg-context
// path is wired.
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

    func test_createLeftoversSolveWithDish_persistsExactlyOneDish() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        XCTAssertEqual(outcome.recipePlan.title, "Salmon fried rice")
        // Walk back from the persisted plan via its SuggestedDish to its
        // MealSolveRequest — exactly one dish should hang off the solve.
        let dishes = try fetchSuggestedDishes(forRecipePlanId: outcome.recipePlan.id)
        XCTAssertEqual(dishes.count, 1, "leftovers solve persists ONE dish, not three")
    }

    func test_createLeftoversSolveWithDish_setsSourceRecipePlanRelationship() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: outcome.recipePlan.id))
        // SCA-110: relationship-based link. The leftovers solve must
        // point to the SAME RecipePlan instance that produced the
        // leftovers — analytics queries read `.id` off the relationship.
        XCTAssertEqual(
            solve.sourceRecipePlan?.id,
            source.id,
            "leftovers solve relationship must resolve to the source RecipePlan",
        )
        XCTAssertTrue(
            solve.sourceRecipePlan === source,
            "relationship resolves to the same managed object passed in (no proxy/copy)",
        )
    }

    // SCA-110: orphan-detection — Nullify deletionRule on both sides
    // means deleting the source RecipePlan should leave the leftovers
    // solve row intact with sourceRecipePlan == nil, NOT crash and NOT
    // cascade-delete the solve. Pinned here because the SCA-56-era
    // bare-UUID design tolerated dangling pointers; the Stir-2 model's
    // FK-style relationship has stricter semantics that need a test to
    // ensure we didn't accidentally pick deletionRule=Cascade.
    func test_createLeftoversSolveWithDish_sourceRecipePlanDeleteNullsRelationship() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )
        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: outcome.recipePlan.id))
        XCTAssertNotNil(solve.sourceRecipePlan, "precondition: relationship is wired")

        // Hard-delete the source plan and save.
        controller.viewContext.delete(source)
        try controller.viewContext.save()

        // Re-fetch the solve to bust any in-memory cache and verify the
        // relationship is now nil (not a dangling reference, not a
        // cascade-deleted solve row).
        controller.viewContext.refresh(solve, mergeChanges: true)
        XCTAssertNil(solve.sourceRecipePlan, "Nullify deletionRule clears the relationship")
        XCTAssertNil(solve.deletedAt, "leftovers solve row is NOT cascade-deleted with the source plan")
        // Round-trip via fetch to confirm persistence layer agrees.
        let request = NSFetchRequest<MealSolveRequest>(entityName: "MealSolveRequest")
        request.predicate = NSPredicate(format: "id == %@", solve.id! as CVarArg)
        let refreshed = try XCTUnwrap(controller.viewContext.fetch(request).first)
        XCTAssertNil(refreshed.sourceRecipePlan)
    }

    func test_createLeftoversSolveWithDish_skipsConstraintsAndPantrySnapshot() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: outcome.recipePlan.id))
        XCTAssertNil(solve.typedConstraints, "leftovers solves don't carry constraints")
        XCTAssertNil(solve.typedPantrySnapshot, "leftovers solves skip pantry per LeftoversSessionViewModel:187")
    }

    func test_createLeftoversSolveWithDish_marksDishSelected() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: outcome.recipePlan.id))
        let suggested = try XCTUnwrap(solve.suggestedDishArray.first)
        XCTAssertNotNil(suggested.selectedAt, "leftovers solve marks its dish selected immediately")
        XCTAssertEqual(solve.selectedSuggestedDishId, suggested.id)
    }

    func test_createLeftoversSolveWithDish_roundTripsIngredientsAndSteps() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(
            title: "Salmon fried rice",
            rank: 1,
            ingredientNames: ["Cooked rice", "Leftover salmon", "Soy sauce"],
            stepCount: 4,
        )

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let ings = (outcome.recipePlan.ingredients as? Set<RecipeIngredient>)?
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap(\.displayName) ?? []
        XCTAssertEqual(ings, ["Cooked rice", "Leftover salmon", "Soy sauce"])

        let steps = (outcome.recipePlan.steps as? Set<RecipeStep>)?
            .sorted { $0.sortOrder < $1.sortOrder } ?? []
        XCTAssertEqual(steps.count, 4)
        XCTAssertEqual(steps.map { Int($0.stepNumber) }, [1, 2, 3, 4])
    }

    // SCA-56 S2 / S3 — verify the magic-string `aiVersion = "leftovers"`
    // and magic-confidence 0.9/0.5 from the original implementation are
    // gone; instead, persistence threads the actual prompt version and
    // sets confidence to 0 (no model confidence on leftovers DishCards).
    func test_createLeftoversSolveWithDish_threadsPromptVersionAndZerosConfidence() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-canary",
        )

        XCTAssertEqual(outcome.recipePlan.aiVersion, "v1.1.0-canary",
                       "leftovers persistence MUST thread the backend prompt version, not a magic 'leftovers' tag")

        let solve = try XCTUnwrap(fetchSolveRequest(forNewRecipePlanId: outcome.recipePlan.id))
        let suggested = try XCTUnwrap(solve.suggestedDishArray.first)
        XCTAssertEqual(suggested.confidence, 0,
                       "leftovers DishCards don't carry a model confidence; persisted value must be 0 (sentinel), not a synthesized 0.9/0.5")
    }

    func test_createLeftoversSolveWithDish_unknownPromptVersionWhenNil() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: nil,
        )

        XCTAssertEqual(outcome.recipePlan.aiVersion, "unknown",
                       "nil promptVersion (stream errored before done event) falls back to 'unknown' sentinel")
    }

    // SCA-56 (DB1 #8) — verify steps are pre-sorted by stepNumber so
    // wire-order quirks can't desync sortOrder from semantic order.
    func test_createLeftoversSolveWithDish_sortsStepsByStepNumberRegardlessOfWireOrder() async throws {
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

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household, from: source, dish: dish,
            aiRequestId: nil, promptVersion: nil,
        )
        let steps = (outcome.recipePlan.steps as? Set<RecipeStep>)?
            .sorted { $0.sortOrder < $1.sortOrder } ?? []
        XCTAssertEqual(steps.map(\.instructionText), ["first", "second", "third"])
    }

    // SCA-108: leftovers solves no longer auto-promote to Tonight. The
    // SCA-70 negative pairing in SolveRepositoryTonightPickTests
    // (`test_latestTonightPick_dinnerSolveReportsNotFromLeftovers`)
    // remains the positive contract for non-leftovers solves; this
    // test now asserts the inverse — when only a leftovers solve
    // exists, `latestTonightPick` returns nil because the leftovers
    // solve is filtered out at the predicate. The prior assertion
    // (`pick.isFromLeftovers == true`) was the SCA-70 wire contract
    // that became unreachable once SCA-108 made leftovers a side
    // trip rather than a hero replacement.
    func test_createLeftoversSolveWithDish_doesNotPromoteToTonightPick_whenOnlyLeftoversExist() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Salmon fried rice", rank: 1)

        _ = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        XCTAssertNil(
            solveRepo.latestTonightPick(for: household),
            "SCA-108: leftovers solve must NOT auto-promote to Tonight; only the prior dinner solve (or nil if none) is the hero card",
        )
    }

    func test_createLeftoversSolveWithDish_keepsPriorDinnerSolveAsTonightPick() async throws {
        // SCA-108 inverse contract: a leftovers solve completing AFTER
        // a regular dinner solve must NOT overtake the dinner. The
        // prior dinner remains the Tonight hero card; the leftovers
        // plan still persists (Saved tab, Tomorrow's plan, analytics
        // wire), but it doesn't replace what the user just rated.
        // Earlier behavior (pre-SCA-108) was the inverse: leftovers
        // overtook because `completedAt` ordering had no source-plan
        // filter — see deferred-work.md line 42 + ADR ratification of
        // option B in the SCA-108 ticket body.
        _ = try seedSolveCompletedNow(title: "Earlier dinner")
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let dish = makeDishCard(title: "Tomorrow's leftover plan", rank: 1)

        _ = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        let pick = try XCTUnwrap(solveRepo.latestTonightPick(for: household))
        XCTAssertEqual(
            pick.title,
            "Earlier dinner",
            "SCA-108: prior dinner solve must remain the Tonight pick after a leftovers solve",
        )
        XCTAssertFalse(
            pick.isFromLeftovers,
            "SCA-108: latestTonightPick filters leftovers out; pick.isFromLeftovers is unreachable in practice",
        )
    }

    // SCA-106: pathological 50-ingredient + 25-step dish persists via
    // the bg-context path. Verifies (a) the round-trip writes all rows,
    // (b) `persistMs` is reported (>= 0; happy-path inMemory writes
    // are typically < 30 ms, so we assert a generous 5000 ms ceiling
    // to catch a regression where the bg context is mis-wired and
    // synchronously blocks the test main actor for many seconds), and
    // (c) the returned RecipePlan resolves on viewContext (proves the
    // objectID handoff works after a sibling-context save).
    func test_createLeftoversSolveWithDish_pathologicalDishPersistsViaBackgroundContext() async throws {
        let source = try seedSourceRecipePlan(title: "Salmon dinner")
        let ingredientNames = (1 ... 50).map { "Ingredient \($0)" }
        let dish = makeDishCard(
            title: "Pathological leftover plan",
            rank: 1,
            ingredientNames: ingredientNames,
            stepCount: 25,
        )

        let outcome = try await solveRepo.createLeftoversSolveWithDish(
            on: household,
            from: source,
            dish: dish,
            aiRequestId: nil,
            promptVersion: "v1.1.0-test",
        )

        // (a) round-trip writes
        let ings = (outcome.recipePlan.ingredients as? Set<RecipeIngredient>) ?? []
        XCTAssertEqual(ings.count, 50, "all 50 ingredients persisted on bg-context save")
        let steps = (outcome.recipePlan.steps as? Set<RecipeStep>) ?? []
        XCTAssertEqual(steps.count, 25, "all 25 steps persisted on bg-context save")

        // (b) persist_ms reported
        XCTAssertGreaterThanOrEqual(outcome.persistMs, 0, "persist_ms is non-negative")
        XCTAssertLessThan(outcome.persistMs, 5000,
                          "in-memory bg-context save shouldn't take > 5s; if it does, the bg context is mis-wired")

        // (c) view-context resolution after sibling save
        let viewObject = try controller.viewContext.existingObject(with: outcome.recipePlan.objectID)
        XCTAssertTrue(viewObject is RecipePlan, "returned RecipePlan resolves on viewContext")
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
