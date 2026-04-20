// GroceryItem+Extensions
//
// Spec §4.17 — priority is REQUIRED per spec; we enforce via repo
// insertion path (always set to one of three enum values). CloudKit
// syncable; hard-delete with parent list.

import Foundation

public enum GroceryItemPriority: String, Sendable, CaseIterable {
    case normal   // default
    case low      // optional garnish; "if you like"
    case high     // essential flavor-defining ingredient

    /// Display ordering — high first, low last.
    var sortRank: Int {
        switch self {
        case .high:   return 0
        case .normal: return 1
        case .low:    return 2
        }
    }
}

public enum GroceryCategory: String, Sendable, CaseIterable {
    case produce
    case dairy
    case meat
    case pantry
    case frozen
    case other

    /// Human-friendly aisle name for GroceryExportView grouping.
    var displayName: String {
        switch self {
        case .produce: return "Produce"
        case .dairy:   return "Dairy"
        case .meat:    return "Meat"
        case .pantry:  return "Pantry"
        case .frozen:  return "Frozen"
        case .other:   return "Other"
        }
    }

    /// Shopping-aisle order. Roughly inside-perimeter first.
    var aisleOrder: Int {
        switch self {
        case .produce: return 0
        case .meat:    return 1
        case .dairy:   return 2
        case .frozen:  return 3
        case .pantry:  return 4
        case .other:   return 5
        }
    }
}

public extension GroceryItem {
    var priorityEnum: GroceryItemPriority {
        GroceryItemPriority(rawValue: priority ?? "") ?? .normal
    }

    func setPriority(_ value: GroceryItemPriority) {
        self.priority = value.rawValue
    }

    var categoryEnum: GroceryCategory {
        GroceryCategory(rawValue: groceryCategory ?? "") ?? .other
    }

    func setCategory(_ value: GroceryCategory) {
        self.groceryCategory = value.rawValue
    }
}
