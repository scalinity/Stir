// SubstitutionRepository
//
// Persists SubstitutionEvent rows per spec §4.14 with our step-4
// extension: `missingIngredientDisplayName` captures the original
// missing-ingredient name AT PERSIST TIME — for free-text events
// (e.g. "my blender broke") and for picker-selected events alike.
// Snapshotting the picker-selected case is necessary because
// `applyAcceptedSwap` mutates the linked RecipeIngredient.displayName
// in place after acceptance, overwriting the only other record of
// what the user originally substituted out. Without the snapshot,
// the StepCardView swap badge ("X (was: Y)") loses Y.
//
// SubstitutionEvent.missingLabel computed prop reads the snapshot
// first; the FK's live displayName is the post-swap name.

import CoreData
import Foundation

@MainActor
final class SubstitutionRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
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

        // Snapshot the original missing-ingredient name for both code paths.
        // FK path: capture ingredient.displayName BEFORE applyAcceptedSwap
        // can mutate it, so the swap badge can render "X (was: Y)" after
        // acceptance.
        // Free-text path: capture the user's typed label so missingLabel
        // has something to return.
        if let ingredient = input.ingredient,
           let name = ingredient.displayName,
           !name.isEmpty
        {
            event.missingIngredientDisplayName = name
        } else if let freeText = input.freeTextName, !freeText.isEmpty {
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

    /// Apply an accepted substitution to the recipe by mutating the linked
    /// RecipeIngredient in place. Without this, the swap is recorded as a
    /// SubstitutionEvent for history but invisible to every downstream
    /// consumer: the substitution picker still lists the original name, the
    /// voice context's `remainingIngredients` still references the old
    /// ingredient, and a re-opened sheet would offer the same swap again.
    ///
    ///   - displayName: replaced with `acceptedAlternativeText`
    ///   - amountText: replaced with `amountConversion` when non-nil; the
    ///     original amount stays when the model didn't supply a conversion
    ///     (e.g. "use the same amount of rice noodles for dried pasta")
    ///   - canonicalIngredientSlug: nilled — the slug encoded the original
    ///     ingredient's identity and no longer matches the swapped name
    ///
    /// Free-text events (`recipeIngredient == nil`, e.g. "my blender broke")
    /// are no-ops — there's nothing to mutate. The SubstitutionEvent itself
    /// captures the swap for those.
    ///
    /// Step instruction text is intentionally untouched: it's frozen prose
    /// referencing the original ingredient. Auto-rewriting would require an
    /// extra AI call per accept and is out of scope.
    func applyAcceptedSwap(
        _ event: SubstitutionEvent,
        substitutionText: String,
        amountConversion: String?,
    ) throws {
        guard let ingredient = event.recipeIngredient else { return }
        ingredient.displayName = substitutionText
        if let amount = amountConversion?.trimmingCharacters(in: .whitespacesAndNewlines),
           !amount.isEmpty
        {
            ingredient.amountText = amount
        }
        ingredient.canonicalIngredientSlug = nil
        try controller.save()
    }
}
