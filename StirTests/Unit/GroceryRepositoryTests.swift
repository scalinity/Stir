// GroceryRepositoryTests
//
// Spec §4.16 / §4.17 invariants enforced by the repo:
//   - GroceryList.status enum is exactly {draft, exported}.
//   - Transition draft → exported only on markExported with EventKit
//     correlation IDs.
//   - GroceryItem.priority is REQUIRED on every insert; default "normal"
//     when the incoming response lacks a value.
//   - Dedupe merges by canonical_slug or normalized displayName,
//     preserving the higher priority and combining amount_text.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class GroceryRepositoryTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var repo: GroceryRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        repo = GroceryRepository(controller: controller)
    }

    // MARK: - createDraft

    func test_createDraft_startsInDraftStatus() throws {
        let list = try repo.createDraft(for: household, title: "Chicken Tacos")
        XCTAssertEqual(list.statusEnum, .draft)
        XCTAssertNil(list.exportedAt)
        XCTAssertNil(list.reminderListId)
        XCTAssertEqual(list.title, "Chicken Tacos")
        XCTAssertNotNil(list.createdAt)
    }

    func test_createDraft_capturesSourceCookingSessionID() throws {
        let sessionID = UUID()
        let list = try repo.createDraft(
            for: household,
            title: "Session-originated",
            sourceCookingSessionID: sessionID,
        )
        XCTAssertEqual(list.sourceCookingSessionId, sessionID)
    }

    // MARK: - replaceItems

    func test_replaceItems_populatesPriorityOnEveryRow() throws {
        let list = try repo.createDraft(for: household, title: "Test")
        try repo.replaceItems(on: list, items: [
            .init(displayName: "chicken thighs", quantityText: "1.5 lbs", canonicalSlug: "chicken_thigh", category: .meat, priority: .high),
            .init(displayName: "olive oil", quantityText: "2 tbsp", canonicalSlug: "olive_oil", category: .pantry, priority: .normal),
            .init(displayName: "parsley", quantityText: nil, canonicalSlug: nil, category: .produce, priority: .low),
        ])

        let items = list.orderedItems
        XCTAssertEqual(items.count, 3)
        for item in items {
            XCTAssertNotNil(item.priority, "priority REQUIRED on every row — spec §4.17")
            XCTAssertNotEqual(item.priority ?? "", "", "priority must not be empty")
            XCTAssertTrue(
                ["normal", "low", "high"].contains(item.priority ?? ""),
                "priority must be a spec-allowed enum value",
            )
        }
    }

    func test_replaceItems_replacesExistingWithoutLeakingRows() throws {
        let list = try repo.createDraft(for: household, title: "Test")
        try repo.replaceItems(on: list, items: [
            .init(displayName: "first-pass", quantityText: nil, canonicalSlug: nil, category: .other, priority: .normal),
        ])
        XCTAssertEqual(list.orderedItems.count, 1)

        try repo.replaceItems(on: list, items: [
            .init(displayName: "second-pass-a", quantityText: nil, canonicalSlug: nil, category: .other, priority: .normal),
            .init(displayName: "second-pass-b", quantityText: nil, canonicalSlug: nil, category: .other, priority: .normal),
        ])

        let items = list.orderedItems
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.contains(where: { $0.displayName == "second-pass-a" }))
        XCTAssertTrue(items.contains(where: { $0.displayName == "second-pass-b" }))
        XCTAssertFalse(items.contains(where: { $0.displayName == "first-pass" }))
    }

    // MARK: - dedupe

    func test_dedupedForPersistence_mergesBySlugAndKeepsHigherPriority() {
        let merged = repo.dedupedForPersistence([
            .init(displayName: "Olive Oil", quantityText: "1 cup", canonicalSlug: "olive_oil", category: .pantry, priority: .normal),
            .init(displayName: "olive oil", quantityText: "2 tbsp", canonicalSlug: "olive_oil", category: .pantry, priority: .high),
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.priority, .high, "higher priority wins on merge")
        XCTAssertEqual(merged.first?.canonicalSlug, "olive_oil")
        XCTAssertNotNil(merged.first?.quantityText)
        XCTAssertTrue(
            merged.first?.quantityText?.contains("1 cup") == true &&
                merged.first?.quantityText?.contains("2 tbsp") == true,
            "combined amount_text should surface both quantities",
        )
    }

    func test_normalizedDisplayName_handlesSingularPlural() {
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("Tomatoes"), "tomato")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("eggs"), "egg")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("berries"), "berry")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("Salt"), "salt")
    }

    /// Regression for the "roses → ros" bug. Singulars ending in -e
    /// that take a plural-s (rose, name, range) must round-trip through
    /// the same normalized key as their plural. Pre-fix the -es branch
    /// aggressively dropped 'es', producing "ros"/"nam"/"rang" for the
    /// plurals and breaking dedupe.
    func test_normalizedDisplayName_singularsEndingInEArePreserved() {
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("roses"), "rose")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("rose"), "rose")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("names"), "name")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("name"), "name")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("ranges"), "range")
        // Sibilant -es plurals still drop 'es' properly.
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("classes"), "class")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("boxes"), "box")
        XCTAssertEqual(GroceryRepository.normalizedDisplayName("dishes"), "dish")
    }

    /// Regression: slug-keyed item and no-slug item with same display
    /// name must merge. Pre-fix they went into separate buckets because
    /// dedupe keyed on slug OR name (not slug AND name index).
    func test_dedupedForPersistence_mergesSlugWithNoSlugSameDisplayName() {
        let merged = repo.dedupedForPersistence([
            .init(displayName: "Chicken breast", quantityText: "1 lb", canonicalSlug: "chicken_breast", category: .meat, priority: .high),
            .init(displayName: "Chicken breast", quantityText: "2 pieces", canonicalSlug: nil, category: .meat, priority: .normal),
        ])
        XCTAssertEqual(merged.count, 1, "items with same display name merge whether slug is present or not")
        XCTAssertEqual(merged.first?.canonicalSlug, "chicken_breast", "known slug wins over nil")
        XCTAssertEqual(merged.first?.priority, .high)
    }

    // MARK: - markExported

    func test_markExported_flipsStatusAndRecordsEventKitIDs() throws {
        let list = try repo.createDraft(for: household, title: "Test")
        try repo.replaceItems(on: list, items: [
            .init(displayName: "parsley", quantityText: "1 bunch", canonicalSlug: nil, category: .produce, priority: .normal),
        ])
        let firstItemID = list.orderedItems.first?.id
        XCTAssertNotNil(firstItemID)

        try repo.markExported(
            list,
            reminderListID: "reminder-list-uuid",
            itemReminderIDs: [firstItemID!: "item-reminder-uuid"],
        )

        XCTAssertEqual(list.statusEnum, .exported)
        XCTAssertEqual(list.reminderListId, "reminder-list-uuid")
        XCTAssertNotNil(list.exportedAt)
        XCTAssertEqual(list.orderedItems.first?.reminderId, "item-reminder-uuid")
    }

    func test_markExported_isNoOpOnAlreadyExportedList() throws {
        let list = try repo.createDraft(for: household, title: "Test")
        try repo.replaceItems(on: list, items: [
            .init(displayName: "parsley", quantityText: nil, canonicalSlug: nil, category: .produce, priority: .normal),
        ])
        try repo.markExported(list, reminderListID: "first-list", itemReminderIDs: [:])
        let firstExportedAt = list.exportedAt

        // Second call — should no-op (not overwrite fields).
        try repo.markExported(list, reminderListID: "second-list", itemReminderIDs: [:])

        XCTAssertEqual(list.statusEnum, .exported)
        XCTAssertEqual(list.reminderListId, "first-list", "should not overwrite on re-export")
        XCTAssertEqual(list.exportedAt, firstExportedAt, "exportedAt frozen after first export")
    }

    // MARK: - toggle

    func test_toggleChecked_flipsPersistedFlag() throws {
        let list = try repo.createDraft(for: household, title: "Test")
        try repo.replaceItems(on: list, items: [
            .init(displayName: "milk", quantityText: "1 gal", canonicalSlug: "milk", category: .dairy, priority: .normal),
        ])
        let item = list.orderedItems.first!
        XCTAssertFalse(item.isChecked)

        try repo.toggleChecked(item)
        XCTAssertTrue(item.isChecked)

        try repo.toggleChecked(item)
        XCTAssertFalse(item.isChecked)
    }
}
