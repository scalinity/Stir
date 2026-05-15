// RecipePlan + RecipeIngredient + RecipeStep type-safety extensions.

import CoreData
import Foundation

extension RecipePlan {
    enum Origin: String, CaseIterable, Sendable {
        case ai      // dinner_solve output
        case imported  // step 7 — recipe import
        case manual  // user-created
    }

    var typedOrigin: Origin {
        get { origin.flatMap(Origin.init(rawValue:)) ?? .ai }
        set { origin = newValue.rawValue }
    }

    var isSoftDeleted: Bool { deletedAt != nil }

    /// Ingredients sorted by sortOrder ascending.
    var ingredientArray: [RecipeIngredient] {
        let set = ingredients as? Set<RecipeIngredient> ?? []
        return set.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Steps sorted by stepNumber ascending (sortOrder fallback on tie).
    var stepArray: [RecipeStep] {
        let set = steps as? Set<RecipeStep> ?? []
        return set.sorted { (a, b) in
            if a.stepNumber != b.stepNumber { return a.stepNumber < b.stepNumber }
            return a.sortOrder < b.sortOrder
        }
    }

    /// SCA-425 / SCA-431: canonical projection of recipe steps into
    /// the substitution endpoint's `recipe_steps` wire shape. Consumed
    /// by BOTH the sheet path
    /// (`SubstitutionSheetViewModel.buildRecipeContext`) and the
    /// voice-path function-call dispatch
    /// (`RealtimeSessionTransport.dispatchSubstitution`). Pre-SCA-431
    /// each call site re-implemented this 15-line projection — the
    /// same drift class that produced SCA-424. Centralising keeps the
    /// two AI invocation paths in lockstep.
    ///
    /// Per-step rules:
    ///   - Empty / whitespace-only `instructionText` is dropped
    ///     (backend Zod enforces `instruction.min(1)`).
    ///   - `instructionText` over 2000 chars is clamped to 2000
    ///     (backend Zod is `.max(2000)`). Imported recipes routinely
    ///     have long steps; client-side clamping is friendlier than a
    ///     VAL-01.
    ///   - `timerSeconds == 0` (Core Data default for untimed steps)
    ///     becomes JSON `null` so the model gets an explicit
    ///     "untimed" signal rather than reading 0 as a 0-second timer.
    ///   - Negative `timerSeconds` (data-corruption case) is mapped to
    ///     nil; should never appear in practice.
    ///
    /// `stepArray` is already sorted by stepNumber, so callers don't
    /// need to re-sort the returned array.
    func substitutionRecipeSteps() -> [SubstitutionRequest.RecipeContext.RecipeStep] {
        stepArray.compactMap { step in
            let raw = step.instructionText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { return nil }
            let instruction = raw.count > 2000
                ? String(raw.prefix(2000))
                : raw
            let timer = Int(step.timerSeconds)
            return SubstitutionRequest.RecipeContext.RecipeStep(
                stepNumber: Int(step.stepNumber),
                instruction: instruction,
                timerSeconds: timer > 0 ? timer : nil,
            )
        }
    }
}

extension RecipeIngredient {
    enum Source: String, CaseIterable, Sendable {
        case ai
        case imported
        case manual
    }

    var typedSource: Source {
        get { source.flatMap(Source.init(rawValue:)) ?? .ai }
        set { source = newValue.rawValue }
    }
}

extension RecipeStep {
    /// Caution tags are persisted as a comma-separated string
    /// (CloudKit-compatible, no custom transformers).
    var cautionTagsArray: [String] {
        get {
            guard let csv = cautionTagsCSV, !csv.isEmpty else { return [] }
            return csv.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        set {
            cautionTagsCSV = newValue.joined(separator: ",")
        }
    }
}
