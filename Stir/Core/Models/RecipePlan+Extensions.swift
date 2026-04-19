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
