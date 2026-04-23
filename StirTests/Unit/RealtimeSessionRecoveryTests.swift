// RealtimeSessionRecoveryTests
//
// Pins the two critical-path recovery behaviors added in the 2026-04-23
// review remediation:
//
//   P0-L: `turnStuckWatchdogFired` — Gemini Live drops `turnComplete`
//         on multi-pass tool-call turns (CLAUDE.md §sharp-edge #20).
//         The watchdog synthesizes a turnComplete after 15 s of silence
//         on `.modelSpeaking`; the VoiceTurn row MUST persist with
//         `resultType=.error, errorCode="turnComplete_timeout"` so
//         ADR 0015's cap-reversal trigger query can count these.
//
//   P1-S: `handleTransportError` must NOT demote a successfully-
//         recovered session to `.error`. Prior code unconditionally
//         advanced to `.error` after `refreshSession`; the P0-A fix
//         routes on the returned `RefreshOutcome` so `.success` stays
//         `.ready` (or pre-refresh state) and only `.preCommitFailure`
//         / `.postCommitFailure` escalate.
//
// Uses the same test hooks as RealtimeSessionReportingTests:
// `_testInjectFrame`, `_testAdvance`, `_testFireTurnStuckWatchdog`
// (new in P0-L). Zero real-time waits — the watchdog Task timeout is
// bypassed via the synchronous test hook.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class RealtimeSessionRecoveryTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var cookingSession: CookingSession!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        household = try HouseholdProfileRepository(controller: controller)
            .ensureHouseholdProfile(for: "install:recovery-\(UUID().uuidString)")
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

    // MARK: - P0-L: stuck-turnComplete watchdog

    func test_watchdog_fires_callback_with_correct_payload_shape() async throws {
        let driver = makeDriverAt(state: .modelSpeaking)

        var capturedCallback: (sessionID: String, turnIndex: Int, toolCallType: String?, elapsedMs: Int, turnLengthMs: Int)?
        driver.onVoiceTurnStuckWatchdogFired = { session, turn, tool, elapsed, length in
            capturedCallback = (session, turn, tool, elapsed, length)
        }

        // Synchronous fire of the watchdog path — watchdog guards on
        // `stateMachine.state == .modelSpeaking`, which `makeDriverAt`
        // already ensures.
        driver._testFireTurnStuckWatchdog()

        let cb = try XCTUnwrap(capturedCallback, "watchdog callback must fire")
        XCTAssertFalse(cb.sessionID.isEmpty, "session id must be populated from mintResponse")
        XCTAssertEqual(cb.turnIndex, 1, "first watchdog fire reports turnIndex=1")
        XCTAssertNil(cb.toolCallType, "no tool call preceded this turn → nil")
        XCTAssertGreaterThanOrEqual(cb.elapsedMs, 0)
        XCTAssertGreaterThanOrEqual(cb.turnLengthMs, 0)
    }

    func test_watchdog_persists_voice_turn_with_timeout_error_code() async throws {
        let driver = makeDriverAt(state: .modelSpeaking)

        // Pre-watchdog VoiceTurn count baseline
        let repo = VoiceTurnRepository(controller: controller)
        let preTurns = repo.turns(for: cookingSession)

        driver._testFireTurnStuckWatchdog()

        let postTurns = repo.turns(for: cookingSession)
        XCTAssertEqual(
            postTurns.count,
            preTurns.count + 2,
            "watchdog fire must persist user + model VoiceTurn rows",
        )

        // Model row is the second of the pair per finalizeTurn's ordering.
        let modelRow = try XCTUnwrap(postTurns.last { $0.typedSpeaker == .model })
        XCTAssertEqual(
            modelRow.typedResultType,
            .error,
            "model row on watchdog fire must be .error (spec §4.12 audit)",
        )
        XCTAssertEqual(
            modelRow.errorCode,
            "turnComplete_timeout",
            "errorCode must be the ADR 0015 trigger signal string",
        )

        // User row should be .normal — the user DID speak, only the model
        // response was truncated.
        let userRow = try XCTUnwrap(postTurns.last { $0.typedSpeaker == .user })
        XCTAssertEqual(userRow.typedResultType, .normal)
        XCTAssertNil(userRow.errorCode)
    }

    func test_watchdog_latches_tool_call_name_from_preceding_tool_frame() async throws {
        let driver = makeDriverAt(state: .ready)
        var captured: String??
        driver.onVoiceTurnStuckWatchdogFired = { _, _, tool, _, _ in
            captured = tool
        }

        // Inject a toolCall frame so `lastToolCallName` latches.
        let toolCall = LiveToolCall(functionCalls: [
            LiveFunctionCall(id: "tc-1", name: "start_timer", args: ["seconds": 120]),
        ])
        await driver._testInjectFrame(.toolCall(toolCall))

        // Transition to .modelSpeaking (toolCalling → modelSpeaking is
        // the production path when Gemini resumes audio after toolResponse).
        driver._testAdvance(to: .modelSpeaking)

        driver._testFireTurnStuckWatchdog()

        XCTAssertEqual(captured, "start_timer", "watchdog must latch most-recent toolCall name")
        XCTAssertNil(
            driver._testLastToolCallName,
            "lastToolCallName must reset in finalizeTurn's defer block",
        )
    }

    func test_watchdog_advances_state_to_ready() async throws {
        let driver = makeDriverAt(state: .modelSpeaking)
        XCTAssertEqual(driver.currentState, .modelSpeaking)

        driver._testFireTurnStuckWatchdog()

        XCTAssertEqual(
            driver.currentState,
            .ready,
            "watchdog synthesizes turnComplete → state advances to .ready",
        )
    }

    // MARK: - P1-S: refresh outcome gating (narrow coverage)

    /// Narrow regression guard for the P0-A fix: `refreshSession()`
    /// short-circuits to `.skipped` when called on a terminal state
    /// (`.closed` or `.error`). This is the cheap-to-test half of the
    /// outcome contract; the success path requires a full mock WS
    /// harness (deferred to a follow-up PR). The skipped path is what
    /// `handleTransportError` sees after it has already advanced to
    /// `.error` — we pin that it doesn't re-advance and doesn't loop.
    func test_refreshSession_returnsSkipped_whenStateIsError() async throws {
        let driver = makeDriver()
        driver._testAdvance(to: .ready)
        driver._testAdvance(to: .error)

        let outcome = await driver.refreshSession(reason: "transport_error")
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(
            driver.currentState,
            .error,
            "refreshSession on .error must not mutate state",
        )
    }

    /// Same pinning for `.closed`. Calling refresh on a closed session
    /// should be a no-op that returns `.skipped`.
    func test_refreshSession_returnsSkipped_whenStateIsClosed() async throws {
        let driver = makeDriver()
        driver.close()

        let outcome = await driver.refreshSession(reason: "transport_error")
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(driver.currentState, .closed)
    }

    // MARK: - Helpers

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

    /// `makeDriver` + state-machine walk to the target state. The
    /// `testingOnlyMintResponse` init leaves the machine in `.idle`
    /// (no preWarm runs). Production path is `.idle → .connecting →
    /// .ready → .userSpeaking → …`; for tests we advance via the
    /// test-only `_testAdvance` in one step.
    private func makeDriverAt(state: VoiceSessionState) -> RealtimeSession {
        let driver = makeDriver()
        // Walk the grammar: .idle → .ready (legal) → .modelSpeaking (legal)
        driver._testAdvance(to: .ready)
        if state != .ready {
            driver._testAdvance(to: state)
        }
        return driver
    }
}
