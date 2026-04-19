// SubstitutionEvent type-safety extensions.
//
// Mirrors spec §4.14 (`accepted Bool?`). The Core Data column is a
// String enum with three values to avoid the CloudKit-unfriendly
// nullable-Bool pattern. Public API exposes `Bool?` for the Sheet view
// model so callers don't need to know about the encoding.
//
// Step-4 adds `missingIngredientDisplayName` beyond the spec — captures
// the free-text case where the user's problem isn't tied to a picker-
// selected RecipeIngredient ("my blender broke").

import CoreData
import Foundation

extension SubstitutionEvent {
    enum Acceptance: String, CaseIterable, Sendable {
        case pending = ""      // not yet decided
        case accepted
        case rejected
    }

    var typedAcceptance: Acceptance {
        get { acceptance.flatMap(Acceptance.init(rawValue:)) ?? .pending }
        set { acceptance = newValue.rawValue }
    }

    /// Public-facing `Bool?` projection of the internal enum.
    ///   nil    — pending
    ///   true   — accepted
    ///   false  — rejected
    var acceptedBool: Bool? {
        get {
            switch typedAcceptance {
            case .pending: return nil
            case .accepted: return true
            case .rejected: return false
            }
        }
        set {
            switch newValue {
            case .none: typedAcceptance = .pending
            case .some(true): typedAcceptance = .accepted
            case .some(false): typedAcceptance = .rejected
            }
        }
    }

    /// Human-readable label of the missing item — falls back to the
    /// free-text column when no RecipeIngredient was picker-selected.
    var missingLabel: String {
        if let named = recipeIngredient?.displayName, !named.isEmpty { return named }
        return missingIngredientDisplayName ?? ""
    }
}
