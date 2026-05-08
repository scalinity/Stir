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

    // MARK: - SCA-171 / S7 — cross-bucket interaction guards
    //
    // These tests pin the new cross-file dispatch paths introduced by
    // the SCA-79 file split (commits 441563e..646d0a3..105ef55). The
    // existing 38 tests exercise individual hooks; these two add a
    // regression guard for the cross-bucket call resolution itself, so
    // a future refactor that moves or renames a method on either side
    // of a bucket boundary doesn't silently break the integration.

    /// Pins the StateMachine.handleInboundFrame → Transport.handleToolCall
    /// cross-file route. `handleInboundFrame` lives in
    /// `RealtimeSessionStateMachine.swift`; its `.toolCall` switch arm
    /// dispatches to `handleToolCall` in `RealtimeSessionTransport.swift`.
    /// If a future refactor breaks the cross-extension dispatch (e.g.
    /// renaming, moving to a different file with a stricter access
    /// modifier, or accidentally introducing a private overload),
    /// `lastToolCallName` will not get latched and this test fails.
    ///
    /// Distinct from `test_watchdog_latches_tool_call_name_from_preceding_tool_frame`,
    /// which exercises the same path but is conceptually about watchdog
    /// payload accuracy. This test's promise is the cross-bucket
    /// dispatch contract specifically.
    func test_handleInboundFrame_routesToolCall_throughTransportBucket() async throws {
        let driver = makeDriverAt(state: .ready)

        XCTAssertNil(
            driver._testLastToolCallName,
            "precondition: no tool call has fired yet",
        )

        let toolCall = LiveToolCall(functionCalls: [
            LiveFunctionCall(id: "tc-cross-bucket-1", name: "advance_step", args: [:]),
        ])
        await driver._testInjectFrame(.toolCall(toolCall))

        XCTAssertEqual(
            driver._testLastToolCallName,
            "advance_step",
            "handleInboundFrame.toolCall must dispatch to handleToolCall (Transport bucket) and latch lastToolCallName",
        )
        XCTAssertEqual(
            driver.currentState,
            .toolCalling,
            "Transport.handleToolCall must advance the state machine to .toolCalling — confirms the cross-bucket effect, not just the latch",
        )
    }

    /// Pins the StateMachine bucket's transport-error persist surface
    /// (`recordTurnAsTransportError`). Both `AudioIO.handleAudioInterruption`
    /// (cross-bucket: AudioIO → StateMachine) and the receive
    /// dispatcher's catch-block via `handleTransportError`
    /// (in-StateMachine since SCA-161) reach into this method. This test
    /// pins the persist contract directly: a non-nil `turnStartedAt`
    /// causes both VoiceTurn rows (user + model) to land with
    /// `.error` + errorCode "transport_error".
    ///
    /// If `recordTurnAsTransportError` ever gets refactored back into
    /// `private` or moved out of StateMachine, the AudioIO interruption
    /// path silently loses ADR 0015 cap-reversal trigger visibility
    /// (the failing turns stop being counted). This test catches that.
    func test_recordTurnAsTransportError_persistsErrorPairWithCorrectErrorCode() async throws {
        let driver = makeDriverAt(state: .userSpeaking)

        // Simulate an in-flight turn: production sets `turnStartedAt`
        // inside `beginTurn()`, which we don't drive here (it requires
        // a real AudioPipeline). The flag is non-private post-SCA-159
        // so direct mutation is fine under `@testable import`. The
        // audio-chunk frame below populates the per-turn anchors that
        // `finalizeTurn` would normally consume — recordTurnAsTransportError
        // doesn't read them, but the symmetry pins that the helper's
        // guard depends ONLY on `turnStartedAt` (the contract under test).
        driver.turnStartedAt = Date()
        var withAudio = LiveServerContent()
        withAudio.audioChunks = [LiveAudioChunk(base64: "AA==", mimeType: "audio/pcm;rate=24000")]
        await driver._testInjectFrame(.serverContent(withAudio))

        let repo = VoiceTurnRepository(controller: controller)
        let preTurns = repo.turns(for: cookingSession)

        driver.recordTurnAsTransportError()

        let postTurns = repo.turns(for: cookingSession)
        XCTAssertEqual(
            postTurns.count,
            preTurns.count + 2,
            "recordTurnAsTransportError must persist user + model VoiceTurn rows",
        )
        let modelRow = try XCTUnwrap(postTurns.last { $0.typedSpeaker == .model })
        let userRow = try XCTUnwrap(postTurns.last { $0.typedSpeaker == .user })
        XCTAssertEqual(modelRow.typedResultType, .error,
                       "model row must be .error on transport_error path")
        XCTAssertEqual(modelRow.errorCode, "transport_error",
                       "errorCode must match ADR 0015 trigger signal string")
        XCTAssertEqual(userRow.typedResultType, .error,
                       "user row must ALSO be .error (unlike watchdog where user row stays .normal — both directions are compromised on transport-error)")
        XCTAssertEqual(userRow.errorCode, "transport_error")
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
