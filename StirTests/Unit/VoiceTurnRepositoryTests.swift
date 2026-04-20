// VoiceTurnRepositoryTests
//
// Exercises VoiceTurn persistence per spec §4.12. Covers:
//   - Persist a single turn + read back all fields
//   - turnIndex auto-advance via nextTurnIndex()
//   - Typed enum round-trip (speaker, inputMode, resultType)
//   - Fetch filter by cookingSessionId + turnIndex ordering
//   - Cascade delete: deleting CookingSession hard-deletes its VoiceTurns

import CoreData
import XCTest
@testable import Stir

@MainActor
final class VoiceTurnRepositoryTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var sessionRepo: CookingSessionRepository!
    private var voiceTurnRepo: VoiceTurnRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household)
        sessionRepo = CookingSessionRepository(controller: controller)
        voiceTurnRepo = VoiceTurnRepository(controller: controller)
    }

    func test_persist_writesAllFields() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let turn = try voiceTurnRepo.persist(.init(
            session: session,
            speaker: .user,
            turnIndex: 1,
            transcriptText: "how hot should the oil be",
            inputMode: .voice,
            latencyMs: 0,
            resultType: .normal,
        ))

        XCTAssertNotNil(turn.id)
        XCTAssertEqual(turn.cookingSessionId, session.id)
        XCTAssertEqual(turn.turnIndex, 1)
        XCTAssertEqual(turn.typedSpeaker, .user)
        XCTAssertEqual(turn.transcriptText, "how hot should the oil be")
        XCTAssertEqual(turn.typedInputMode, .voice)
        XCTAssertEqual(turn.latencyMs, 0)
        XCTAssertEqual(turn.typedResultType, .normal)
        XCTAssertNotNil(turn.createdAt)
    }

    func test_nextTurnIndex_startsAt1AndAdvances() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)

        XCTAssertEqual(voiceTurnRepo.nextTurnIndex(for: session), 1, "first turn starts at 1")

        _ = try voiceTurnRepo.persist(.init(
            session: session, speaker: .user, turnIndex: 1,
            transcriptText: "hi", inputMode: .voice, latencyMs: 0, resultType: .normal,
        ))
        XCTAssertEqual(voiceTurnRepo.nextTurnIndex(for: session), 2)

        _ = try voiceTurnRepo.persist(.init(
            session: session, speaker: .model, turnIndex: 2,
            transcriptText: "hello", inputMode: .voice, latencyMs: 450, resultType: .normal,
        ))
        XCTAssertEqual(voiceTurnRepo.nextTurnIndex(for: session), 3)
    }

    func test_turns_returnsInTurnIndexOrder() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        // Persist out of order.
        _ = try voiceTurnRepo.persist(.init(
            session: session, speaker: .model, turnIndex: 2,
            transcriptText: "second", inputMode: .voice, latencyMs: 200, resultType: .normal,
        ))
        _ = try voiceTurnRepo.persist(.init(
            session: session, speaker: .user, turnIndex: 1,
            transcriptText: "first", inputMode: .voice, latencyMs: 0, resultType: .normal,
        ))
        _ = try voiceTurnRepo.persist(.init(
            session: session, speaker: .model, turnIndex: 3,
            transcriptText: "third", inputMode: .voice, latencyMs: 600, resultType: .toolCall,
        ))

        let got = voiceTurnRepo.turns(for: session)
        XCTAssertEqual(got.map(\.turnIndex), [1, 2, 3])
        XCTAssertEqual(got.map(\.transcriptText), ["first", "second", "third"])
    }

    func test_turns_scopedToCookingSession() throws {
        let sessionA = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let sessionB = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)

        _ = try voiceTurnRepo.persist(.init(
            session: sessionA, speaker: .user, turnIndex: 1,
            transcriptText: "A-1", inputMode: .voice, latencyMs: 0, resultType: .normal,
        ))
        _ = try voiceTurnRepo.persist(.init(
            session: sessionB, speaker: .user, turnIndex: 1,
            transcriptText: "B-1", inputMode: .voice, latencyMs: 0, resultType: .normal,
        ))

        let aTurns = voiceTurnRepo.turns(for: sessionA)
        let bTurns = voiceTurnRepo.turns(for: sessionB)
        XCTAssertEqual(aTurns.count, 1)
        XCTAssertEqual(bTurns.count, 1)
        XCTAssertEqual(aTurns.first?.transcriptText, "A-1")
        XCTAssertEqual(bTurns.first?.transcriptText, "B-1")
    }

    func test_cascadeDelete_removesTurnsWithSession() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let sessionId = session.id!

        _ = try voiceTurnRepo.persist(.init(
            session: session, speaker: .user, turnIndex: 1,
            transcriptText: "cascade-1", inputMode: .voice, latencyMs: 0, resultType: .normal,
        ))
        _ = try voiceTurnRepo.persist(.init(
            session: session, speaker: .model, turnIndex: 2,
            transcriptText: "cascade-2", inputMode: .voice, latencyMs: 500, resultType: .normal,
        ))

        // Hard delete the session (the spec sets hard-delete with session —
        // the Core Data cascade relationship encodes this).
        let context = controller.viewContext
        context.delete(session)
        try context.save()

        // Confirm no VoiceTurn rows remain for this session.
        let fetch = NSFetchRequest<VoiceTurn>(entityName: "VoiceTurn")
        fetch.predicate = NSPredicate(format: "cookingSessionId == %@", sessionId as CVarArg)
        let remaining = try context.count(for: fetch)
        XCTAssertEqual(remaining, 0, "VoiceTurns must cascade-delete with CookingSession")
    }

    func test_typedResultType_toolCallRoundTrip() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let turn = try voiceTurnRepo.persist(.init(
            session: session, speaker: .model, turnIndex: 1,
            transcriptText: "Let me check",
            inputMode: .voice,
            latencyMs: 320,
            resultType: .toolCall,
        ))
        // Spec enum value is snake_case `tool_call`; typed wrapper normalizes.
        XCTAssertEqual(turn.resultType, "tool_call")
        XCTAssertEqual(turn.typedResultType, .toolCall)
    }

    func test_typedSpeaker_defaultsToModelOnEmptyString() throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let turn = try voiceTurnRepo.persist(.init(
            session: session, speaker: .model, turnIndex: 1,
            transcriptText: "", inputMode: .voice, latencyMs: 0, resultType: .normal,
        ))
        turn.speaker = ""  // corrupted value
        XCTAssertEqual(turn.typedSpeaker, .model, "fallback avoids crashing on unexpected values")
    }

    private func makeRecipePlan(household: HouseholdProfile) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Voice Turn Test"
        plan.servings = 2
        plan.estimatedMinutes = 25
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try controller.save()
        return plan
    }
}
