import CoreData
import XCTest
@testable import Stir

@MainActor
final class HouseholdDataDeletionServiceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "stir.deletion.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func test_scopedEraseCascadesContentAndKeepsOtherAccount() throws {
        let controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        let erased = try repo.ensureHouseholdProfile(for: "ck:A")
        let other = try repo.ensureHouseholdProfile(for: "ck:B")
        let recipe = RecipePlan(context: controller.viewContext)
        recipe.id = UUID()
        recipe.household = erased
        let step = RecipeStep(context: controller.viewContext)
        step.recipePlan = recipe
        let retained = PantryItem(context: controller.viewContext)
        retained.id = UUID()
        retained.household = other
        try controller.save()
        let service = HouseholdDataDeletionService(controller: controller, defaults: defaults())

        try service.erase(canonicalUserKey: "ck:A")

        XCTAssertNil(try repo.findExisting(for: "ck:A"))
        XCTAssertNotNil(erased.deletedAt)
        XCTAssertEqual(erased.recipePlans?.count, 0)
        XCTAssertEqual(try repo.findExisting(for: "ck:B"), other)
        XCTAssertEqual(retained.household, other)
        XCTAssertTrue(service.isAwaitingAcknowledgement(for: "ck:A"))
        XCTAssertNil(service.state(for: "ck:A")?.cloudExportedAt)
        XCTAssertEqual(try controller.viewContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "RecipeStep")), 0)
    }

    func test_markerSurvivesFailureRelaunchAndLateImportsAfterStartOver() throws {
        let controller = PersistenceController(inMemory: true)
        let storage = defaults()
        let repo = HouseholdProfileRepository(controller: controller)
        let old = try repo.ensureHouseholdProfile(for: "ck:A")
        let failed = HouseholdDataDeletionService(controller: controller, defaults: storage, save: {
            controller.viewContext.rollback()
            throw NSError(domain: "fixture.save", code: 1)
        })
        XCTAssertThrowsError(try failed.erase(canonicalUserKey: "ck:A"))
        XCTAssertTrue(failed.isAwaitingAcknowledgement(for: "ck:A"))

        let resumed = HouseholdDataDeletionService(controller: controller, defaults: storage)
        try resumed.resumeDeletion(for: "ck:A")
        XCTAssertNotNil(resumed.state(for: "ck:A")?.lastEraseSavedAt)
        resumed.acknowledgeDeletion(for: "ck:A")
        let replacement = try repo.ensureHouseholdProfile(for: "ck:A")
        let newRecipe = RecipePlan(context: controller.viewContext)
        newRecipe.id = UUID()
        newRecipe.household = replacement
        let lateRecipe = RecipePlan(context: controller.viewContext)
        lateRecipe.id = UUID()
        lateRecipe.household = old
        try controller.save()

        let relaunched = HouseholdDataDeletionService(controller: controller, defaults: storage)
        try relaunched.resumeDeletion(for: "ck:A")

        XCTAssertFalse(relaunched.isAwaitingAcknowledgement(for: "ck:A"))
        XCTAssertEqual(try repo.findExisting(for: "ck:A"), replacement)
        XCTAssertEqual(newRecipe.household, replacement)
        XCTAssertEqual(old.recipePlans?.count, 0)
        XCTAssertFalse(old.isDeleted)
    }

    func test_cloudAcknowledgementRequiresMatchingStoreAndLaterExport() throws {
        let controller = PersistenceController(inMemory: true)
        let household = try HouseholdProfileRepository(controller: controller).ensureHouseholdProfile(for: "ck:A")
        let store = try XCTUnwrap(household.objectID.persistentStore?.identifier)
        let service = HouseholdDataDeletionService(controller: controller, defaults: defaults())
        service.setCurrentIdentity("ck:A")
        try service.erase(canonicalUserKey: "ck:A")
        let savedAt = try XCTUnwrap(service.state(for: "ck:A")?.lastEraseSavedAt)

        service.recordSuccessfulExport(for: "ck:A", storeIdentifier: "other-store", startedAt: savedAt, endedAt: savedAt)
        service.recordSuccessfulExport(for: "ck:A", storeIdentifier: store, startedAt: savedAt.addingTimeInterval(-1), endedAt: savedAt)
        XCTAssertNil(service.state(for: "ck:A")?.cloudExportedAt)
        let endedAt = savedAt.addingTimeInterval(5)
        service.recordSuccessfulExport(for: "ck:A", storeIdentifier: store, startedAt: savedAt.addingTimeInterval(1), endedAt: endedAt)
        XCTAssertEqual(service.state(for: "ck:A")?.cloudExportedAt, endedAt)
    }

    func test_exportCannotAcknowledgeAnotherIdentityOrUnknownStart() throws {
        let controller = PersistenceController(inMemory: true)
        let household = try HouseholdProfileRepository(controller: controller).ensureHouseholdProfile(for: "ck:A")
        let store = try XCTUnwrap(household.objectID.persistentStore?.identifier)
        let service = HouseholdDataDeletionService(controller: controller, defaults: defaults())
        service.setCurrentIdentity("ck:A")
        try service.erase(canonicalUserKey: "ck:A")
        let startedAt = Date().addingTimeInterval(1)
        let export = UUID()
        service.observeExport(identifier: export, storeIdentifier: store, startedAt: startedAt, endedAt: nil, succeeded: false)
        service.setCurrentIdentity("ck:B")
        service.observeExport(identifier: export, storeIdentifier: store, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1), succeeded: true)
        service.recordSuccessfulExport(for: "ck:A", storeIdentifier: store, startedAt: startedAt, endedAt: startedAt)
        XCTAssertNil(service.state(for: "ck:A")?.cloudExportedAt)
        service.setCurrentIdentity("ck:A")
        service.observeExport(identifier: UUID(), storeIdentifier: store, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1), succeeded: true)
        XCTAssertNil(service.state(for: "ck:A")?.cloudExportedAt, "A completion with no observed identity-bound start stays pending")
    }

    func test_unreadableMarkerFailsClosed() throws {
        let controller = PersistenceController(inMemory: true)
        let storage = defaults()
        storage.set(Data("bad state".utf8), forKey: "stir.householdDeletion.v1")
        let service = HouseholdDataDeletionService(controller: controller, defaults: storage)
        XCTAssertTrue(service.isAwaitingAcknowledgement(for: "ck:A"))
        XCTAssertThrowsError(try service.resumeDeletion(for: "ck:A"))
    }
}
