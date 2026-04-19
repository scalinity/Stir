// MealSolveRequest type-safety + JSON encode/decode helpers.
//
// Binary attributes (constraintJSON, pantrySnapshotJSON, sourceAssetIdsJSON)
// persist structured data without custom Core Data transformers — simplest
// path that keeps NSPersistentCloudKitContainer happy.

import CoreData
import Foundation

extension MealSolveRequest {
    enum Status: String, CaseIterable, Sendable {
        case pending
        case streaming   // SSE open, dishes arriving
        case completed   // all dishes received; user selected one (if any)
        case failed      // AI-01 / AI-02 during solve
    }

    var typedStatus: Status {
        get { status.flatMap(Status.init(rawValue:)) ?? .pending }
        set { status = newValue.rawValue }
    }

    var isSoftDeleted: Bool { deletedAt != nil }

    /// Ranked array of associated SuggestedDishes.
    var suggestedDishArray: [SuggestedDish] {
        let set = suggestedDishes as? Set<SuggestedDish> ?? []
        return set.sorted { $0.rank < $1.rank }
    }

    // --- Typed JSON getters/setters --------------------------------------

    struct Constraints: Codable, Sendable, Equatable {
        var maxTimeMinutes: Int?
        var cuisineLeaning: String?
        var useFirst: [String]?
        var avoidEquipment: [String]?
        var goal: String?

        enum CodingKeys: String, CodingKey {
            case maxTimeMinutes = "max_time_minutes"
            case cuisineLeaning = "cuisine_leaning"
            case useFirst = "use_first"
            case avoidEquipment = "avoid_equipment"
            case goal
        }
    }

    struct PantrySnapshot: Codable, Sendable, Equatable {
        var ingredients: [Ingredient]

        struct Ingredient: Codable, Sendable, Equatable {
            var displayName: String
            var canonicalSlug: String?
            var amountText: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case canonicalSlug = "canonical_slug"
                case amountText = "amount_text"
            }
        }
    }

    var typedConstraints: Constraints? {
        get {
            guard let data = constraintJSON else { return nil }
            return try? JSONDecoder().decode(Constraints.self, from: data)
        }
        set {
            constraintJSON = (newValue.flatMap { try? JSONEncoder().encode($0) })
        }
    }

    var typedPantrySnapshot: PantrySnapshot? {
        get {
            guard let data = pantrySnapshotJSON else { return nil }
            return try? JSONDecoder().decode(PantrySnapshot.self, from: data)
        }
        set {
            pantrySnapshotJSON = (newValue.flatMap { try? JSONEncoder().encode($0) })
        }
    }

    var typedSourceAssetIds: [UUID] {
        get {
            guard let data = sourceAssetIdsJSON else { return [] }
            return (try? JSONDecoder().decode([UUID].self, from: data)) ?? []
        }
        set {
            sourceAssetIdsJSON = try? JSONEncoder().encode(newValue)
        }
    }
}
