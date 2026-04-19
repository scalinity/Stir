// OutcomeFeedbackRepositoryTests
//
// Exercises upsert semantics on the 1:1 CookingSession ↔ OutcomeFeedback
// relationship — spec §4.15 pins uniqueness on cookingSessionId, but
// CloudKit can't enforce it at the schema level so the repo enforces it
// in Swift. These tests assert:
//   - First upsert inserts a fresh row with createdAt set.
//   - Second upsert on the same session UPDATES in place (no new row),
//     preserves createdAt, and reflects the new field values.
//   - Rating clamping (0 → 1, 6 → 5).
//   - leftoverCount clamping (negative → 0).

import CoreData
import XCTest
@testable import Stir

@MainActor
final class OutcomeFeedbackRepositoryTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var sessionRepo: CookingSessionRepository!
    private var outcomeRepo: OutcomeFeedbackRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household)
        sessionRepo = CookingSessionRepository(controller: controller)
        outcomeRepo = OutcomeFeedbackRepository(controller: controller)
    }

    func test_upsert_insertsRowWhenSessionHasNone() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        XCTAssertNil(session.outcomeFeedback)

        let feedback = try outcomeRepo.upsert(for: session, input: .init(
            rating: 4,
            workload: .easy,
            taste: .loved,
            spiceLevel: .mild,
            wouldRepeat: true,
            notes: "Great",
            leftoverCount: 2,
        ))

        XCTAssertEqual(feedback.rating, 4)
        XCTAssertEqual(feedback.typedTaste, .loved)
        XCTAssertEqual(feedback.typedWorkload, .easy)
        XCTAssertEqual(feedback.typedSpiceLevel, .mild)
        XCTAssertEqual(feedback.wouldRepeat, true)
        XCTAssertEqual(feedback.notes, "Great")
        XCTAssertEqual(feedback.leftoverCount, 2)
        XCTAssertNotNil(feedback.createdAt)
        XCTAssertIdentical(session.outcomeFeedback, feedback)
    }

    func test_upsert_updatesInPlacePreservingCreatedAt() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let first = try outcomeRepo.upsert(for: session, input: .init(
            rating: 3,
            workload: .medium,
            taste: .good,
            spiceLevel: .medium,
            wouldRepeat: false,
            notes: nil,
            leftoverCount: 0,
        ))
        let originalCreatedAt = first.createdAt
        let originalID = first.id

        // Sleep briefly so a re-set of createdAt would be detectable.
        try await Task.sleep(for: .milliseconds(20))

        let second = try outcomeRepo.upsert(for: session, input: .init(
            rating: 5,
            workload: .hard,
            taste: .bad,
            spiceLevel: .hot,
            wouldRepeat: true,
            notes: "Updated",
            leftoverCount: 4,
        ))

        // Same row, not a fresh insert.
        XCTAssertEqual(second.id, originalID)
        XCTAssertEqual(second.createdAt, originalCreatedAt, "createdAt must not be overwritten on update")
        XCTAssertEqual(second.rating, 5)
        XCTAssertEqual(second.typedTaste, .bad)
        XCTAssertEqual(second.notes, "Updated")
        XCTAssertEqual(second.leftoverCount, 4)

        // Confirm only one OutcomeFeedback row exists for this session via fetch.
        let request = NSFetchRequest<OutcomeFeedback>(entityName: "OutcomeFeedback")
        request.predicate = NSPredicate(format: "cookingSession == %@", session)
        let count = try controller.viewContext.count(for: request)
        XCTAssertEqual(count, 1, "upsert must update in place — only one row may exist per session")
    }

    func test_upsert_clampsRatingBelowMinAndAboveMax() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)

        let low = try outcomeRepo.upsert(for: session, input: .init(
            rating: 0,
            workload: .easy,
            taste: .good,
            spiceLevel: .mild,
            wouldRepeat: false,
            notes: nil,
            leftoverCount: 0,
        ))
        XCTAssertEqual(low.rating, 1, "rating below 1 must clamp to 1")

        let high = try outcomeRepo.upsert(for: session, input: .init(
            rating: 99,
            workload: .easy,
            taste: .good,
            spiceLevel: .mild,
            wouldRepeat: false,
            notes: nil,
            leftoverCount: 0,
        ))
        XCTAssertEqual(high.rating, 5, "rating above 5 must clamp to 5")
    }

    func test_upsert_clampsNegativeLeftoverCountToZero() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let feedback = try outcomeRepo.upsert(for: session, input: .init(
            rating: 4,
            workload: .easy,
            taste: .good,
            spiceLevel: .mild,
            wouldRepeat: false,
            notes: nil,
            leftoverCount: -3,
        ))
        XCTAssertEqual(feedback.leftoverCount, 0, "leftover count must clamp at 0")
    }

    private func makeRecipePlan(household: HouseholdProfile) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Outcome Test"
        plan.servings = 2
        plan.estimatedMinutes = 25
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try controller.save()
        return plan
    }
}
