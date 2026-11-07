// RealtimeSessionReportingTests
//
// Locks down the per-turn pending-report flush logic across the three
// usage/turnComplete orderings the driver must tolerate:
//   (A) trailing — turnComplete arrives FIRST, usage follows later.
//       Not what OpenAI sends (usage rides in the same response.done and
//       is emitted first) but the previous provider did this routinely
//       (observed 2026-04-22), and the deferred-POST path stays as the
//       backstop.
//   (B) timeout — turnComplete arrives but NO usage follows. Report
//       fires with zero tokens after pendingReportTimeoutSec; ops log
//       captures the regression.
//   (C) leading — usage arrives first (the OpenAI shape: parseAll emits
//       usage before turnComplete). Short-circuit path skips the 2s
//       wait entirely.
//
// Each scenario injects synthetic frames via `_testInjectFrame` and
// asserts the `onTurnFinalized` callback carries the expected token
// breakdown. The callback uses the same payload that the POST does,
// so token correctness here = POST correctness.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class RealtimeSessionReportingTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var cookingSession: CookingSession!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        household = try HouseholdProfileRepository(controller: controller)
            .ensureHouseholdProfile(for: "install:reporting-\(UUID().uuidString)")
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

    // MARK: - Scenario A: trailing usageMetadata (the prod regression)

    func test_scenarioA_trailing_usageMetadata_populates_token_counts() async throws {
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Frame 1: serverContent with turnComplete=true. Triggers
        // finalizeTurn → pendingReport set → 2s timer scheduled.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        XCTAssertTrue(captured.isEmpty, "report must NOT fire before usage arrives")

        // Frame 2 (trailing): usageMetadata in a later envelope.
        // Early-fires flushPendingReport via the case .usageMetadata
        // hook in handleInboundFrame.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 2150,
            responseTokenCount: 150,
            totalTokenCount: 2300,
            promptAudioTokens: 1150,
            promptTextTokens: 1000,
            responseAudioTokens: 150,
            responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))

        XCTAssertEqual(captured.count, 1, "report must fire exactly once after usage arrives")
        let summary = try XCTUnwrap(captured.first)
        XCTAssertEqual(summary.promptTokensText, 1000)
        XCTAssertEqual(summary.promptTokensAudio, 1150)
        // Raw provider total forwarded to backend. In this fixture
        // total == text+audio, but the field must be populated on every
        // report.
        XCTAssertEqual(summary.promptTokensTotal, 2150)
        XCTAssertEqual(summary.responseTokensText, 0)
        XCTAssertEqual(summary.responseTokensAudio, 150)
        XCTAssertEqual(summary.responseTokensTotal, 150)
    }

    // MARK: - Scenario B: usage never arrives — timeout fires

    func test_scenarioB_no_usageMetadata_fires_report_with_zeros_after_timeout() async throws {
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        XCTAssertTrue(captured.isEmpty)

        // Wait past the budget. pendingReportTimeoutSec is 2s; give it
        // 0.5s headroom for the Task.sleep + flush hop.
        try await Task.sleep(for: .seconds(LiveSessionBudget.pendingReportTimeoutSec + 0.5))

        XCTAssertEqual(captured.count, 1, "timeout must still fire the report")
        let summary = try XCTUnwrap(captured.first)
        XCTAssertEqual(summary.promptTokensText, 0, "no usage → zero tokens")
        XCTAssertEqual(summary.promptTokensAudio, 0)
        XCTAssertEqual(summary.promptTokensTotal, 0)
        XCTAssertEqual(summary.responseTokensText, 0)
        XCTAssertEqual(summary.responseTokensAudio, 0)
        XCTAssertEqual(summary.responseTokensTotal, 0)
    }

    // MARK: - Scenario C: leading usageMetadata (short-circuit)

    func test_scenarioC_leading_usageMetadata_short_circuits_no_timer_wait() async throws {
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Frame 1: usageMetadata arrives first (the response.done shape:
        // parseAll puts usage before turnComplete). Accumulator set but
        // NO pendingReport yet, so the .usageArrived early-fire guard is
        // a no-op.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 1500,
            responseTokenCount: 200,
            totalTokenCount: 1700,
            promptAudioTokens: 1000,
            promptTextTokens: 500,
            responseAudioTokens: 200,
            responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))
        XCTAssertTrue(captured.isEmpty, "usage before turnComplete cannot fire — nothing pending yet")

        // Frame 2: serverContent{turnComplete}. finalizeTurn sees
        // lastUsageMetadata already populated, short-circuits via
        // `if lastUsageMetadata != nil { flushPendingReport(...) }`.
        // Report fires SYNCHRONOUSLY — no 2s wait.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))

        XCTAssertEqual(captured.count, 1, "short-circuit must fire on turnComplete")
        let summary = try XCTUnwrap(captured.first)
        XCTAssertEqual(summary.promptTokensText, 500)
        XCTAssertEqual(summary.promptTokensAudio, 1000)
        XCTAssertEqual(summary.promptTokensTotal, 1500)
        XCTAssertEqual(summary.responseTokensText, 0)
        XCTAssertEqual(summary.responseTokensAudio, 200)
        XCTAssertEqual(summary.responseTokensTotal, 200)
    }

    // MARK: - Unattributed tokens: total exceeds text+audio breakdown

    func test_totals_exceed_breakdown_when_audio_overhead_present() async throws {
        // input_tokens can include tokens that input_token_details
        // doesn't attribute to text or audio (image tokens, in
        // principle). Both the raw total AND the breakdown must be
        // forwarded so the backend can price the remainder at audio
        // rate.
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 3500,   // raw total
            responseTokenCount: 160,  // raw total
            totalTokenCount: 3660,
            promptAudioTokens: 2100,  // breakdown sums to 3300 — 200 less than total
            promptTextTokens: 1200,
            responseAudioTokens: 150, // breakdown sums to 150 — 10 less than total
            responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))

        XCTAssertEqual(captured.count, 1)
        let summary = try XCTUnwrap(captured.first)
        XCTAssertEqual(summary.promptTokensText, 1200)
        XCTAssertEqual(summary.promptTokensAudio, 2100)
        XCTAssertEqual(summary.promptTokensTotal, 3500,
                       "raw promptTokenCount must be forwarded verbatim, not reduced to breakdown sum")
        XCTAssertGreaterThan(summary.promptTokensTotal,
                             summary.promptTokensText + summary.promptTokensAudio,
                             "total > breakdown exposes the unattributed remainder the backend prices at audio rate")
        XCTAssertEqual(summary.responseTokensText, 0)
        XCTAssertEqual(summary.responseTokensAudio, 150)
        XCTAssertEqual(summary.responseTokensTotal, 160)
    }

    func test_totals_accumulate_across_multiple_generation_passes() async throws {
        // Tool-call turn: two usage frames (one per response). Totals
        // must SUM across responses, matching the sumPromptTokens
        // accumulator semantics. Mirrors the real 2026-04-22 prod session
        // where turn 1 showed 3501 + 3642 = 7143 across two passes.
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Response 1 — user speech + tool call.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 3501, responseTokenCount: 12, totalTokenCount: 3513,
            promptAudioTokens: 2000, promptTextTokens: 1300,
            responseAudioTokens: 0, responseTextTokens: 12,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))
        // Response 2 — after tool output, spoken reply.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 3642, responseTokenCount: 200, totalTokenCount: 3842,
            promptAudioTokens: 2100, promptTextTokens: 1350,
            responseAudioTokens: 195, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))

        XCTAssertEqual(captured.count, 1)
        let summary = try XCTUnwrap(captured.first)
        XCTAssertEqual(summary.promptTokensTotal, 7143,
                       "tool-call turn must SUM promptTokenCount across passes (3501 + 3642)")
        XCTAssertEqual(summary.responseTokensTotal, 212,
                       "response total must sum across passes (12 + 200)")
        XCTAssertEqual(summary.promptTokensText, 2650)   // 1300 + 1350
        XCTAssertEqual(summary.promptTokensAudio, 4100)  // 2000 + 2100
        XCTAssertEqual(summary.responseTokensText, 12)
        XCTAssertEqual(summary.responseTokensAudio, 195)
    }

    // MARK: - TTFA measurement (Live path)

    func test_ttfa_anchors_on_last_preaudio_speechStopped() async throws {
        // TTFA = time from the LAST `speech_stopped` that arrived BEFORE
        // first model audio to the first audio chunk. `speech_stopped` is
        // the only anchor: the input transcript lands later and
        // asynchronously (often after audio has started), so neither a
        // pre-audio nor a post-audio transcription frame may touch it.
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // VAD fires speech_stopped, then a second one 120 ms later (the
        // user resumed briefly). The last pre-audio one wins.
        await driver._testInjectFrame(.userSpeechEnded)
        try await Task.sleep(for: .milliseconds(120))
        await driver._testInjectFrame(.userSpeechEnded)

        // Simulate server-side thinking latency before audio arrives.
        // A transcript landing mid-window must NOT move the anchor (it
        // would shift it later and under-report TTFA).
        try await Task.sleep(for: .milliseconds(150))
        var earlyTranscript = LiveServerContent()
        earlyTranscript.inputTranscription = LiveTranscription(text: "next step", finished: true)
        await driver._testInjectFrame(.serverContent(earlyTranscript))
        try await Task.sleep(for: .milliseconds(150))

        // First audio chunk. TTFA clock stops.
        var firstAudio = LiveServerContent()
        firstAudio.audioChunks = [LiveAudioChunk(base64: "AA==", mimeType: "audio/pcm;rate=24000")]
        await driver._testInjectFrame(.serverContent(firstAudio))

        // A speech_stopped AFTER audio started must NOT move the anchor
        // forward either.
        try await Task.sleep(for: .milliseconds(100))
        await driver._testInjectFrame(.userSpeechEnded)

        // Later audio chunk. Must NOT update firstModelAudioAt.
        var laterAudio = LiveServerContent()
        laterAudio.audioChunks = [LiveAudioChunk(base64: "BB==", mimeType: "audio/pcm;rate=24000")]
        await driver._testInjectFrame(.serverContent(laterAudio))

        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 500, responseTokenCount: 50, totalTokenCount: 550,
            promptAudioTokens: 500, promptTextTokens: 0,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))

        XCTAssertEqual(captured.count, 1)

        // TTFA ≈ (firstAudio - second speech_stopped) ≈ 300 ms. Allow
        // headroom for Task.sleep drift on CI runners. Must NOT be
        // ~420 ms (anchor stamped on the first speech_stopped) and must
        // NOT be ~150 ms (anchor dragged forward by the transcript).
        let ttfa = captured.first?.latencyTtfaMs ?? -1
        XCTAssertGreaterThanOrEqual(ttfa, 250,
                                    "TTFA must clock from the last pre-audio speech_stopped, not from the transcript")
        XCTAssertLessThanOrEqual(ttfa, 410,
                                 "TTFA must not include the 120 ms before the last speech_stopped " +
                                 "and must not advance past audio start")
    }

    func test_ttfa_is_zero_when_no_speechStopped_fires() async throws {
        // Defensive: a turn with no `speech_stopped` (text-injected turns,
        // or a dropped event) has no user-end anchor. ttfa must return 0 —
        // NOT a garbage wall-clock diff against turnStartedAt, and NOT an
        // anchor taken from a transcript frame. The dashboard filters
        // zeros so those turns are excluded from p95 rather than
        // dragging the metric.
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // A transcript alone must not create an anchor.
        var transcript = LiveServerContent()
        transcript.inputTranscription = LiveTranscription(text: "next step", finished: true)
        await driver._testInjectFrame(.serverContent(transcript))

        var firstAudio = LiveServerContent()
        firstAudio.audioChunks = [LiveAudioChunk(base64: "AA==", mimeType: "audio/pcm;rate=24000")]
        await driver._testInjectFrame(.serverContent(firstAudio))

        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 100, responseTokenCount: 10, totalTokenCount: 110,
            promptAudioTokens: 100, promptTextTokens: 0,
            responseAudioTokens: 10, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.latencyTtfaMs, 0,
                       "unmeasurable turns must surface as 0, not a wall-clock fallback")
    }

    // MARK: - Race: usage arriving AFTER early-fire clears pendingReport

    func test_usageMetadata_arriving_after_flush_is_noop() async throws {
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Complete turn, then trailing usage → one report.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 500, responseTokenCount: 100, totalTokenCount: 600,
            promptAudioTokens: 500, promptTextTokens: 0,
            responseAudioTokens: 100, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))
        XCTAssertEqual(captured.count, 1)

        // A second usageMetadata (a duplicate or late frame) MUST NOT
        // fire a second report — pendingReport is nil after the flush.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 999, responseTokenCount: 999, totalTokenCount: 1998,
            promptAudioTokens: 999, promptTextTokens: 0,
            responseAudioTokens: 999, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))
        XCTAssertEqual(captured.count, 1, "second usage must not double-fire the report")
    }

    // MARK: - containedToolCall flag (ADR 0012 TTFA gate split)

    func test_containedToolCall_defaultsFalse_onPlainTurn() async throws {
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Plain turn: turnComplete + usage. No toolCall frame injected.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 500, responseTokenCount: 50, totalTokenCount: 550,
            promptAudioTokens: 500, promptTextTokens: 0,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))

        XCTAssertEqual(captured.count, 1)
        XCTAssertFalse(captured.first?.containedToolCall ?? true,
                       "turns with no toolCall frame must surface as normal — " +
                       "drives cook_turn_resolved.result_type = normal (ADR 0012)")
    }

    func test_containedToolCall_trueWhenToolFrameSeen() async throws {
        let driver = makeDriver()
        driver._testInstallLiveTransport(MockLiveTransport())
        defer { driver.close() }
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Tool-call handler is gated on `liveStates` (.userSpeaking, .ready,
        // .modelSpeaking, .thinking, .toolCalling). The test harness starts
        // in .idle and skips the real preWarm flow, so we advance to .ready
        // explicitly to pass the guard.
        driver._testAdvance(to: .ready)

        // Inject a harmless tool call (get_timer_status has no side
        // effects — callback unwired in the test harness → returns a
        // default empty snapshot). This exercises handleToolCall →
        // stateMachine.advance(.toolCalling) → turnContainedToolCall = true.
        let call = LiveFunctionCall(id: "fc_1", name: "get_timer_status", args: [:])
        await driver._testInjectFrame(.toolCall(LiveToolCall(functionCalls: [call])))

        // Turn-complete + trailing usage to flush the pending report.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 1200, responseTokenCount: 50, totalTokenCount: 1250,
            promptAudioTokens: 200, promptTextTokens: 1000,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))

        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(captured.first?.containedToolCall ?? false,
                      "turns with a toolCall frame must surface as tool_call — " +
                      "drives cook_turn_resolved.result_type = tool_call (ADR 0012)")
    }

    func test_containedToolCall_resetsPerTurn() async throws {
        // Turn 1 has a tool call; turn 2 doesn't. The flag must clear
        // at finalize-turn; otherwise every subsequent turn inherits
        // the prior turn's classification and every event post-tool
        // gets mistagged as tool_call.
        let driver = makeDriver()
        driver._testInstallLiveTransport(MockLiveTransport())
        defer { driver.close() }
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Pass the tool-call handler's liveStates guard (see test above).
        driver._testAdvance(to: .ready)

        // Turn 1 — with tool call.
        let call = LiveFunctionCall(id: "fc_1", name: "get_timer_status", args: [:])
        await driver._testInjectFrame(.toolCall(LiveToolCall(functionCalls: [call])))
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 1200, responseTokenCount: 50, totalTokenCount: 1250,
            promptAudioTokens: 200, promptTextTokens: 1000,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))

        // Turn 2 — plain.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 500, responseTokenCount: 50, totalTokenCount: 550,
            promptAudioTokens: 500, promptTextTokens: 0,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )))

        XCTAssertEqual(captured.count, 2)
        XCTAssertTrue(captured[0].containedToolCall, "turn 1 had a tool call")
        XCTAssertFalse(captured[1].containedToolCall,
                       "turn 2 must NOT inherit turn 1's tool-call flag — flag resets in finalizeTurn()")
    }

    // MARK: - voice_session_refreshed resolved callback (pre-commit failure)

    /// Pins the contract that `onVoiceSessionRefreshResolved` fires with
    /// success=false when the mint round-trip throws (before the
    /// transport swap commits). Spec §15 voice_session_refreshed must
    /// carry `success: bool` on BOTH paths — prior design fired on
    /// request only, making refresh failures telemetry-invisible and
    /// leaving the Voice session health "refresh success rate" tile
    /// one-sided. Regression class: 0% failure emissions observed in
    /// prod 2026-04-22 spike.
    func test_refreshSession_firesResolvedCallback_withFalse_whenMintFails() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        MockURLProtocol.handler = { _ in
            // Realistic backend-error shape — 500 with an opaque body.
            // AIDispatch.realtimeSession maps 5xx to StirError.server,
            // which refreshSession() catches.
            let response = HTTPURLResponse(
                url: URL(string: "https://test.invalid/functions/v1/realtime-session")!,
                statusCode: 500, httpVersion: nil, headerFields: nil,
            )!
            return (response, Data("{}".utf8))
        }

        let driver = makeDriverWithMockURLProtocol()
        let resolvedBox = ResolveCaptureBox()
        driver.onVoiceSessionRefreshResolved = { reason, turns, sessionID, success in
            resolvedBox.record(reason: reason, turns: turns, sessionID: sessionID, success: success)
        }

        // Pass the "preWarm" state guard (driver construction starts .idle,
        // refresh guards on .closed / .error — so we advance to .ready
        // which is a valid non-terminal state that refreshSession accepts).
        driver._testAdvance(to: .ready)

        await driver.refreshSession(reason: "minutes")

        let capture = try XCTUnwrap(resolvedBox.first,
                                    "resolved callback must fire exactly once per refreshSession invocation")
        XCTAssertFalse(capture.success, "mint 500 is a pre-commit failure; success must be false")
        XCTAssertEqual(capture.reason, "minutes", "reason must pass through unchanged")
        // Pre-commit failure path: sessionID is the ORIGINAL session id
        // (the destination never came up; source still owns the session).
        XCTAssertEqual(capture.sessionID, driver.voiceSessionID ?? "",
                       "pre-commit failure must report the ORIGINAL session id — the source is still live")
    }

    /// Pins the success-path emission too — otherwise the failure test
    /// above could spuriously pass against a callback that never fires.
    /// Can't run a full successful refresh end-to-end from a unit test
    /// (it needs a live WS server with setupComplete), so this test
    /// verifies the callback field is SETTABLE and the driver exposes
    /// the expected signature. Full success-path coverage lives in the
    /// device-session validation run.
    func test_refreshResolved_callback_signature_matches_contract() {
        let driver = makeDriverWithMockURLProtocol()
        var signatureAccepts: Bool = false
        driver.onVoiceSessionRefreshResolved = { reason, turns, sessionID, success in
            // Four params, in this order. If the callback signature
            // drifts, this closure assignment fails to compile.
            _ = (reason, turns, sessionID, success)
            signatureAccepts = true
        }
        XCTAssertNotNil(driver.onVoiceSessionRefreshResolved)
        XCTAssertFalse(signatureAccepts, "closure hasn't been invoked yet")
    }

    // MARK: - OpenAI tool-call turn (two responses) and cached-token reporting

    /// Feed raw OpenAI event JSON through the real parser and into the
    /// driver, in the order the transport would deliver the frames.
    private func inject(_ driver: RealtimeSession, _ json: String) async throws {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [])
        for frame in LiveInboundFrame.parseAll(object) {
            await driver._testInjectFrame(frame)
        }
    }

    func test_toolCallTurn_sumsBothResponses_andCompletesOnlyOnTheSecond() async throws {
        let driver = makeDriver()
        driver._testInstallLiveTransport(MockLiveTransport())
        defer { driver.close() }
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }
        driver._testAdvance(to: .ready)

        // Response 1 ends in a tool call: arguments.done, then response.done
        // carrying usage and a function_call item. NOT the end of the turn.
        try await inject(driver, """
        {"type":"response.function_call_arguments.done","call_id":"call_1",
         "name":"get_timer_status","arguments":"{}"}
        """)
        try await inject(driver, """
        {"type":"response.done","response":{"status":"completed",
         "output":[{"type":"function_call","name":"get_timer_status","call_id":"call_1","arguments":"{}"}],
         "usage":{"total_tokens":1010,"input_tokens":1000,"output_tokens":10,
          "input_token_details":{"text_tokens":400,"audio_tokens":600,"cached_tokens":0},
          "output_token_details":{"text_tokens":10,"audio_tokens":0}}}}
        """)
        XCTAssertTrue(captured.isEmpty, "a tool-call response must not complete the turn")
        XCTAssertEqual(driver.currentState, .toolCalling, "still waiting for the spoken reply")

        // Response 2: the spoken reply, with cache hits, completes the turn.
        try await inject(driver, #"{"type":"response.output_audio.delta","delta":"AA=="}"#)
        try await inject(driver, """
        {"type":"response.done","response":{"status":"completed",
         "output":[{"type":"message","role":"assistant"}],
         "usage":{"total_tokens":1260,"input_tokens":1100,"output_tokens":160,
          "input_token_details":{"text_tokens":500,"audio_tokens":600,"cached_tokens":900,
            "cached_tokens_details":{"text_tokens":450,"audio_tokens":450}},
          "output_token_details":{"text_tokens":10,"audio_tokens":150}}}}
        """)

        XCTAssertEqual(captured.count, 1, "exactly one report for the whole tool-call turn")
        let summary = try XCTUnwrap(captured.first)
        XCTAssertTrue(summary.containedToolCall, "arguments.done latched the tool flag before the turn finalized")
        XCTAssertEqual(summary.promptTokensTotal, 2100, "1000 + 1100 summed across both responses")
        XCTAssertEqual(summary.responseTokensTotal, 170)
        XCTAssertEqual(summary.promptTokensText, 900)
        XCTAssertEqual(summary.promptTokensAudio, 1200)
        XCTAssertEqual(driver.currentState, .ready)
    }

    func test_voiceTurnUsagePost_carriesCachedTextAndAudioSeparately() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let log = RequestLog()
        installMintFailingHandler(log: log)
        let driver = makeDriverWithMockURLProtocol()
        driver._testAdvance(to: .ready)

        try await inject(driver, """
        {"type":"response.done","response":{"status":"completed","output":[],
         "usage":{"total_tokens":950,"input_tokens":800,"output_tokens":150,
          "input_token_details":{"text_tokens":300,"audio_tokens":500,"cached_tokens":200,
            "cached_tokens_details":{"text_tokens":120,"audio_tokens":80}},
          "output_token_details":{"text_tokens":20,"audio_tokens":130}}}}
        """)

        let body = try await log.awaitBody(forPathSuffix: "/voice-turn-usage")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let turns = try XCTUnwrap(root["turns"] as? [[String: Any]])
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn["prompt_tokens_cached"] as? Int, 120, "cached TEXT tokens only")
        XCTAssertEqual(turn["prompt_tokens_cached_audio"] as? Int, 80, "cached AUDIO tokens")
        XCTAssertEqual(turn["prompt_tokens_total"] as? Int, 800)
    }

    func test_voiceTurnUsagePost_omitsCachedFieldsWhenNothingWasCached() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let log = RequestLog()
        installMintFailingHandler(log: log)
        let driver = makeDriverWithMockURLProtocol()
        driver._testAdvance(to: .ready)

        try await inject(driver, """
        {"type":"response.done","response":{"status":"completed","output":[],
         "usage":{"total_tokens":110,"input_tokens":100,"output_tokens":10,
          "input_token_details":{"text_tokens":40,"audio_tokens":60,"cached_tokens":0,
            "cached_tokens_details":{"text_tokens":0,"audio_tokens":0}},
          "output_token_details":{"text_tokens":0,"audio_tokens":10}}}}
        """)

        let body = try await log.awaitBody(forPathSuffix: "/voice-turn-usage")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let turn = try XCTUnwrap((root["turns"] as? [[String: Any]])?.first)
        XCTAssertNil(turn["prompt_tokens_cached"], "zero cache hits are omitted, not sent as 0")
        XCTAssertNil(turn["prompt_tokens_cached_audio"])
    }

    // MARK: - Input transcript is a full utterance, not a delta

    func test_twoInputUtterancesInOneTurn_areSpaceJoined() async throws {
        // The transcript arrives as a full utterance per `completed`
        // event. Two in one turn (VAD split a pause) must not run
        // together as "how longdo you sear".
        let driver = makeDriver()
        var transcripts: [LiveTurnTranscript] = []
        driver.onTurnTranscriptFinalized = { transcripts.append($0) }
        driver._testAdvance(to: .ready)

        try await inject(driver, #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"How long"}"#)
        try await inject(driver, #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"do you sear it?"}"#)
        try await inject(driver, #"{"type":"response.done","response":{"status":"completed","output":[],"usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}}}"#)

        XCTAssertEqual(transcripts.first?.userText, "How long do you sear it?")
    }

    // MARK: - Refresh policy (ADR 0038 decision 4)

    func test_refresh_doesNotTriggerOnTurnCountOrPromptTokens() async throws {
        // The old cadence (every 4 turns) and token burst (> 10k prompt
        // tokens in a turn) triggers are retired: a refresh discards the
        // provider's prompt cache. Twelve heavy turns inside the first
        // minutes of a session must not mint anything.
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let log = RequestLog()
        installMintFailingHandler(log: log)
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let driver = makeDriverWithMockURLProtocol(now: { clock.current })
        driver.transportOpenedAt = clock.current
        driver._testAdvance(to: .ready)
        let resolved = ResolveCaptureBox()
        driver.onVoiceSessionRefreshResolved = { reason, turns, sessionID, success in
            resolved.record(reason: reason, turns: turns, sessionID: sessionID, success: success)
        }

        for _ in 0 ..< 12 {
            clock.advance(by: 30)
            await driver._testInjectFrame(.usageMetadata(heavyUsage()))
            await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(log.count(forPathSuffix: "/realtime-session"), 0, "no mint on turn count or token volume")
        XCTAssertTrue(resolved.captures.isEmpty, "no refresh may start")
        XCTAssertFalse(driver._testPendingPreMintIsSet, "no pre-mint this early either")
    }

    func test_refresh_triggersAtTransportAge55Minutes_withReasonMinutes() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let log = RequestLog()
        installMintFailingHandler(log: log)
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let driver = makeDriverWithMockURLProtocol(now: { clock.current })
        driver.transportOpenedAt = clock.current
        driver._testAdvance(to: .ready)
        let resolved = ResolveCaptureBox()
        driver.onVoiceSessionRefreshResolved = { reason, turns, sessionID, success in
            resolved.record(reason: reason, turns: turns, sessionID: sessionID, success: success)
        }

        clock.advance(by: LiveSessionBudget.refreshAtSessionAgeSec)
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))

        // finalizeTurn starts the refresh in a Task; wait for it to resolve.
        let capture = try await resolved.awaitFirst()
        XCTAssertEqual(capture.reason, "minutes")
        XCTAssertFalse(capture.success, "the stubbed mint fails; the point is that the age trigger fired")
        XCTAssertEqual(log.count(forPathSuffix: "/realtime-session"), 1)
    }

    func test_refresh_doesNotTriggerJustUnderTheBoundary_butPreMintsFromMinute54() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let log = RequestLog()
        installMintFailingHandler(log: log)
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let driver = makeDriverWithMockURLProtocol(now: { clock.current })
        driver.transportOpenedAt = clock.current
        driver._testAdvance(to: .ready)
        let resolved = ResolveCaptureBox()
        driver.onVoiceSessionRefreshResolved = { reason, turns, sessionID, success in
            resolved.record(reason: reason, turns: turns, sessionID: sessionID, success: success)
        }

        // 1 s before the pre-mint age: nothing.
        clock.advance(by: LiveSessionBudget.preMintAtSessionAgeSec - 1)
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        XCTAssertFalse(driver._testPendingPreMintIsSet)

        // At the pre-mint age: the mint starts, but the session is not refreshed.
        clock.advance(by: 1)
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        XCTAssertTrue(driver._testPendingPreMintIsSet, "minute 54 starts the background mint")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(resolved.captures.isEmpty, "pre-mint is not a refresh")
        XCTAssertEqual(LiveSessionBudget.preMintAtSessionAgeSec, 54 * 60)
        XCTAssertEqual(LiveSessionBudget.refreshAtSessionAgeSec, 55 * 60)
    }

    func test_refresh_discardsPreMintedSecretPastItsExpiresAt_andMintsFresh() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let log = RequestLog()
        installMintFailingHandler(log: log)
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let driver = makeDriverWithMockURLProtocol(now: { clock.current })
        driver._testAdvance(to: .ready)

        // Fresh by age (it "started" now) but the secret it resolves to
        // has already passed its `expires_at`.
        let expired = Task<RealtimeSessionResponse, Error> {
            MockMintResponse.make(expiresAt: "2001-01-01T00:00:00Z")
        }
        driver._testSetPreMintTask(expired, startedAt: clock.current)

        let outcome = await driver.refreshSession(reason: "minutes")

        XCTAssertEqual(log.count(forPathSuffix: "/realtime-session"), 1,
                       "an expired pre-minted secret must be replaced by a sync mint")
        XCTAssertEqual(outcome, .preCommitFailure, "the stubbed sync mint fails")
    }

    func test_refresh_usesPreMintedSecretThatIsStillValid() async throws {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        let log = RequestLog()
        installMintFailingHandler(log: log)
        let clock = TestClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let driver = makeDriverWithMockURLProtocol(now: { clock.current })
        driver._testAdvance(to: .ready)

        let valid = Task<RealtimeSessionResponse, Error> {
            MockMintResponse.make(expiresAt: "2099-01-01T00:00:00Z", wsURL: "wss://test.invalid")
        }
        driver._testSetPreMintTask(valid, startedAt: clock.current)

        // The pre-minted secret is used (no mint request); the refresh then
        // fails at the transport's host pin because the stub URL isn't
        // api.openai.com — still a pre-commit failure, which is the point.
        let outcome = await driver.refreshSession(reason: "minutes")

        XCTAssertEqual(log.count(forPathSuffix: "/realtime-session"), 0,
                       "a valid pre-minted secret must be used, not re-minted")
        XCTAssertEqual(outcome, .preCommitFailure)
    }

    private func heavyUsage() -> LiveUsageMetadata {
        LiveUsageMetadata(
            promptTokenCount: 20_000, responseTokenCount: 100, totalTokenCount: 20_100,
            promptAudioTokens: 10_000, promptTextTokens: 10_000,
            responseAudioTokens: 100, responseTextTokens: 0,
            cachedContentTokenCount: nil,
            cachedAudioTokens: nil,
        )
    }

    /// Mint (`/realtime-session`) answers 429 — a non-retryable error, so
    /// failures resolve immediately instead of riding the 5xx backoff.
    /// Everything else (voice-turn-usage) answers 204.
    private func installMintFailingHandler(log: RequestLog) {
        MockURLProtocol.handler = { request in
            log.record(request)
            let url = request.url ?? URL(string: "https://test.invalid")!
            let status = (request.url?.path ?? "").hasSuffix("/realtime-session") ? 429 : 204
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, status == 429 ? Data("{}".utf8) : Data())
        }
    }

    // MARK: - Helpers

    private func makeDriver(now: @escaping @Sendable () -> Date = Date.init) -> RealtimeSession {
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
        let mint = MockMintResponse.make(wsURL: "wss://test.invalid")
        return RealtimeSession(
            testingOnlyMintResponse: mint,
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(controller: controller),
            cookingSession: cookingSession,
            now: now,
        )
    }

    private func serverContent(turnComplete: Bool) -> LiveServerContent {
        var content = LiveServerContent()
        content.turnComplete = turnComplete
        return content
    }

    /// Variant of makeDriver() that routes AIDispatch through
    /// MockURLProtocol so refresh-time mint calls can be scripted from
    /// the test. Same cooking-session + voice-turn repo, same pre-mint
    /// response; only the URLSession differs.
    private func makeDriverWithMockURLProtocol(now: @escaping @Sendable () -> Date = Date.init) -> RealtimeSession {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil, sentry: nil, revenueCat: nil,
            build: "1.0.0 (1)", osVersion: "17.5",
        )
        let sessionClient = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: MockURLProtocol.stubSession(),
            sentry: NoOpSentryReporter(),
        )
        let aiDispatch = AIDispatch(session: sessionClient, config: config)
        let mint = MockMintResponse.make(wsURL: "wss://test.invalid")
        return RealtimeSession(
            testingOnlyMintResponse: mint,
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(controller: controller),
            cookingSession: cookingSession,
            now: now,
        )
    }
}

/// MainActor-isolated capture shim for the refresh-resolved callback.
/// Avoids `var captured` in-test-method because the callback is
/// @MainActor-isolated and the test body runs on MainActor — a direct
/// mutating closure is legal but reads more clearly as an explicit
/// value type.
@MainActor
private final class ResolveCaptureBox {
    struct Capture {
        let reason: String
        let turns: Int
        let sessionID: String
        let success: Bool
    }
    private(set) var captures: [Capture] = []
    var first: Capture? { captures.first }

    /// Poll until the first capture lands (refresh runs in an un-awaited
    /// Task started by finalizeTurn). Fails the wait after `timeout`.
    func awaitFirst(timeout: Duration = .seconds(3)) async throws -> Capture {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let first { return first }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("refresh resolved callback never fired within \(timeout)")
        throw WaitTimeout()
    }

    func record(reason: String, turns: Int, sessionID: String, success: Bool) {
        captures.append(Capture(
            reason: reason,
            turns: turns,
            sessionID: sessionID,
            success: success,
        ))
    }
}

/// Thrown after `XCTFail` when a polled wait times out, to abort the test.
private struct WaitTimeout: Error {}

/// Mutable clock shared with the driver's `now` closure. Lock-backed so it
/// satisfies `@Sendable` without actor hops in the test body.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var current: Date {
        lock.lock(); defer { lock.unlock() }
        return date
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}

/// Records requests that reach `MockURLProtocol` (path + body). The handler
/// runs on a URLSession thread, hence the lock.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(path: String, body: Data?)] = []

    func record(_ request: URLRequest) {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }
        lock.lock(); defer { lock.unlock() }
        entries.append((request.url?.path ?? "", body))
    }

    func count(forPathSuffix suffix: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { $0.path.hasSuffix(suffix) }.count
    }

    /// Wait for a request whose path ends with `suffix` and return its body
    /// (the fire-and-forget usage POST runs in a detached Task).
    func awaitBody(forPathSuffix suffix: String, timeout: Duration = .seconds(3)) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            lock.lock()
            let match = entries.first { $0.path.hasSuffix(suffix) }?.body
            lock.unlock()
            if let match { return match }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("no request to \(suffix) within \(timeout)")
        throw WaitTimeout()
    }
}
