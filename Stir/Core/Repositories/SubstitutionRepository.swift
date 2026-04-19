// SubstitutionRepository
//
// Persists SubstitutionEvent rows per spec §4.14 with our step-4
// extension: `missingIngredientDisplayName` captures the free-text
// ingredient case (user types "I don't have a blender" or "my stock
// went bad") that isn't tied to a picker-selected RecipeIngredient.
//
// Dual-write rule (confirmed by Daniel in scope alignment):
//   - Picker-selected → `recipeIngredient` FK set, displayName column nil
//   - Free-text → `recipeIngredient` nil, displayName set to user's label
//
// SubstitutionEvent.missingLabel computed prop hides this behind a
// single API so the UI doesn't branch.

import CoreData
import Foundation

@MainActor
final class SubstitutionRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    // Not Sendable: holds NSManagedObject refs (CookingSession, RecipeIngredient,
    // RecipeStep) which aren't Sendable. SubstitutionRepository runs entirely
    // on @MainActor, so the struct is only ever constructed and consumed
    // on the main actor — Sendable isn't needed.
    struct PersistInput {
        let subEventId: UUID
        let session: CookingSession
        /// Picker-selected ingredient (mutually exclusive with freeTextName).
        let ingredient: RecipeIngredient?
        /// Free-text ingredient/equipment label (used when ingredient == nil).
        let freeTextName: String?
        /// Step the user was on when they asked.
        let step: RecipeStep?
        let userProblemText: String
        let modelSuggestionText: String
        let hardConstraintCheckPassed: Bool
    }

    @discardableResult
    func persist(_ input: PersistInput) throws -> SubstitutionEvent {
        let context = controller.viewContext
        let event = SubstitutionEvent(context: context)
        event.id = input.subEventId
        event.cookingSession = input.session
        event.recipeIngredient = input.ingredient
        event.step = input.step
        event.userProblemText = input.userProblemText
        event.modelSuggestionText = input.modelSuggestionText
        event.hardConstraintCheckPassed = input.hardConstraintCheckPassed
        event.createdAt = Date()
        event.typedAcceptance = .pending

        // Only set missingIngredientDisplayName when there's no FK — keeps
        // the picker-selected read path clean (UI reads ingredient.displayName
        // via the FK, not the denormalized copy).
        if input.ingredient == nil, let freeText = input.freeTextName, !freeText.isEmpty {
            event.missingIngredientDisplayName = freeText
        }
        try controller.save()
        return event
    }

    /// Record the user's Accept / Reject decision after reviewing the
    /// suggestion. `accepted == nil` is the pending/undecided state (never
    /// expected to be written through this method — use `persist` for that).
    func recordDecision(
        _ event: SubstitutionEvent,
        accepted: Bool?,
        acceptedAlternativeText: String? = nil,
    ) throws {
        event.acceptedBool = accepted
        event.acceptedAlternativeText = acceptedAlternativeText
        try controller.save()
    }
}
