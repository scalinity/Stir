// HouseholdProfile type-safety extensions.
//
// Wraps the string-typed Core Data attribute `preferredUnits` in a typed enum
// and exposes deterministic accessors for the NSSet relationships. All heavy
// validation still lives in `HouseholdProfileRepository`; this file is about
// making the raw NSManagedObject ergonomic from Swift.

import CoreData
import Foundation

extension HouseholdProfile {
    enum PreferredUnits: String, CaseIterable, Sendable {
        case imperial
        case metric
    }

    var typedPreferredUnits: PreferredUnits {
        get { preferredUnits.flatMap(PreferredUnits.init(rawValue:)) ?? .imperial }
        set { preferredUnits = newValue.rawValue }
    }

    /// DietaryRule array derived from the NSSet relationship, sorted by `createdAt`.
    var dietaryRuleArray: [DietaryRule] {
        let set = dietaryRules as? Set<DietaryRule> ?? []
        return set.sorted { (a, b) in
            (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
        }
    }

    /// KitchenEquipment array derived from the NSSet relationship, sorted by `code`.
    var kitchenEquipmentArray: [KitchenEquipment] {
        let set = kitchenEquipment as? Set<KitchenEquipment> ?? []
        return set.sorted { (a, b) in (a.code ?? "") < (b.code ?? "") }
    }

    /// Whether the profile is soft-deleted (spec §4.1: deletedAt non-nil).
    var isSoftDeleted: Bool { deletedAt != nil }
}
