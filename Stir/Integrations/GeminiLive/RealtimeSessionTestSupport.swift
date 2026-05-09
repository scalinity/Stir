// RealtimeSessionTestSupport
//
// SCA-79 review S8 (CR3): test-only `_test*` hooks extracted out of
// the main `RealtimeSession.swift`. The hooks are gated `#if DEBUG`
// and do NOT compile into release builds — same posture as before,
// just relocated so the main file is no longer ~150 LOC of test
// surface mixed with production code.
//
// What lives here:
//
//   - Frame-injection seam (`_testInjectFrame`) — drives
//     `handleInboundFrame` (StateMachine extension) without a real
//     receive dispatcher.
//   - State-machine driver (`_testAdvance`) — back door for tests
//     that need to exercise handlers gated on `liveStates` without
//     running mint + WS handshake.
//   - Watchdog synchronous trigger (`_testFireTurnStuckWatchdog`) —
//     calls `turnStuckWatchdogFired` (StateMachine extension) without
//     waiting on the 15 s sleep.
//   - Pre-mint slot probes (`_testSetPreMintTask`, `_testPendingPreMintIsSet`,
//     `_testPendingPreMintStartedAt`, `_testConsumePreMintedTaskIfFresh`,
//     `_testKickOffPreMintIfBudgetAllows`, `_testTearDownPreMintSlot`) —
//     exercise the StateMachine pre-mint API surface deterministically.
//   - Field accessors (`_testMostRecentTtfaMs`, `_testLastToolCallName`)
//     — tests assert against last-finalized turn state.
//   - Mock harnesses (`MockMintResponse`, `MockLiveTransport`) — tests can
//     construct valid mint payloads and drive transport send/receive paths
//     without touching Gemini Live.
//
// What does NOT live here: the `init(testingOnlyMintResponse:...)`
// initializer remains in `RealtimeSession.swift` inside its own
// `#if DEBUG` block — Swift's designated-init-in-extension rules for
// `final class` are restrictive enough that keeping the init in the
// type body is the safe path. Test code using the init keeps working
// unchanged.
//
// Test-side migration: zero. All hook signatures preserved verbatim;
// existing `StirTests/Unit/RealtimeSession*Tests.swift` files compile
// and pass without import changes.

#if DEBUG

import Foundation

extension RealtimeSession {

    /// Test-only frame injection for the pending-report reporting path.
    /// Feeds a synthetic inbound frame through `handleInboundFrame`
    /// exactly as the receive dispatcher would — tests can stage
    /// same-envelope, leading-envelope, and trailing-envelope
    /// usageMetadata patterns and observe `onTurnFinalized` to verify
    /// the POST payload would carry the right token counts.
    ///
    /// Not exposed in release — the receive dispatcher is the only
    /// production caller of `handleInboundFrame` and injecting frames
    /// from anywhere else is a test concern.
    func _testInjectFrame(_ frame: LiveInboundFrame) async {
        await handleInboundFrame(frame)
    }

    /// TTFA computed by the most recent `finalizeTurn()`. Exposed for
    /// tests that assert the frame-sequence → TTFA pipeline; not
    /// usable in production because it reflects only the last-finalized
    /// turn and is reset when the session closes. Returns 0 before any
    /// turn finalizes.
    var _testMostRecentTtfaMs: Int {
        lastTurnResult?.sttLatencyMs ?? 0
    }

    /// Drives the internal state machine for tests. Production paths
    /// only ever advance via preWarm → handleInboundFrame; tests that
    /// need to exercise handlers gated on `liveStates` (`handleToolCall`)
    /// without running the real mint + WS handshake use this helper.
    /// Returns the advance result.
    ///
    /// Current callers (StirTests/Unit/RealtimeSessionReportingTests):
    ///   - test_containedToolCall_trueWhenToolFrameSeen
    ///   - test_containedToolCall_resetsPerTurn
    /// If you add a third call site, think hard about whether the
    /// handler under test has a legitimate production state-entry path
    /// the test could exercise instead — this helper is a deliberate
    /// back door, not a shortcut.
    @discardableResult
    func _testAdvance(to next: VoiceSessionState) -> Bool {
        stateMachine.advance(to: next)
    }

    /// P0-L (2026-04-23): synchronous trigger of the stuck-turnComplete
    /// watchdog path for testing. Equivalent to the watchdog Task
    /// timeout firing after `LiveSessionBudget.turnStuckWatchdogSec`
    /// of silence on the `.modelSpeaking` entry — but without the
    /// 15 s real-time wait. Exercises the exact recovery pipeline:
    ///
    ///   PostHog callback fires with (sessionID, turnIndex, toolCallType,
    ///   elapsedStuckMs, turnLengthAtStuck)
    ///   → `finalizeWasWatchdogFire = true`
    ///   → `.modelSpeaking` → `.ready`
    ///   → `finalizeTurn()` persists VoiceTurn with
    ///      resultType=.error, errorCode="turnComplete_timeout"
    ///   → pendingReport flush
    ///
    /// Caller responsibility: put the state machine in `.modelSpeaking`
    /// first (tests do this via `_testAdvance(to: .modelSpeaking)` or
    /// by injecting a serverContent frame carrying audio).
    func _testFireTurnStuckWatchdog() {
        turnStuckWatchdogFired()
    }

    /// P0-L test hook: inspect `lastToolCallName` so tests can verify
    /// the watchdog payload correctly latches the in-flight tool-call
    /// name from a preceding toolCall frame.
    var _testLastToolCallName: String? {
        lastToolCallName
    }

    /// P1-P test hook: inject a task + timestamp into the pre-mint slot.
    /// Drives `consumePreMintedTaskIfFresh` into each of its four lifecycle
    /// cases deterministically (close-before-consume, ready-before-refresh,
    /// 45 s staleness, in-flight-await) without waiting on a real mint
    /// HTTP round trip. Passing `nil` for `task` clears the slot; passing
    /// `nil` for `startedAt` is treated as infinitely stale by the consumer
    /// via the `.map { ... } ?? .infinity` branch in
    /// `consumePreMintedTaskIfFresh`.
    func _testSetPreMintTask(
        _ task: Task<RealtimeSessionResponse, Error>?,
        startedAt: Date?,
    ) {
        pendingPreMintTask = task
        pendingPreMintStartedAt = startedAt
    }

    /// P1-P test hook: non-destructive peek — true iff `pendingPreMintTask`
    /// is currently set. Does NOT trigger the consumer's defer-clear.
    /// Used by the seam-integration test to assert that
    /// `kickOffPreMintIfBudgetAllows` put something in the slot.
    var _testPendingPreMintIsSet: Bool {
        pendingPreMintTask != nil
    }

    /// P1-P test hook: non-destructive peek at `pendingPreMintStartedAt`.
    /// Returns nil after a stale-branch consumption cleared the slot;
    /// lifecycle tests use this to assert the consumer's defer ran.
    var _testPendingPreMintStartedAt: Date? {
        pendingPreMintStartedAt
    }

    /// P1-P test hook: test-accessible wrapper for the private consumer.
    /// Returns the Task if fresh, nil otherwise; clears state via the
    /// consumer's defer regardless of outcome. Same contract as the
    /// production call site in `refreshSession`.
    func _testConsumePreMintedTaskIfFresh() -> Task<RealtimeSessionResponse, Error>? {
        consumePreMintedTaskIfFresh()
    }

    /// P1-P test hook: synchronous wrapper for the private prewarm.
    /// Production trigger is deep in the finalize-turn path (fires only
    /// at `turnsSinceRefresh == refreshAtTurnCount - 1`, ~3 turns in);
    /// driving that naturally in a test would require a full multi-turn
    /// setup. The seam-integration test uses this hook to invoke the
    /// prewarm directly after injecting a MockURLProtocol-backed
    /// `AIDispatch` via the normal constructor, then asserts
    /// `_testPendingPreMintIsSet == true` to pin the seam.
    func _testKickOffPreMintIfBudgetAllows(currentTurn: Int) {
        kickOffPreMintIfBudgetAllows(currentTurn: currentTurn)
    }

    /// P1-P test hook: run the pre-mint teardown path exactly as
    /// `session.close()` does, without running the rest of close's
    /// 200-line teardown (continuations, transport, audio pipeline,
    /// etc.). Exercises `cancelAndClearPreMintSlot()` — the extracted
    /// symbol both the production `close()` and this hook call. A
    /// future refactor that moves the cancel or clear out of the
    /// extracted method is caught by P1-P test 1; a future refactor
    /// that removes the call from `close()` is caught by the paired
    /// wiring test (close-invokes-extraction).
    func _testTearDownPreMintSlot() {
        cancelAndClearPreMintSlot()
    }

    /// SCA-132 test hook: install a caller-owned mock transport without
    /// opening a URLSessionWebSocketTask. Tests can then start the receive
    /// dispatcher and yield frames through `MockLiveTransport`.
    func _testInstallLiveTransport(_ transport: any LiveTransporting) {
        self.transport = transport
    }
}

/// SCA-132: canonical mock mint payload builder. Keeps voice tests from
/// hand-writing subtly different `RealtimeSessionResponse` fixtures.
enum MockMintResponse {
    static func make(
        authToken: String = "auth_tokens/test",
        expiresAt: String = "2027-01-01T00:00:00Z",
        sessionID: String = UUID().uuidString,
        wsURL: String = "wss://generativelanguage.googleapis.com/v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=auth_tokens/test",
        promptVersion: String = "1.0.0",
        setupFrameJSON: String = "{\"setup\":{}}",
    ) -> RealtimeSessionResponse {
        RealtimeSessionResponse(
            authToken: authToken,
            expiresAt: expiresAt,
            sessionID: sessionID,
            wsURL: wsURL,
            promptVersion: promptVersion,
            setupFrameJSON: setupFrameJSON,
        )
    }
}

/// SCA-132: deterministic in-memory Live transport. It records opened URLs
/// and outbound frames, and lets tests yield inbound frames directly into
/// RealtimeSession's normal receive dispatcher.
@MainActor
final class MockLiveTransport: LiveTransporting {
    private(set) var inbound: AsyncThrowingStream<LiveInboundFrame, Error>
    private var continuation: AsyncThrowingStream<LiveInboundFrame, Error>.Continuation!

    private(set) var openedURLs: [URL] = []
    private(set) var sentFrames: [LiveOutboundFrame] = []
    private(set) var isClosed = false

    var openError: Error?
    var sendError: Error?

    init() {
        let pair = AsyncThrowingStream.makeStream(of: LiveInboundFrame.self)
        inbound = pair.stream
        continuation = pair.continuation
    }

    /// SCA-256 (W8 from /review-5): defensive `deinit` finishes the
    /// continuation if a test forgot to call `close()` / `finish()`.
    /// `AsyncThrowingStream.Continuation.finish()` is a no-op when
    /// invoked after the stream has already terminated, so the
    /// guarded path is safe even when callers explicitly closed.
    /// This keeps a stray test from leaking the producer-side
    /// continuation past the mock's lifetime — important if a future
    /// refactor moves the continuation off `self` to a long-lived
    /// owner where deallocation no longer naturally terminates the
    /// stream.
    deinit {
        continuation?.finish()
    }

    func open(url: URL) throws {
        if let openError { throw openError }
        openedURLs.append(url)
    }

    func close() {
        isClosed = true
        continuation.finish()
    }

    func send(_ frame: LiveOutboundFrame) async throws {
        if let sendError { throw sendError }
        sentFrames.append(frame)
    }

    func yield(_ frame: LiveInboundFrame) {
        continuation.yield(frame)
    }

    func finish(throwing error: Error? = nil) {
        continuation.finish(throwing: error)
    }
}

#endif
