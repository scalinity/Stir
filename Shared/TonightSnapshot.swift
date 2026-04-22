// TonightSnapshot
//
// Anonymous snapshot of the latest MealSolveRequest's top
// SuggestedDish entries, sized for widget rendering. Written by
// SolveViewModel / TonightSnapshotService after every successful
// dinner-solve; read by StirWidgets.
//
// Payload size is intentionally tiny (3 dishes × ~6 fields each) so
// the App Group write stays under UserDefaults's cross-process sync
// threshold and the privacy surface is minimal. No ingredients beyond
// the 2 most prominent per dish, no instructions, no CloudKit ids that
// resolve outside the app.
//
// Matches spec §4.5 MealSolveRequest + §4.6 SuggestedDish field names
// (id, title, estimatedMinutes) — deliberately a projection, not a
// copy, so the widget schema can evolve independently of the entities.

import Foundation

public struct TonightSnapshot: Codable, Sendable, Equatable {
    public let solveId: UUID
    public let capturedAt: Date
    public let topDishes: [DishBrief]

    public init(solveId: UUID, capturedAt: Date, topDishes: [DishBrief]) {
        self.solveId = solveId
        self.capturedAt = capturedAt
        self.topDishes = topDishes
    }

    public struct DishBrief: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let title: String
        /// One-line summary, e.g. "35 min · 6 ingredients". Widget-ready.
        public let subtitle: String
        public let totalTimeMin: Int
        /// At most two entries — first-line widget view capacity.
        public let keyIngredients: [String]
        /// Emoji stand-in for a hero image; widgets can't download
        /// remote images and bundling per-dish artwork isn't v1 scope.
        public let heroEmoji: String

        public init(
            id: UUID,
            title: String,
            subtitle: String,
            totalTimeMin: Int,
            keyIngredients: [String],
            heroEmoji: String,
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.totalTimeMin = totalTimeMin
            self.keyIngredients = keyIngredients
            self.heroEmoji = heroEmoji
        }
    }
}
