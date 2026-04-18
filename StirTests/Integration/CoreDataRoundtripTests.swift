// CoreDataRoundtripTests
//
// Exercises HouseholdProfile + DietaryRule + KitchenEquipment through the
// persistence controller (in-memory store). Cascade-delete, uniqueness,
// typed extension getters/setters.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class CoreDataRoundtripTests: XCTestCase {
    private var controller: PersistenceController!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
    }

    func test_householdProfile_createAndRead() async throws {
        let repo = HouseholdProfileRepository(controller: controller)
        let key = "install:\(UUID().uuidString)"
        let profile = try repo.ensureHouseholdProfile(for: key)

        XCTAssertEqual(profile.canonicalUserKey, key)
        XCTAssertFalse(profile.onboardingCompleted)
        XCTAssertEqual(profile.servingsDefault, 2)
        XCTAssertEqual(profile.typedPreferredUnits, .imperial)
        XCTAssertNotNil(profile.createdAt)
        XCTAssertEqual(profile.dietaryRuleArray.count, 0)
    }

    func test_householdProfile_ensureIsIdempotent() async throws {
        let repo = HouseholdProfileRepository(controller: controller)
        let key = "install:\(UUID().uuidString)"
        let first = try repo.ensureHouseholdProfile(for: key)
        let second = try repo.ensureHouseholdProfile(for: key)
        XCTAssertEqual(first.objectID, second.objectID)
    }

    func test_dietaryRule_uniqueConstraintEnforcedInRepo() async throws {
        let profileRepo = HouseholdProfileRepository(controller: controller)
        let ruleRepo = DietaryRuleRepository(controller: controller)
        let profile = try profileRepo.ensureHouseholdProfile(for: "install:\(UUID().uuidString)")

        _ = try ruleRepo.add(to: profile, kind: .allergy, value: "peanut")
        _ = try ruleRepo.add(to: profile, kind: .allergy, value: "peanut")  // should no-op

        let rules = profile.dietaryRuleArray.filter { $0.isActive && $0.typedKind == .allergy }
        XCTAssertEqual(rules.count, 1)
    }

    func test_kitchenEquipment_setAvailabilityUpsertsIdempotently() async throws {
        let profileRepo = HouseholdProfileRepository(controller: controller)
        let equipmentRepo = KitchenEquipmentRepository(controller: controller)
        let profile = try profileRepo.ensureHouseholdProfile(for: "install:\(UUID().uuidString)")

        _ = try equipmentRepo.setAvailability(true, code: .oven, on: profile)
        _ = try equipmentRepo.setAvailability(true, code: .oven, on: profile)
        _ = try equipmentRepo.setAvailability(false, code: .oven, on: profile)

        let rows = profile.kitchenEquipmentArray.filter { $0.code == "oven" }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.isAvailable, false)
    }

    func test_cascadeDelete_householdRemovesChildren() async throws {
        let profileRepo = HouseholdProfileRepository(controller: controller)
        let ruleRepo = DietaryRuleRepository(controller: controller)
        let equipmentRepo = KitchenEquipmentRepository(controller: controller)
        let profile = try profileRepo.ensureHouseholdProfile(for: "install:\(UUID().uuidString)")

        _ = try ruleRepo.add(to: profile, kind: .allergy, value: "peanut")
        _ = try equipmentRepo.setAvailability(true, code: .oven, on: profile)

        let context = controller.viewContext
        context.delete(profile)
        try controller.save()

        // Check that no orphan DietaryRule / KitchenEquipment rows remain.
        let ruleRequest = NSFetchRequest<DietaryRule>(entityName: "DietaryRule")
        let equipmentRequest = NSFetchRequest<KitchenEquipment>(entityName: "KitchenEquipment")
        XCTAssertEqual(try context.count(for: ruleRequest), 0)
        XCTAssertEqual(try context.count(for: equipmentRequest), 0)
    }
}
