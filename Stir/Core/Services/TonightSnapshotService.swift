// TonightSnapshotService
//
// Projects the main app's latest solve state into the App-Group-shared
// TonightSnapshot that StirWidgets reads on every timeline refresh.
//
// Write flow:
//   SolveViewModel.persistCompletedSolve
//     → TonightSnapshotService.write(slots:solveId:)
//     → SharedStorage.writeTonight(...)
//     → WidgetCenter.shared.reloadAllTimelines()
//
// Staleness boundary: a successful solve overwrites the snapshot. A
// failed solve (slot errors, zero dishes) is a no-op — the widget keeps
// showing the previous valid idea.

import Foundation
import WidgetKit

@MainActor
struct TonightSnapshotService {
    private let storage: SharedStorage
    private let reloadTimelines: () -> Void

    init(
        storage: SharedStorage = SharedStorage(),
        reloadTimelines: @escaping () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
    ) {
        self.storage = storage
        self.reloadTimelines = reloadTimelines
    }

    /// Persist the top-3 dish brief from a just-completed solve. Pass the
    /// SolveViewModel's `slots` (rank-ordered) + the persisted
    /// MealSolveRequest id + the persisted SuggestedDish ids (sorted by
    /// rank, 1..3). No-op when fewer than one dish has been produced.
    func write(
        solveId: UUID,
        suggestedDishIds: [UUID],
        dishes: [DishProjection],
    ) {
        guard !dishes.isEmpty else { return }
        let briefs = zip(dishes.prefix(3), suggestedDishIds.prefix(3)).map { dish, id in
            TonightSnapshot.DishBrief(
                id: id,
                title: dish.title,
                subtitle: Self.subtitle(timeMin: dish.totalTimeMin, ingredientCount: dish.ingredientCount),
                totalTimeMin: dish.totalTimeMin,
                keyIngredients: Array(dish.ingredientNames.prefix(2)),
                heroEmoji: Self.heroEmoji(for: dish.cuisine),
            )
        }
        let snapshot = TonightSnapshot(
            solveId: solveId,
            capturedAt: Date(),
            topDishes: Array(briefs),
        )
        storage.writeTonight(snapshot)
        reloadTimelines()
    }

    /// Clear the snapshot. Used on logout or "delete account" flows.
    func clear() {
        storage.writeTonight(nil)
        reloadTimelines()
    }

    // MARK: - Projection

    /// Narrow shape SolveViewModel passes in. Keeping SolveViewModel
    /// from depending on TonightSnapshot directly (that type lives in
    /// Shared/ which is a wider compile surface).
    struct DishProjection {
        let title: String
        let totalTimeMin: Int
        let ingredientCount: Int
        let ingredientNames: [String]
        let cuisine: String?
    }

    // MARK: - Helpers

    static func subtitle(timeMin: Int, ingredientCount: Int) -> String {
        let ings = ingredientCount == 1 ? "1 ingredient" : "\(ingredientCount) ingredients"
        return "\(timeMin) min · \(ings)"
    }

    /// Cheap cuisine → emoji mapping. Widget can't download remote
    /// images and per-dish artwork isn't v1 scope, so we classify on
    /// cuisine and fall back to a generic plate. Step 8 can enrich
    /// once we have a proper palette of hero glyphs.
    static func heroEmoji(for cuisine: String?) -> String {
        guard let raw = cuisine?.lowercased() else { return "🍽️" }
        switch raw {
        case "italian", "pasta":        return "🍝"
        case "mexican", "tex-mex":      return "🌮"
        case "chinese", "asian":        return "🥡"
        case "japanese":                return "🍱"
        case "thai":                    return "🍜"
        case "indian":                  return "🍛"
        case "american", "bbq":         return "🍔"
        case "mediterranean", "greek":  return "🥗"
        case "breakfast":               return "🍳"
        case "soup":                    return "🥣"
        case "salad":                   return "🥗"
        case "dessert":                 return "🍰"
        case "seafood", "fish":         return "🐟"
        default:                        return "🍽️"
        }
    }
}
