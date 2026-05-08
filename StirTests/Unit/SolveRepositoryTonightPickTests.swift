// SolveRepositoryTonightPickTests
//
// CR3-C3 fix: pin the high-traffic Tonight + Solve-again read APIs that
// shipped without coverage:
//   - latestTonightPick: nil when no completed solve, returns latest
//     completed, prefers user-selected dish over rank-0, bails on
//     soft-deleted plans.
//   - latestPantryIngredients: returns the snapshot from the latest
//     completed solve.
//   - softDelete: persists deletedAt, returns true on success.
//
// CoreData fixtures use the in-memory PersistenceController so saves
// round-trip without touching disk. Test-scoped install:test:<uuid>
// per CLAUDE.md "Integration test DB strategy."

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SolveRepositoryTonightPickTests: XCTestCase {
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

    // MARK: - latestTonightPick

    func test_latestTonightPick_returnsNilWhenNoSolves() {
        XCTAssertNil(solveRepo.latestTonightPick(for: household))
    }

    // SCA-70: regular dinner-solves carry no sourceRecipePlanId, so
    // their TonightPick must report isFromLeftovers=false. The
    // hero-card eyebrow logic in TonightHomeView keys off this flag.
    func test_latestTonightPick_dinnerSolveReportsNotFromLeftovers() throws {
        try seedSolve(title: "Regular dinner", servings: 2, estimatedMinutes: 25, rank: 0)
        let pick = try XCTUnwrap(solveRepo.latestTonightPick(for: household))
        XCTAssertFalse(pick.isFromLeftovers)
    }

    func test_latestTonightPick_returnsLatestCompletedSolve() throws {
        try seedSolve(title: "Older Pasta", servings: 2, estimatedMinutes: 25, rank: 0)
        // Slight delay to ensure completedAt ordering is deterministic.
        try seedSolve(title: "Newer Tacos", servings: 4, estimatedMinutes: 18, rank: 0)

        let pick = try XCTUnwrap(solveRepo.latestTonightPick(for: household))
        XCTAssertEqual(pick.title, "Newer Tacos")
        XCTAssertEqual(pick.servings, 4)
        XCTAssertEqual(pick.estimatedMinutes, 18)
    }

    func test_latestTonightPick_prefersUserSelectedDishOverRank0() throws {
        // Create a solve with two dishes; user selected the rank-1 one.
        let outcome = try seedSolveMultiDish(titles: ["Rank0 Dish", "Rank1 Dish"])
        // selectedSuggestedDishId points at the rank-1 dish.
        guard let solve = try fetchSolve(id: outcome.solveRequestId),
              let secondDish = solve.suggestedDishArray.first(where: { $0.rank == 1 })
        else {
            XCTFail("Couldn't load seeded solve.")
            return
        }
        try solveRepo.markSelected(secondDish, on: solve)

        let pick = try XCTUnwrap(solveRepo.latestTonightPick(for: household))
        XCTAssertEqual(pick.title, "Rank1 Dish",
                       "User-selected dish must win over rank-0 — the act of selecting is a commitment.")
    }

    func test_latestTonightPick_bailsWhenChosenPlanIsSoftDeleted() throws {
        let outcome = try seedSolve(title: "Soft Deleted Plan", servings: 2, estimatedMinutes: 20, rank: 0)
        guard let plan = solveRepo.fetchRecipePlan(forSuggestedDishId: outcome.suggestedDishIds[0]) else {
            XCTFail("Couldn't load plan from seeded solve.")
            return
        }
        XCTAssertTrue(solveRepo.softDelete(plan))

        XCTAssertNil(solveRepo.latestTonightPick(for: household),
                     "Soft-deleted plan must NOT ghost in the Tonight hero card.")
    }

    // MARK: - latestPantryIngredients

    func test_latestPantryIngredients_returnsSnapshot() throws {
        _ = try seedSolveWithPantry(
            title: "P",
            pantry: [
                .init(displayName: "Tomato", canonicalSlug: "tomato", amountText: "2"),
                .init(displayName: "Basil", canonicalSlug: "basil", amountText: "1 bunch"),
            ],
        )
        let ingredients = try XCTUnwrap(solveRepo.latestPantryIngredients(for: household))
        XCTAssertEqual(ingredients.count, 2)
        XCTAssertEqual(ingredients.first?.displayName, "Tomato")
    }

    func test_latestPantryIngredients_returnsNilWhenNoSolves() {
        XCTAssertNil(solveRepo.latestPantryIngredients(for: household))
    }

    // MARK: - softDelete

    func test_softDelete_setsDeletedAtAndReturnsTrue() throws {
        let outcome = try seedSolve(title: "Marked", servings: 2, estimatedMinutes: 10, rank: 0)
        let plan = try XCTUnwrap(solveRepo.fetchRecipePlan(forSuggestedDishId: outcome.suggestedDishIds[0]))
        XCTAssertNil(plan.deletedAt)
        XCTAssertTrue(solveRepo.softDelete(plan))
        XCTAssertNotNil(plan.deletedAt)
    }

    // MARK: - Helpers

    @discardableResult
    private func seedSolve(
        title: String,
        servings: Int,
        estimatedMinutes: Int,
        rank: Int,
    ) throws -> SolveRepository.SolveOutcome {
        let dishInput = SolveRepository.DishInput(
            rank: rank,
            title: title,
            summary: "summary",
            totalTimeMinutes: estimatedMinutes,
            fitLabelPrimary: .bestFit,
            fitLabelSecondary: nil,
            missingIngredientCount: 0,
            hardConstraintPass: true,
            reasoningSummary: "reason",
            confidence: 0.9,
            recipePlan: SolveRepository.RecipePlanInput(
                title: title,
                summary: "summary",
                servings: servings,
                difficulty: 1,
                estimatedMinutes: estimatedMinutes,
                cuisine: nil,
                aiVersion: "1.0.0",
                ingredients: [
                    SolveRepository.IngredientInput(
                        displayName: "Salt",
                        canonicalSlug: "salt",
                        amountText: "1 tsp",
                        isOptional: false,
                    ),
                ],
                steps: [
                    SolveRepository.StepInput(
                        stepNumber: 1,
                        instructionText: "Cook.",
                        timerSeconds: nil,
                        cautionTags: [],
                    ),
                ],
            ),
        )
        let snapshot = MealSolveRequest.PantrySnapshot(ingredients: [])
        return try solveRepo.createSolveWithDishes(
            on: household,
            constraints: nil,
            pantrySnapshot: snapshot,
            dishes: [dishInput],
            aiRequestId: nil,
        )
    }

    private func seedSolveMultiDish(titles: [String]) throws -> SolveRepository.SolveOutcome {
        let dishes = titles.enumerated().map { idx, title in
            SolveRepository.DishInput(
                rank: idx,
                title: title,
                summary: "summary",
                totalTimeMinutes: 20,
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
                    estimatedMinutes: 20,
                    cuisine: nil,
                    aiVersion: "1.0.0",
                    ingredients: [],
                    steps: [],
                ),
            )
        }
        return try solveRepo.createSolveWithDishes(
            on: household,
            constraints: nil,
            pantrySnapshot: MealSolveRequest.PantrySnapshot(ingredients: []),
            dishes: dishes,
            aiRequestId: nil,
        )
    }

    private func seedSolveWithPantry(
        title: String,
        pantry: [MealSolveRequest.PantrySnapshot.Ingredient],
    ) throws -> SolveRepository.SolveOutcome {
        let dishInput = SolveRepository.DishInput(
            rank: 0,
            title: title,
            summary: "summary",
            totalTimeMinutes: 20,
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
                estimatedMinutes: 20,
                cuisine: nil,
                aiVersion: "1.0.0",
                ingredients: [],
                steps: [],
            ),
        )
        return try solveRepo.createSolveWithDishes(
            on: household,
            constraints: nil,
            pantrySnapshot: MealSolveRequest.PantrySnapshot(ingredients: pantry),
            dishes: [dishInput],
            aiRequestId: nil,
        )
    }

    private func fetchSolve(id: UUID) throws -> MealSolveRequest? {
        let request = NSFetchRequest<MealSolveRequest>(entityName: "MealSolveRequest")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try controller.viewContext.fetch(request).first
    }
}
