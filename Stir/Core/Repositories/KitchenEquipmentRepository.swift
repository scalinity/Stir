// KitchenEquipmentRepository
//
// Manage equipment rows attached to a HouseholdProfile. Step-2 onboarding
// writes here from Setup 2. Spec §4.3 uniqueness `(household, code)` is
// enforced at this layer.

import CoreData
import Foundation

@MainActor
final class KitchenEquipmentRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController = .shared) {
        self.controller = controller
    }

    /// Ensure the given code exists on the household. Sets isAvailable to
    /// whatever the caller passes; idempotent.
    @discardableResult
    func setAvailability(
        _ isAvailable: Bool,
        code: KitchenEquipment.CommonCode,
        on profile: HouseholdProfile,
    ) throws -> KitchenEquipment {
        let rawCode = code.rawValue
        let context = controller.viewContext

        if let existing = profile.kitchenEquipmentArray.first(where: { $0.code == rawCode }) {
            if existing.isAvailable != isAvailable {
                existing.isAvailable = isAvailable
                existing.updatedAt = Date()
                try controller.save()
            }
            return existing
        }

        let equipment = KitchenEquipment(context: context)
        equipment.id = UUID()
        equipment.typedCode = code
        equipment.isAvailable = isAvailable
        let now = Date()
        equipment.createdAt = now
        equipment.updatedAt = now
        equipment.household = profile

        try controller.save()
        return equipment
    }

    /// Remove a row entirely (hard delete per spec §4.3).
    func delete(_ equipment: KitchenEquipment) throws {
        let context = controller.viewContext
        context.delete(equipment)
        try controller.save()
    }
}
