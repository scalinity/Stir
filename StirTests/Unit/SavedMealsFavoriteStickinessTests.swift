// SavedMealsFavoriteStickinessTests
//
// Regression: SCA-10. A RecipePlan that the user favorited (e.g. via
// Tonight's Save-for-later) and never cooked used to disappear from
// `savedMealEntries` the moment they unfavorited it, because the
// predicate's only qualifier for that row was `isFavorite == YES`.
// Fix: `setFavorite` flips `isSaved = true` (sticky), and the predicate
// includes `isSaved == YES` as an OR clause. Soft-delete remains the
// only path that drops a plan from Saved.
//
// Tests exercise the round-trip: write via SolveRepository.setFavorite
// (the production path the UI actually calls), read via
// CookingSessionRepository.savedMealEntries.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SavedMealsFavoriteStickinessTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var solveRepo: SolveRepository!
    private var cookRepo: CookingSessionRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        solveRepo = SolveRepository(controller: controller)
        cookRepo = CookingSessionRepository(controller: controller)
    }

    // MARK: - The bug regression

    func test_unfavoritingNeverCookedPlanKeepsItInSavedMeals() throws {
        // Arrange — plan favorited via the same path Tonight uses
        // (Save-for-later → SolveRepository.setFavorite(true, ...)).
        let plan = makePlan(title: "Tomato Galette")
        XCTAssertTrue(solveRepo.setFavorite(true, on: plan))

        // Sanity — appears in saved while favorited.
        var entries = try cookRepo.savedMealEntries(for: household)
        XCTAssertEqual(entries.map(\.title), ["Tomato Galette"])

        // Act — user unfavorites.
        XCTAssertTrue(solveRepo.setFavorite(false, on: plan))

        // Assert — plan must still surface in Saved (Favorites is a
        // sub-filter of Saved, not the sole gate).
        entries = try cookRepo.savedMealEntries(for: household)
        XCTAssertEqual(
            entries.map(\.title), ["Tomato Galette"],
            "Unfavoriting a never-cooked plan must not remove it from Saved (SCA-10).",
        )
    }

    func test_setFavoriteTrueMarksPlanIsSaved() throws {
        let plan = makePlan(title: "Lemony Pasta")
        XCTAssertFalse(plan.isSaved)
        XCTAssertTrue(solveRepo.setFavorite(true, on: plan))
        XCTAssertTrue(plan.isSaved, "setFavorite(true) must promote isSaved")
    }

    func test_setFavoriteFalseDoesNotClearIsSaved() throws {
        let plan = makePlan(title: "Charred Broccoli")
        _ = solveRepo.setFavorite(true, on: plan)
        XCTAssertTrue(plan.isSaved)

        _ = solveRepo.setFavorite(false, on: plan)
        XCTAssertTrue(plan.isSaved, "Unfavoriting must not unset isSaved")
        XCTAssertFalse(plan.isFavorite)
    }

    func test_unfavoritingPreFixRowMigratesIsSavedAndKeepsItInSaved() throws {
        // Simulates pre-SCA-10 data: a row that was favorited by an
        // older app build whose setFavorite did NOT touch isSaved. We
        // bypass setFavorite for the initial state so isFavorite=true
        // co-exists with isSaved=false (the impossible state under the
        // new code path). SCA-151 drops the legacy `isFavorite == YES`
        // fetch fallback, so this row should not surface until a write
        // path explicitly migrates it to `isSaved=true`.
        let plan = makePlan(title: "Pre-fix Pierogi")
        plan.isFavorite = true
        plan.isSaved = false
        try controller.viewContext.save()

        XCTAssertTrue(
            try cookRepo.savedMealEntries(for: household).isEmpty,
            "Favorite-only legacy rows should not surface after SCA-151 drops the isFavorite predicate fallback.",
        )

        _ = solveRepo.setFavorite(false, on: plan)
        XCTAssertFalse(plan.isFavorite)
        XCTAssertTrue(plan.isSaved, "setFavorite(false) must migrate pre-fix rows to isSaved=true")

        XCTAssertEqual(
            try cookRepo.savedMealEntries(for: household).map(\.title), ["Pre-fix Pierogi"],
            "Pre-fix favorited row must remain in Saved after an explicit unfavorite migration.",
        )
    }

    // MARK: - Predicate stays open to historical rows + cooked-only path

    func test_neverFavoritedNeverCookedPlanIsExcluded() throws {
        // Pre-fix invariant: dinner-solve outputs that the user never
        // engaged with don't auto-fill Saved.
        _ = makePlan(title: "Untouched solve output")
        let entries = try cookRepo.savedMealEntries(for: household)
        XCTAssertTrue(entries.isEmpty)
    }

    func test_softDeletedPlanIsExcludedEvenIfSaved() throws {
        let plan = makePlan(title: "Trashed Tagine")
        _ = solveRepo.setFavorite(true, on: plan)
        XCTAssertEqual(try cookRepo.savedMealEntries(for: household).count, 1)

        XCTAssertTrue(solveRepo.softDelete(plan))
        XCTAssertTrue(try cookRepo.savedMealEntries(for: household).isEmpty)
    }

    func test_completedSessionMarksPlanIsSaved() throws {
        // Cooked-only path: meal cooked once, never favorited, must
        // stick in Saved on re-launch (covered today by the
        // SUBQUERY clause + the new isSaved write).
        let plan = makePlan(title: "Skillet Cornbread")
        let session = try cookRepo.createSession(on: household, for: plan, entryPoint: .solve)
        try cookRepo.markCompleted(session)
        XCTAssertTrue(plan.isSaved, "markCompleted must promote isSaved")

        let entries = try cookRepo.savedMealEntries(for: household)
        XCTAssertEqual(entries.map(\.title), ["Skillet Cornbread"])
    }

    // MARK: - Helpers

    private func makePlan(title: String) -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = title
        plan.typedOrigin = .ai
        plan.isFavorite = false
        plan.isSaved = false
        plan.servings = 2
        plan.difficulty = 2
        plan.estimatedMinutes = 25
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try? context.save()
        return plan
    }
}
