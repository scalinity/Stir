// SpeechFallbackServiceTests
//
// Scope: pure-logic unit tests. No SFSpeechRecognizer / AVAudioEngine /
// AVSpeechSynthesizer hardware required — those layers are excluded from
// unit testing because they require real mic/speech permissions that
// only make sense on a physical device. The parts we CAN test at the
// unit level:
//   - Constructor doesn't crash; initial state is .idle
//   - close() from any state ends at .closed
//   - currentState tracks the state machine's transitions
//
// Deeper flows (begin/end turn, speak) need a device-level smoke test
// that runs only with STIR_RUN_AI_INTEGRATION_TESTS=1. Those belong in
// the eval harness or in Phase D.2's in-device validation pass.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SpeechFallbackServiceTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var session: CookingSession!
    private var aiDispatch: AIDispatch!
    private var voiceTurnRepo: VoiceTurnRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household)
        let sessionRepo = CookingSessionRepository(controller: controller)
        session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        voiceTurnRepo = VoiceTurnRepository(controller: controller)

        // Construct an AIDispatch with a mock session client — we
        // don't exercise it in these tests (hardware paths skip), so a
        // simple placeholder is enough. Matches the ScanViewModelTests
        // pattern for in-process AIDispatch construction.
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            build: "1.0.0 (1)",
            osVersion: "17.5",
        )
        let sessionClient = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: .shared,
            sentry: NoOpSentryReporter(),
        )
        aiDispatch = AIDispatch(session: sessionClient, config: config)
    }

    func test_initialState_isIdle() {
        let service = SpeechFallbackService(
            aiDispatch: aiDispatch,
            voiceTurnRepository: voiceTurnRepo,
            cookingSession: session,
        )
        XCTAssertEqual(service.currentState, .idle)
    }

    func test_close_fromIdle_transitionsToClosed() {
        let service = SpeechFallbackService(
            aiDispatch: aiDispatch,
            voiceTurnRepository: voiceTurnRepo,
            cookingSession: session,
        )
        service.close()
        XCTAssertEqual(service.currentState, .closed)
    }

    func test_close_isIdempotent() {
        let service = SpeechFallbackService(
            aiDispatch: aiDispatch,
            voiceTurnRepository: voiceTurnRepo,
            cookingSession: session,
        )
        service.close()
        XCTAssertEqual(service.currentState, .closed)
        service.close()  // second close — should not throw or re-transition.
        XCTAssertEqual(service.currentState, .closed)
    }

    func test_cancelSpeaking_doesNotCrash_whenNotSpeaking() {
        let service = SpeechFallbackService(
            aiDispatch: aiDispatch,
            voiceTurnRepository: voiceTurnRepo,
            cookingSession: session,
        )
        // No active speech — this is a no-op. Used to be the kind of
        // thing that crashed on AVSpeechSynthesizer.stopSpeaking when
        // the synthesizer had never started; guard keeps it safe.
        service.cancelSpeaking()
        XCTAssertNotEqual(service.currentState, .error)
    }

    // MARK: - Helpers

    private func makeRecipePlan(household: HouseholdProfile) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Fallback Service Test"
        plan.servings = 2
        plan.estimatedMinutes = 25
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try controller.save()
        return plan
    }
}
