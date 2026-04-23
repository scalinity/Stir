// CookModeVoiceTraceAggregationTests
//
// Validates CookModeViewModel.fireVoiceSessionCloseTrace aggregation
// (ADR 0009 — single $ai_trace per session, both input and output state
// in one emission). This is the only iOS-side test covering the summation
// math; without it the VM's dashboard-join contract is effectively
// untested.

import CoreData
import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class CookModeVoiceTraceAggregationTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var traceSpy: SpyAITrace!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(
            for: "install:trace-\(UUID().uuidString)",
        )
        recipePlan = try makeRecipePlan(household: household)
        traceSpy = SpyAITrace()
    }

    // MARK: - Tests

    func test_closeTrace_aggregatesThreeLiveTurnSummaries() async throws {
        let session = try freshSession()
        let driver = LiveMockDriver(
            sessionID: "11111111-1111-4111-8111-111111111111",
            promptVersion: "1.0.0",
        )
        let vm = makeVM(session: session, voiceDriver: nil)
        vm.attachVoiceDriver(driver)

        // Totals exceed text+audio by the AUDIO-mode per-pass overhead
        // (CLAUDE.md sharp-edge #15). Turn 1 has 50-token remainder on
        // prompt; turn 2 has 100; turn 3 has 200. Response side: +10/+10/+10.
        // Aggregated `total_prompt_tokens` must equal the raw total sum
        // (5200 + 350 = 5550), not the text+audio sum (5200).
        vm.recordLiveTurnSummary(.init(
            turnIndex: 1,
            promptTokensText: 1000, promptTokensAudio: 150, promptTokensTotal: 1200,
            responseTokensText: 0, responseTokensAudio: 150, responseTokensTotal: 160,
            submittedAt: Date(),
            latencyMs: 1200, latencyTtfaMs: 0,
            containedToolCall: false,
            endedReason: .turnComplete,
            endedAt: Date(),
        ))
        vm.recordLiveTurnSummary(.init(
            turnIndex: 2,
            promptTokensText: 1000, promptTokensAudio: 900, promptTokensTotal: 2000,
            responseTokensText: 0, responseTokensAudio: 150, responseTokensTotal: 160,
            submittedAt: Date(),
            latencyMs: 1400, latencyTtfaMs: 0,
            containedToolCall: false,
            endedReason: .turnComplete,
            endedAt: Date(),
        ))
        vm.recordLiveTurnSummary(.init(
            turnIndex: 3,
            promptTokensText: 1000, promptTokensAudio: 1150, promptTokensTotal: 2350,
            responseTokensText: 10, responseTokensAudio: 140, responseTokensTotal: 160,
            submittedAt: Date(),
            latencyMs: 1600, latencyTtfaMs: 0,
            containedToolCall: false,
            endedReason: .turnComplete,
            endedAt: Date(),
        ))

        await vm.exit(markAbandoned: true)

        XCTAssertEqual(traceSpy.captures.count, 1, "Exactly one $ai_trace per session (ADR 0009)")
        let capture = traceSpy.captures[0]
        XCTAssertEqual(capture.traceID, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(capture.spanName, "voice_session_start")
        XCTAssertEqual(capture.feature, "cook_mode_realtime")

        // Input state captured at attach time.
        let input = capture.inputState
        XCTAssertNotNil(input, "Input state must be attached to the single emission")
        XCTAssertEqual(input?["prompt_version"] as? String, "1.0.0")
        XCTAssertEqual(input?["path"] as? String, "live_api")
        XCTAssertNotNil(input?["recipe_plan_id"])
        XCTAssertNotNil(input?["cooking_session_id"])

        // Output state aggregated over 3 turns.
        let output = capture.outputState
        XCTAssertNotNil(output)
        XCTAssertEqual(output?["total_turns"] as? Int, 3)
        // sum prompt_text: 1000 + 1000 + 1000 = 3000
        XCTAssertEqual(output?["total_prompt_tokens_text"] as? Int, 3000)
        // sum prompt_audio: 150 + 900 + 1150 = 2200
        XCTAssertEqual(output?["total_prompt_tokens_audio"] as? Int, 2200)
        // sum prompt_total: 1200 + 2000 + 2350 = 5550 — raw Gemini totals,
        // matches backend SUM(ai_request_log.input_tokens) for the session.
        XCTAssertEqual(output?["total_prompt_tokens"] as? Int, 5550)
        // sum response_text: 0 + 0 + 10 = 10
        XCTAssertEqual(output?["total_response_tokens_text"] as? Int, 10)
        // sum response_audio: 150 + 150 + 140 = 440
        XCTAssertEqual(output?["total_response_tokens_audio"] as? Int, 440)
        // sum response_total: 160 + 160 + 160 = 480 — raw totals.
        XCTAssertEqual(output?["total_response_tokens"] as? Int, 480)
        XCTAssertEqual(output?["ended_reason"] as? String, "user_exit")
        XCTAssertEqual(output?["path"] as? String, "live_api")
    }

    func test_closeTrace_idempotent_onDoubleExit() async throws {
        let session = try freshSession()
        let driver = LiveMockDriver(
            sessionID: "22222222-2222-4222-8222-222222222222",
            promptVersion: "1.0.0",
        )
        let vm = makeVM(session: session, voiceDriver: nil)
        vm.attachVoiceDriver(driver)
        vm.recordLiveTurnSummary(.init(
            turnIndex: 1,
            promptTokensText: 100, promptTokensAudio: 100, promptTokensTotal: 200,
            responseTokensText: 0, responseTokensAudio: 50, responseTokensTotal: 50,
            submittedAt: Date(),
            latencyMs: 1000, latencyTtfaMs: 0,
            containedToolCall: false,
            endedReason: .turnComplete,
            endedAt: Date(),
        ))

        await vm.exit(markAbandoned: true)
        XCTAssertEqual(traceSpy.captures.count, 1)

        // Second call — should be a no-op.
        await vm.exit(markAbandoned: true)
        XCTAssertEqual(traceSpy.captures.count, 1, "Second exit must not emit another $ai_trace")
    }

    func test_closeTrace_skipped_whenNoLiveSessionIDOnDriver() async throws {
        let session = try freshSession()
        // Fallback driver: voiceSessionID returns nil via protocol default.
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        let vm = makeVM(session: session, voiceDriver: nil)
        vm.attachVoiceDriver(driver)

        await vm.exit(markAbandoned: true)
        XCTAssertEqual(traceSpy.captures.count, 0, "Fallback path has no session trace to emit")
    }

    // MARK: - Helpers

    private func makeVM(
        session: CookingSession,
        voiceDriver: (any VoiceSessionDriver)?,
    ) -> CookModeViewModel {
        CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: .solve,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: CookTimerRepository(controller: controller),
            timerService: TimerService(
                repository: CookTimerRepository(controller: controller),
                sessionRepository: CookingSessionRepository(controller: controller),
                notificationCenter: FakeTraceNotificationCenter(),
            ),
            analytics: traceSpy,
            sentry: StubSentry(),
            entitlements: nil,
            voiceDriver: voiceDriver,
            disableCookRealtime: false,
            presentPaywall: nil,
        )
    }

    private func freshSession() throws -> CookingSession {
        try CookingSessionRepository(controller: controller).createSession(
            on: household, for: recipePlan, entryPoint: .solve,
        )
    }

    private func makeRecipePlan(household: HouseholdProfile) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Voice Trace Test"
        plan.servings = 2
        plan.estimatedMinutes = 15
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        for (idx, text) in ["Step 1", "Step 2"].enumerated() {
            let step = RecipeStep(context: context)
            step.id = UUID()
            step.recipePlan = plan
            step.stepNumber = Int16(idx)
            step.sortOrder = Int16(idx)
            step.instructionText = text
        }
        try controller.save()
        return plan
    }
}

// MARK: - Spy that intercepts captureAITrace

/// PostHogClient subclass recording every captureAITrace call. Pair with
/// SpyTelemetry in CookModeVoiceIntegrationTests.swift (product events)
/// — this one only cares about the LLM Observability $ai_trace path.
final class SpyAITrace: PostHogClient, @unchecked Sendable {
    struct TraceCapture: Sendable {
        let traceID: String
        let spanName: String
        let inputState: [String: Any]?
        let outputState: [String: Any]?
        let feature: String?
    }
    private let lock = NSLock()
    private var _captures: [TraceCapture] = []
    var captures: [TraceCapture] {
        lock.lock(); defer { lock.unlock() }
        return _captures
    }

    init() { super.init(testingOnly: true) }

    override func captureAITrace(
        traceID: String,
        spanName: String,
        inputState: [String: Any]? = nil,
        outputState: [String: Any]? = nil,
        feature: String? = nil,
    ) {
        lock.lock()
        _captures.append(TraceCapture(
            traceID: traceID,
            spanName: spanName,
            inputState: inputState,
            outputState: outputState,
            feature: feature,
        ))
        lock.unlock()
    }

    // Swallow all product-event captures so `cook_mode_started` etc.
    // don't spam test output.
    override func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        // intentionally empty
    }
}

// MARK: - Live-path driver stub that exposes voiceSessionID / promptVersion

@MainActor
private final class LiveMockDriver: VoiceSessionDriver {
    let pathLabel: VoiceSessionPath = .liveAPI
    private(set) var currentState: VoiceSessionState = .ready
    let voiceSessionID: String?
    let voiceSessionPromptVersion: String?

    init(sessionID: String, promptVersion: String) {
        self.voiceSessionID = sessionID
        self.voiceSessionPromptVersion = promptVersion
    }

    func preWarm() async throws {}
    func beginTurn() async throws {}
    func endTurn(
        recipeContext _: RealtimeRecipeContext,
        householdContext _: RealtimeHouseholdContext,
        currentStepNumber _: Int,
        recipePlanId _: UUID,
    ) async throws -> CookTurnResult {
        CookTurnResult(
            transcript: "",
            response: CookTurnResponse(
                spokenResponse: "",
                suggestedAction: .none,
                actionParams: nil,
                promptVersion: voiceSessionPromptVersion ?? "",
                latencyMS: 0,
                retryCount: 0,
            ),
            sttLatencyMs: 0,
            backendLatencyMs: 0,
        )
    }
    func speak(_: String) async {}
    func cancelSpeaking() async {}
    func close() {}
}

// MARK: - Stubs

/// Minimal Sentry stub matching CookModeVoiceIntegrationTests' SpySentry
/// shape but without the capture arrays — this test file doesn't inspect
/// Sentry behavior.
private final class StubSentry: SentryReporting, @unchecked Sendable {
    func captureError(_: any Error, context _: [String: String]) {}
    func breadcrumb(category _: String, message _: String, data _: [String: String]) {}
    func setUserContext(keyHash _: String) {}
}

@MainActor
private final class FakeTraceNotificationCenter: UNUserNotificationCenterClient {
    func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }
    func requestAuthorization(_: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers _: [String]) {}
}
