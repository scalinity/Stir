// GroceryList+Extensions
//
// Spec §4.16 — soft delete, CloudKit-synced, status enum exactly
// `{draft, exported}` (no other values). Transitions:
//   draft → exported  on successful EventKit export
//   draft → (stays)   if Reminders permission denied
// No un-export transition; the row stays exported even if the user
// deletes the Reminders list downstream.

import Foundation

public enum GroceryListStatus: String, Sendable, CaseIterable {
    case draft
    case exported
}

public extension GroceryList {
    /// Typed read; unknown values fall back to `.draft` — a corrupted
    /// status field should not advertise an export that never happened.
    var statusEnum: GroceryListStatus {
        GroceryListStatus(rawValue: status ?? "") ?? .draft
    }

    func setStatus(_ value: GroceryListStatus) {
        self.status = value.rawValue
    }

    /// Sort items by sortOrder ascending. The Core Data relationship is
    /// an `NSSet` so callers must sort explicitly — centralized here to
    /// avoid drift.
    var orderedItems: [GroceryItem] {
        let items = (items as? Set<GroceryItem>) ?? []
        return items.sorted { (lhs, rhs) in
            if lhs.sortOrder == rhs.sortOrder {
                return (lhs.displayName ?? "") < (rhs.displayName ?? "")
            }
            return lhs.sortOrder < rhs.sortOrder
        }
    }
}
