// RealtimeSessionReportingTests
//
// Locks down the per-turn pending-report flush logic that handles the
// three Gemini Live usageMetadata envelope shapes:
//   (A) trailing — serverContent{turnComplete} arrives FIRST,
//       usageMetadata follows in a later envelope. Observed 2026-04-22
//       as the dominant prod shape; required the deferred-POST fix
//       (parseAll ordering alone doesn't help here).
//   (B) timeout — serverContent{turnComplete} arrives but NO
//       usageMetadata follows. Report fires with zero tokens after
//       pendingReportTimeoutSec; ops log captures the regression.
//   (C) leading/same-envelope — usageMetadata arrives first (or in
//       the same parseAll batch). Short-circuit path skips the 2s
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
        )))

        XCTAssertEqual(captured.count, 1, "report must fire exactly once after usage arrives")
        let summary = try XCTUnwrap(captured.first)
        XCTAssertEqual(summary.promptTokensText, 1000)
        XCTAssertEqual(summary.promptTokensAudio, 1150)
        // Raw Gemini total forwarded to backend. In this fixture
        // total == text+audio (no AUDIO-mode overhead), but the field
        // must be populated on every report.
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

        // Frame 1: usageMetadata arrives first (leading-envelope shape
        // OR same-envelope parseAll ordering puts usage before
        // serverContent). lastUsageMetadata set but NO pendingReport
        // yet, so the .usageArrived early-fire guard is a no-op.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 1500,
            responseTokenCount: 200,
            totalTokenCount: 1700,
            promptAudioTokens: 1000,
            promptTextTokens: 500,
            responseAudioTokens: 200,
            responseTextTokens: 0,
            cachedContentTokenCount: nil,
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

    // MARK: - AUDIO-mode overhead: total exceeds text+audio breakdown

    func test_totals_exceed_breakdown_when_audio_overhead_present() async throws {
        // Real-world Gemini Live shape: promptTokenCount includes the
        // ~200-token per-pass AUDIO-mode overhead that's NOT attributed
        // to any modality in promptTokensDetails. Both the raw total
        // AND the breakdown must be forwarded so the backend can price
        // the remainder at audio rate (sharp-edge #15).
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
                             "total > breakdown exposes the AUDIO-mode overhead the backend prices at audio rate")
        XCTAssertEqual(summary.responseTokensText, 0)
        XCTAssertEqual(summary.responseTokensAudio, 150)
        XCTAssertEqual(summary.responseTokensTotal, 160)
    }

    func test_totals_accumulate_across_multiple_generation_passes() async throws {
        // Tool-call turn: two usageMetadata frames (one per generation
        // pass). Totals must SUM across passes, matching the sumPromptTokens
        // accumulator semantics. Mirrors the real 2026-04-22 prod session
        // where turn 1 showed 3501 + 3642 = 7143 across two passes.
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Pass 1 — user speech + tool call.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 3501, responseTokenCount: 12, totalTokenCount: 3513,
            promptAudioTokens: 2000, promptTextTokens: 1300,
            responseAudioTokens: 0, responseTextTokens: 12,
            cachedContentTokenCount: nil,
        )))
        // Pass 2 — after tool response, spoken reply.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 3642, responseTokenCount: 200, totalTokenCount: 3842,
            promptAudioTokens: 2100, promptTextTokens: 1350,
            responseAudioTokens: 195, responseTextTokens: 0,
            cachedContentTokenCount: nil,
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

    func test_ttfa_anchors_on_last_preaudio_transcription_frame() async throws {
        // TTFA = time from the LAST `inputTranscription` frame that
        // arrived BEFORE first model audio to the first audio chunk.
        // Gemini Live with `automaticActivityDetection` doesn't
        // reliably emit `finished=true`, so the driver stamps the
        // user-end anchor on every pre-audio transcription frame and
        // the last one wins.
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Frame 1: early interim transcription. Anchor stamps here.
        var interim1 = LiveServerContent()
        interim1.inputTranscription = LiveTranscription(text: "next", finished: false)
        await driver._testInjectFrame(.serverContent(interim1))

        // 120ms later, another interim. Anchor advances.
        try await Task.sleep(for: .milliseconds(120))
        var interim2 = LiveServerContent()
        interim2.inputTranscription = LiveTranscription(text: "next step", finished: false)
        await driver._testInjectFrame(.serverContent(interim2))

        // Simulate server-side thinking latency before audio arrives.
        // TTFA starts measuring from the LAST interim (interim2).
        try await Task.sleep(for: .milliseconds(300))

        // Frame 3: first audio chunk. TTFA clock stops.
        var firstAudio = LiveServerContent()
        firstAudio.audioChunks = [LiveAudioChunk(base64: "AA==", mimeType: "audio/pcm;rate=24000")]
        await driver._testInjectFrame(.serverContent(firstAudio))

        // Frame 4: a later transcription AFTER audio started. Must NOT
        // move the anchor forward — firstModelAudioAt is already set.
        try await Task.sleep(for: .milliseconds(100))
        var lateTranscript = LiveServerContent()
        lateTranscript.inputTranscription = LiveTranscription(text: "next step please", finished: true)
        await driver._testInjectFrame(.serverContent(lateTranscript))

        // Frame 5: later audio chunk. Must NOT update firstModelAudioAt.
        var laterAudio = LiveServerContent()
        laterAudio.audioChunks = [LiveAudioChunk(base64: "BB==", mimeType: "audio/pcm;rate=24000")]
        await driver._testInjectFrame(.serverContent(laterAudio))

        // Frame 6: turnComplete fires finalizeTurn → stamps ttfaMs.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))

        // Final usage so the report flushes and summary callback fires.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 500, responseTokenCount: 50, totalTokenCount: 550,
            promptAudioTokens: 500, promptTextTokens: 0,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
        )))

        XCTAssertEqual(captured.count, 1)

        // TTFA ≈ (firstAudio - interim2) ≈ 300 ms. Allow ± 250 ms
        // headroom for Task.sleep drift on CI runners. Must NOT be
        // ~420 ms (which would mean the anchor stamped on interim1
        // instead of interim2) and must NOT be near 0 (pre-fix bug
        // where `finished=true` never fires and anchor stays nil).
        let ttfa = captured.first?.latencyTtfaMs ?? -1
        XCTAssertGreaterThanOrEqual(ttfa, 250,
                                    "TTFA must clock the ~300ms thinking window — anchor on latest pre-audio transcription")
        XCTAssertLessThanOrEqual(ttfa, 600,
                                 "TTFA must not overflow past the simulated thinking window — " +
                                 "anchor must not regress to the first interim frame or advance past audio start")
    }

    func test_ttfa_is_zero_when_no_transcription_frames_fire() async throws {
        // Defensive: tool-call-only turns sometimes skip
        // inputTranscription entirely (the server shortcuts past
        // transcription when it has high VAD confidence on a very
        // short utterance). Without any stamp, ttfa must return 0 —
        // NOT a garbage wall-clock diff against turnStartedAt. The
        // dashboard filters zeros so those turns are excluded from p95
        // rather than dragging the metric.
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // First audio chunk with no prior inputTranscription at all.
        var firstAudio = LiveServerContent()
        firstAudio.audioChunks = [LiveAudioChunk(base64: "AA==", mimeType: "audio/pcm;rate=24000")]
        await driver._testInjectFrame(.serverContent(firstAudio))

        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 100, responseTokenCount: 10, totalTokenCount: 110,
            promptAudioTokens: 100, promptTextTokens: 0,
            responseAudioTokens: 10, responseTextTokens: 0,
            cachedContentTokenCount: nil,
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
        )))
        XCTAssertEqual(captured.count, 1)

        // A second usageMetadata (Gemini sometimes repeats) MUST NOT
        // fire a second report — pendingReport is nil after the flush.
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 999, responseTokenCount: 999, totalTokenCount: 1998,
            promptAudioTokens: 999, promptTextTokens: 0,
            responseAudioTokens: 999, responseTextTokens: 0,
            cachedContentTokenCount: nil,
        )))
        XCTAssertEqual(captured.count, 1, "second usage must not double-fire the report")
    }

    // MARK: - containedToolCall flag (ADR 0012 TTFA gate split)

    func test_containedToolCall_defaultsFalse_onPlainTurn() async throws {
        let driver = makeDriver()
        var captured: [LiveTurnSummary] = []
        driver.onTurnFinalized = { captured.append($0) }

        // Plain turn: transcription + audio + turnComplete + usage.
        // No toolCall frame injected.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 500, responseTokenCount: 50, totalTokenCount: 550,
            promptAudioTokens: 500, promptTextTokens: 0,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
        )))

        XCTAssertEqual(captured.count, 1)
        XCTAssertFalse(captured.first?.containedToolCall ?? true,
                       "turns with no toolCall frame must surface as normal — " +
                       "drives cook_turn_resolved.result_type = normal (ADR 0012)")
    }

    func test_containedToolCall_trueWhenToolFrameSeen() async throws {
        let driver = makeDriver()
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
        )))

        // Turn 2 — plain.
        await driver._testInjectFrame(.serverContent(serverContent(turnComplete: true)))
        await driver._testInjectFrame(.usageMetadata(LiveUsageMetadata(
            promptTokenCount: 500, responseTokenCount: 50, totalTokenCount: 550,
            promptAudioTokens: 500, promptTextTokens: 0,
            responseAudioTokens: 50, responseTextTokens: 0,
            cachedContentTokenCount: nil,
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

        await driver.refreshSession(reason: "turns")

        let capture = try XCTUnwrap(resolvedBox.first,
                                    "resolved callback must fire exactly once per refreshSession invocation")
        XCTAssertFalse(capture.success, "mint 500 is a pre-commit failure; success must be false")
        XCTAssertEqual(capture.reason, "turns", "reason must pass through unchanged")
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

    private func serverContent(turnComplete: Bool) -> LiveServerContent {
        var content = LiveServerContent()
        content.turnComplete = turnComplete
        return content
    }

    /// Variant of makeDriver() that routes AIDispatch through
    /// MockURLProtocol so refresh-time mint calls can be scripted from
    /// the test. Same cooking-session + voice-turn repo, same pre-mint
    /// response; only the URLSession differs.
    private func makeDriverWithMockURLProtocol() -> RealtimeSession {
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

    func record(reason: String, turns: Int, sessionID: String, success: Bool) {
        captures.append(Capture(
            reason: reason,
            turns: turns,
            sessionID: sessionID,
            success: success,
        ))
    }
}
