import CoreData
import XCTest
@testable import Stir

@MainActor
final class HouseholdIdentityReconciliationTests: XCTestCase {
    func test_installPromotionRetainsContentAndCompletedPreferences() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        let source = try repo.ensureHouseholdProfile(for: "install:own-install")
        let recipe = RecipePlan(context: controller.viewContext)
        recipe.id = UUID()
        recipe.household = source
        let rule = try DietaryRuleRepository(controller: controller).add(to: source, kind: .allergy, value: "peanut", severity: .hard)
        try repo.markOnboardingComplete(source)

        let result = try repo.ensureHouseholdProfile(for: "ck:account", promotingInstallationKey: "install:own-install")

        XCTAssertEqual(result.objectID, source.objectID)
        XCTAssertEqual(recipe.household, result)
        XCTAssertEqual(rule.household, result)
        XCTAssertTrue(result.onboardingCompleted)
        XCTAssertNil(try repo.findExisting(for: "install:own-install"))
    }

    func test_existingCloudTargetMergesBothGraphsAndKeepsStableRoot() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        let target = try repo.ensureHouseholdProfile(for: "ck:account")
        target.createdAt = Date(timeIntervalSince1970: 10)
        let source = try repo.ensureHouseholdProfile(for: "install:own-install")
        source.createdAt = Date(timeIntervalSince1970: 20)
        source.servingsDefault = 5
        source.preferredUnits = "metric"
        try repo.markOnboardingComplete(source)
        let recipe = RecipePlan(context: controller.viewContext)
        recipe.id = UUID()
        recipe.household = target
        let pantry = PantryItem(context: controller.viewContext)
        pantry.id = UUID()
        pantry.household = source
        try controller.save()

        let result = try repo.ensureHouseholdProfile(for: "ck:account", promotingInstallationKey: "install:own-install")

        XCTAssertEqual(result.objectID, target.objectID)
        XCTAssertEqual(recipe.household, target)
        XCTAssertEqual(pantry.household, target)
        XCTAssertEqual(result.servingsDefault, 5)
        XCTAssertEqual(result.preferredUnits, "metric")
        XCTAssertTrue(result.onboardingCompleted)
        XCTAssertFalse(source.isDeleted, "Keep the duplicate root for late imports")
        XCTAssertEqual(try repo.reconcileProfiles(for: "ck:account")?.objectID, result.objectID)
    }

    func test_delayedDuplicateAndLateChildReconcileWithoutReactivatingRules() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        let first = try repo.ensureHouseholdProfile(for: "ck:account")
        first.createdAt = Date(timeIntervalSince1970: 10)
        let duplicate = HouseholdProfile(context: controller.viewContext)
        duplicate.id = UUID()
        duplicate.canonicalUserKey = "ck:account"
        duplicate.createdAt = Date(timeIntervalSince1970: 20)
        let older = try DietaryRuleRepository(controller: controller).add(to: duplicate, kind: .diet, value: "vegan")
        older.updatedAt = Date(timeIntervalSince1970: 30)
        let newer = try DietaryRuleRepository(controller: controller).add(to: first, kind: .diet, value: "vegan")
        newer.isActive = false
        newer.updatedAt = Date(timeIntervalSince1970: 40)
        let unique = try DietaryRuleRepository(controller: controller).add(to: duplicate, kind: .allergy, value: "peanut", severity: .hard)
        try controller.save()

        XCTAssertEqual(try repo.reconcileProfiles(for: "ck:account"), first)
        XCTAssertEqual(first.dietaryRuleArray.count, 2)
        XCTAssertFalse(try XCTUnwrap(first.dietaryRuleArray.first { $0.value == "vegan" }).isActive)
        XCTAssertEqual(unique.household, first)
        let lateRecipe = RecipePlan(context: controller.viewContext)
        lateRecipe.id = UUID()
        lateRecipe.household = duplicate
        let latePantry = PantryItem(context: controller.viewContext)
        latePantry.id = UUID()
        latePantry.household = duplicate
        try controller.save()

        XCTAssertEqual(try repo.reconcileProfiles(for: "ck:account"), first)
        XCTAssertEqual(lateRecipe.household, first)
        XCTAssertEqual(latePantry.household, first)
        XCTAssertFalse(duplicate.isDeleted)
    }

    func test_equalCreationDatesUseUUIDAndSeparateCloudAccounts() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        let first = try repo.ensureHouseholdProfile(for: "ck:A")
        first.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        first.createdAt = Date(timeIntervalSince1970: 10)
        let duplicate = HouseholdProfile(context: controller.viewContext)
        duplicate.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        duplicate.createdAt = first.createdAt
        duplicate.canonicalUserKey = "ck:A"
        let other = try repo.ensureHouseholdProfile(for: "ck:B")
        let recipe = RecipePlan(context: controller.viewContext)
        recipe.id = UUID()
        recipe.household = first
        try controller.save()

        XCTAssertEqual(try repo.reconcileProfiles(for: "ck:A"), first)
        XCTAssertEqual(try repo.ensureHouseholdProfile(for: "ck:B"), other)
        XCTAssertEqual(recipe.household, first)
        XCTAssertNotEqual(first.objectID, other.objectID)
    }
}
