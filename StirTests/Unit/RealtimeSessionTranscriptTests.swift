// RealtimeSessionTranscriptTests
//
// CR3-C2 fix: pin the per-turn transcript accumulator behavior in
// RealtimeSession's `serverContent` frame handler. The inline ASSUMPTION
// comment at ~line 2920 says input.text is a delta; if Gemini Live
// preview ever ships cumulative transcriptions (CA1-M5 risk), every
// voice-mode user gets duplicated YOU SAID cards with no telemetry
// signal — the field is best-effort observability and isn't gated by
// hard-rule validation.
//
// These tests inject 3 synthetic `inputTranscription` and
// `outputTranscription` deltas via `_testInjectFrame` then trigger
// `turnComplete` to surface the `onTurnTranscriptFinalized` callback.
// Asserting the resulting `LiveTurnTranscript.userText` /
// `.modelText` equals the simple concatenation of the deltas pins
// the delta-not-cumulative contract: a future protocol shift will
// make this test fail loudly instead of leaking a stuttering UI.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class RealtimeSessionTranscriptTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var cookingSession: CookingSession!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        household = try HouseholdProfileRepository(controller: controller)
            .ensureHouseholdProfile(for: "install:transcript-\(UUID().uuidString)")
        let ctx = controller.viewContext
        recipePlan = RecipePlan(context: ctx)
        recipePlan.id = UUID()
        recipePlan.household = household
        recipePlan.title = "Test"
        recipePlan.servings = 2
        recipePlan.estimatedMinutes = 10
        recipePlan.typedOrigin = .ai
        recipePlan.createdAt = Date()
        recipePlan.updatedAt = Date()
        try controller.save()
        cookingSession = try CookingSessionRepository(controller: controller)
            .createSession(on: household, for: recipePlan, entryPoint: .solve)
    }

    override func tearDown() async throws {
        controller = nil
        household = nil
        recipePlan = nil
        cookingSession = nil
        try await super.tearDown()
    }

    // MARK: - User-side delta accumulation

    func test_inputTranscription_deltasAreConcatenated() async throws {
        let driver = makeDriver()
        let captured = TranscriptCapture()
        driver.onTurnTranscriptFinalized = { snapshot in
            captured.append(snapshot)
        }
        // Move the state machine into modelSpeaking so finalizeTurn
        // (driven by turnComplete) actually runs. idle → ready is the
        // canonical pre-handshake hop; ready → modelSpeaking covers the
        // VAD-driven next-turn path documented in VoiceSessionState.
        _ = driver._testAdvance(to: .ready)
        _ = driver._testAdvance(to: .modelSpeaking)

        await driver._testInjectFrame(.serverContent(content(inputText: "How long")))
        await driver._testInjectFrame(.serverContent(content(inputText: " do you sear")))
        await driver._testInjectFrame(.serverContent(content(inputText: " the steak?")))
        await driver._testInjectFrame(.serverContent(turnComplete()))
        // `onTurnTranscriptFinalized` fires from `flushPendingReport`,
        // which is triggered by `usageMetadata` arriving (or by the 2s
        // timeout). Inject a leading usageMetadata to skip the wait.
        await driver._testInjectFrame(.usageMetadata(usage()))

        XCTAssertEqual(captured.snapshots.count, 1)
        XCTAssertEqual(captured.snapshots.first?.userText, "How long do you sear the steak?")
    }

    // MARK: - Model-side delta accumulation (parallel assertion)

    func test_outputTranscription_deltasAreConcatenated() async throws {
        let driver = makeDriver()
        let captured = TranscriptCapture()
        driver.onTurnTranscriptFinalized = { snapshot in
            captured.append(snapshot)
        }
        _ = driver._testAdvance(to: .ready)
        _ = driver._testAdvance(to: .modelSpeaking)

        await driver._testInjectFrame(.serverContent(content(outputText: "Two minutes")))
        await driver._testInjectFrame(.serverContent(content(outputText: " per side")))
        await driver._testInjectFrame(.serverContent(content(outputText: " for medium-rare.")))
        await driver._testInjectFrame(.serverContent(turnComplete()))
        await driver._testInjectFrame(.usageMetadata(usage()))

        XCTAssertEqual(captured.snapshots.count, 1)
        XCTAssertEqual(captured.snapshots.first?.modelText, "Two minutes per side for medium-rare.")
    }

    // MARK: - Combined: trim semantics + both halves present

    func test_bothSides_concatenateAndTrim() async throws {
        let driver = makeDriver()
        let captured = TranscriptCapture()
        driver.onTurnTranscriptFinalized = { snapshot in
            captured.append(snapshot)
        }
        _ = driver._testAdvance(to: .ready)
        _ = driver._testAdvance(to: .modelSpeaking)

        await driver._testInjectFrame(.serverContent(content(inputText: "  How long ")))
        await driver._testInjectFrame(.serverContent(content(outputText: "Two minutes  ")))
        await driver._testInjectFrame(.serverContent(turnComplete()))
        await driver._testInjectFrame(.usageMetadata(usage()))

        XCTAssertEqual(captured.snapshots.count, 1)
        // The accumulator stores raw deltas; finalize trims only at
        // the snapshot boundary. The contract: callers see something
        // sane on a turn that had whitespace on either side of the
        // user-text or model-text.
        XCTAssertEqual(captured.snapshots.first?.userText, "How long")
        XCTAssertEqual(captured.snapshots.first?.modelText, "Two minutes")
    }

    // MARK: - Helpers

    /// Builds a serverContent frame. Either side can be nil. Each call
    /// produces ONE delta — three calls = three deltas.
    private func content(
        inputText: String? = nil,
        outputText: String? = nil,
    ) -> LiveServerContent {
        var c = LiveServerContent()
        if let inputText {
            c.inputTranscription = LiveTranscription(text: inputText, finished: false)
        }
        if let outputText {
            c.outputTranscription = LiveTranscription(text: outputText, finished: false)
        }
        return c
    }

    private func turnComplete() -> LiveServerContent {
        var c = LiveServerContent()
        c.turnComplete = true
        return c
    }

    private func usage(prompt: Int = 100, response: Int = 50) -> LiveUsageMetadata {
        LiveUsageMetadata(
            promptTokenCount: prompt,
            responseTokenCount: response,
            totalTokenCount: prompt + response,
            promptAudioTokens: prompt / 2,
            promptTextTokens: prompt - prompt / 2,
            responseAudioTokens: response,
            responseTextTokens: 0,
            cachedContentTokenCount: nil,
        )
    }

    private func makeDriver() -> RealtimeSession {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil, sentry: nil, revenueCat: nil,
            build: "1.0.0 (1)", osVersion: "17.5",
        )
        let sessionClient = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: .shared,
            sentry: NoOpSentryReporter(),
        )
        let aiDispatch = AIDispatch(session: sessionClient, config: config)
        let mint = RealtimeSessionResponse(
            authToken: "auth_tokens/test",
            expiresAt: "2027-01-01T00:00:00Z",
            sessionID: UUID().uuidString,
            wsURL: "wss://test.invalid",
            promptVersion: "1.0.0",
            setupFrameJSON: "{\"setup\":{}}",
        )
        return RealtimeSession(
            testingOnlyMintResponse: mint,
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(controller: controller),
            cookingSession: cookingSession,
        )
    }
}

@MainActor
private final class TranscriptCapture {
    private(set) var snapshots: [LiveTurnTranscript] = []
    func append(_ s: LiveTurnTranscript) { snapshots.append(s) }
}
