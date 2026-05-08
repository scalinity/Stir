// RealtimeSessionIdentityTests
//
// Regression guard for the `voiceSessionID` / `voiceSessionPromptVersion`
// property overrides on RealtimeSession. The VoiceSessionDriver protocol
// provides default-nil impls (intentional — fallback drivers don't have
// a session id), which means a future edit that deletes the overrides
// would silently revert the Live path to nil and break the PostHog
// close-summary $ai_trace with no compile error. These tests pin the
// production contract: a RealtimeSession with a minted response must
// expose the mint's session id + prompt version.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class RealtimeSessionIdentityTests: XCTestCase {
    private var controller: PersistenceController!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
    }

    func test_voiceSessionID_returnsMintSessionID() throws {
        let driver = try makeDriver(sessionID: "abc-123", promptVersion: "1.0.0")
        XCTAssertEqual(driver.voiceSessionID, "abc-123")
    }

    func test_voiceSessionPromptVersion_returnsMintPromptVersion() throws {
        let driver = try makeDriver(sessionID: "abc-123", promptVersion: "2.3.4")
        XCTAssertEqual(driver.voiceSessionPromptVersion, "2.3.4")
    }

    // MARK: - Helpers

    private func makeDriver(sessionID: String, promptVersion: String) throws -> RealtimeSession {
        let houseRepo = HouseholdProfileRepository(controller: controller)
        let household = try houseRepo.ensureHouseholdProfile(
            for: "install:rtid-\(UUID().uuidString)",
        )
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Test"
        plan.servings = 2
        plan.estimatedMinutes = 10
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try controller.save()

        let session = try CookingSessionRepository(controller: controller)
            .createSession(on: household, for: plan, entryPoint: .solve)

        let mint = RealtimeSessionResponse(
            authToken: "auth_tokens/test",
            expiresAt: "2027-01-01T00:00:00Z",
            sessionID: sessionID,
            wsURL: "wss://example.invalid",
            promptVersion: promptVersion,
            setupFrameJSON: "{\"setup\":{}}",
        )

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
        let aiDispatch = AIDispatch(session: sessionClient, config: config)

        return RealtimeSession(
            testingOnlyMintResponse: mint,
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(controller: controller),
            cookingSession: session,
        )
    }
}
