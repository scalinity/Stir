// PantryItem type-safety extensions.
//
// Step-3 scope: scan → review → persist. Full CRUD + freshness decay lives
// in step 4 (saved meals) + step 7 (leftovers).

import CoreData
import Foundation

extension PantryItem {
    enum Source: String, CaseIterable, Sendable {
        case scan
        case manual
        case staple
        case `import`  // reserved name; swift backtick keeps the raw enum happy
    }

    enum MemoryState: String, CaseIterable, Sendable {
        case ephemeral   // remembered only for today
        case remembered  // standing pantry item
        case expired     // past expiresAt
        case unknown
    }

    enum ParseConfidence: String, Sendable {
        case confirmed
        case needsReview = "needs_review"
        case likelyStaple = "likely_staple"
    }

    var typedSource: Source {
        get { source.flatMap(Source.init(rawValue:)) ?? .manual }
        set { source = newValue.rawValue }
    }

    var typedMemoryState: MemoryState {
        get { memoryState.flatMap(MemoryState.init(rawValue:)) ?? .ephemeral }
        set { memoryState = newValue.rawValue }
    }

    var isSoftDeleted: Bool { deletedAt != nil }
}
