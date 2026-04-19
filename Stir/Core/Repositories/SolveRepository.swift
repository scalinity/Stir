// SolveRepository
//
// Persists a complete MealSolveRequest with its SuggestedDish[] and
// the RecipePlan (+ RecipeIngredient[] + RecipeStep[]) each dish references.
//
// Step-3 scope: write-only. Read + replay of past solves comes in step 4
// when Tonight Home's "Recent" section lands for real.
//
// Everything commits in ONE viewContext save so a partially-persisted
// solve never surfaces (e.g. MealSolveRequest without its dishes).

import CoreData
import Foundation
import OSLog

@MainActor
final class SolveRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    // MARK: - Input shapes (from SolveViewModel's streaming accumulator)

    struct DishInput: Sendable {
        let rank: Int
        let title: String
        let summary: String
        let totalTimeMinutes: Int
        let fitLabelPrimary: SuggestedDish.FitLabel
        let fitLabelSecondary: SuggestedDish.FitLabel?
        let missingIngredientCount: Int
        let hardConstraintPass: Bool
        let reasoningSummary: String
        let confidence: Double
        let recipePlan: RecipePlanInput
    }

    struct RecipePlanInput: Sendable {
        let title: String
        let summary: String
        let servings: Int
        let difficulty: Int
        let estimatedMinutes: Int
        let cuisine: String?
        let aiVersion: String
        let ingredients: [IngredientInput]
        let steps: [StepInput]
    }

    struct IngredientInput: Sendable {
        let displayName: String
        let canonicalSlug: String?
        let amountText: String
        let isOptional: Bool
    }

    struct StepInput: Sendable {
        let stepNumber: Int
        let instructionText: String
        let timerSeconds: Int?
        let cautionTags: [String]
    }

    struct SolveOutcome: Sendable {
        let solveRequestId: UUID
        let suggestedDishIds: [UUID]
    }

    // MARK: - Create

    /// Persist an AI dinner-solve outcome. Returns identifiers for in-memory
    /// routing (DishPreview deep-link) while the NSManagedObjects live in
    /// viewContext.
    @discardableResult
    func createSolveWithDishes(
        on household: HouseholdProfile,
        constraints: MealSolveRequest.Constraints?,
        pantrySnapshot: MealSolveRequest.PantrySnapshot,
        dishes: [DishInput],
        aiRequestId: String?,
    ) throws -> SolveOutcome {
        let context = controller.viewContext
        let now = Date()

        let solve = MealSolveRequest(context: context)
        solve.id = UUID()
        solve.household = household
        solve.requestedAt = now
        solve.completedAt = dishes.isEmpty ? nil : now
        solve.typedStatus = dishes.isEmpty ? .failed : .completed
        solve.aiRequestId = aiRequestId
        solve.typedConstraints = constraints
        solve.typedPantrySnapshot = pantrySnapshot

        var dishIds: [UUID] = []

        for dish in dishes.sorted(by: { $0.rank < $1.rank }) {
            let recipe = RecipePlan(context: context)
            recipe.id = UUID()
            recipe.household = household
            recipe.title = dish.recipePlan.title
            recipe.summary = dish.recipePlan.summary
            recipe.servings = Int16(dish.recipePlan.servings)
            recipe.difficulty = Int16(dish.recipePlan.difficulty)
            recipe.estimatedMinutes = Int16(dish.recipePlan.estimatedMinutes)
            recipe.cuisine = dish.recipePlan.cuisine
            recipe.aiVersion = dish.recipePlan.aiVersion
            recipe.typedOrigin = .ai
            recipe.isFavorite = false
            recipe.isSaved = false
            recipe.createdAt = now
            recipe.updatedAt = now

            for (idx, ing) in dish.recipePlan.ingredients.enumerated() {
                let row = RecipeIngredient(context: context)
                row.id = UUID()
                row.recipePlan = recipe
                row.displayName = ing.displayName
                row.canonicalIngredientSlug = ing.canonicalSlug
                row.amountText = ing.amountText
                row.isOptional = ing.isOptional
                row.sortOrder = Int16(idx)
                row.typedSource = .ai
            }

            for step in dish.recipePlan.steps {
                let row = RecipeStep(context: context)
                row.id = UUID()
                row.recipePlan = recipe
                row.stepNumber = Int16(step.stepNumber)
                row.sortOrder = Int16(step.stepNumber)
                row.instructionText = step.instructionText
                row.timerSeconds = Int32(step.timerSeconds ?? 0)
                row.cautionTagsArray = step.cautionTags
            }

            let suggested = SuggestedDish(context: context)
            let dishId = UUID()
            dishIds.append(dishId)
            suggested.id = dishId
            suggested.solveRequest = solve
            suggested.recipePlan = recipe
            suggested.rank = Int16(dish.rank)
            suggested.title = dish.title
            suggested.summary = dish.summary
            suggested.estimatedMinutes = Int16(dish.totalTimeMinutes)
            suggested.typedFitLabelPrimary = dish.fitLabelPrimary
            suggested.typedFitLabelSecondary = dish.fitLabelSecondary
            suggested.missingIngredientCount = Int16(dish.missingIngredientCount)
            suggested.hardConstraintPass = dish.hardConstraintPass
            suggested.reasoningSummary = dish.reasoningSummary
            suggested.confidence = dish.confidence
        }

        try controller.save()
        Logger.coreData.info("SolveRepository persisted \(dishes.count, privacy: .public)-dish solve")
        // solve.id was assigned unconditionally at the top of this function;
        // force-unwrap surfaces an invariant violation loudly if Core Data
        // ever nils it (should never happen) instead of silently generating
        // a different UUID the persistent store doesn't know about.
        guard let solveID = solve.id else {
            throw StirError.coreData(underlying: NSError(
                domain: "SolveRepository",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "post-save solve.id is nil"],
            ))
        }
        return SolveOutcome(solveRequestId: solveID, suggestedDishIds: dishIds)
    }

    /// Mark a SuggestedDish as selected by the user. Used by DishPreview's
    /// Start Cooking CTA (step 4 replaces the disabled stub).
    func markSelected(
        _ dish: SuggestedDish,
        on solve: MealSolveRequest,
    ) throws {
        dish.selectedAt = Date()
        solve.selectedSuggestedDishId = dish.id
        try controller.save()
    }

    /// Fetch the RecipePlan linked to a previously-persisted
    /// SuggestedDish. Used by DishPreview when presenting Cook Mode.
    /// Returns nil if the dish row was deleted or the relationship
    /// was nullified (e.g. RecipePlan hard-delete).
    func fetchRecipePlan(forSuggestedDishId id: UUID) -> RecipePlan? {
        let request = NSFetchRequest<SuggestedDish>(entityName: "SuggestedDish")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        request.relationshipKeyPathsForPrefetching = ["recipePlan"]
        return (try? controller.viewContext.fetch(request).first)?.recipePlan
    }
}
