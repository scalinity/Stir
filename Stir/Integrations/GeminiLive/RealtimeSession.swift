// RealtimeSession
//
// Gemini Live (3.1 Flash Live Preview) driver. Conforms to
// VoiceSessionDriver so CookModeViewModel can hold `any VoiceSessionDriver`
// without branching on path type — telemetry keys off `pathLabel`.
//
// Lifecycle mirrors SpeechFallbackService:
//   preWarm  → mint token (via /v1/ai/realtime-session) + open WS +
//              wait for setupComplete + prepare AudioPipeline.
//              Throws on mint failure or setup timeout — VM downgrades
//              to C.3 on any preWarm error.
//   beginTurn → start mic capture, frames stream to WS as realtimeInput.
//   endTurn   → flush mic, wait for serverContent turnComplete + any
//               toolCall round-trip, persist VoiceTurn, return result.
//   speak     → no-op on Live (audio already streamed during endTurn).
//   cancelSpeaking → stop audio player; user is about to begin a new turn.
//   close     → tear down WS + audio + audio session. Idempotent.
//
// What's STUBBED (explicit TODOs for post-D.1 tuning):
//   - Session refresh at 10 min / 15 turns with silent handoff. Scaffolded
//     as `refreshSession()` but not timer-triggered yet — pending D.1 data
//     on whether the silent-gap budget holds.
//   - Client-side filler audio clip on toolCall arrival (CLAUDE.md
//     §sharp-edge #3). Played via FillerClipPlayer; audio asset itself
//     is a placeholder until recorded.
//   - Pruning via sessionUpdate after step advances. Scaffolded as
//     `pruneAfterStepAdvance()` but not wired to the VM's step-advance
//     callback yet — pending D.1 data on token growth without pruning.

import AVFoundation
import Foundation
import OSLog

/// Numeric budgets for the Live driver. Mirrored from CLAUDE.md's
/// `LiveSessionLimits` spec. Keeping them here (scoped to the Live
/// path) rather than in a global struct because every value is
/// Live-specific and most have TODO(D.1) tunings pending.
@MainActor
enum LiveSessionBudget {
    /// Seconds to wait for the server's `setupComplete` handshake
    /// before failing `preWarm()`. Observed p95 is ~300 ms; 5 s is a
    /// generous upper bound.
    static let setupHandshakeSec: Double = 5
    /// Seconds to wait for the server's `turnComplete` frame after
    /// user audio closes. 2× Gemini's observed ~15 s p95 for a long
    /// multi-sentence response.
    static let turnCompleteSec: Double = 30
}

@MainActor
final class RealtimeSession: VoiceSessionDriver {

    // MARK: - VoiceSessionDriver conformance

    let pathLabel: VoiceSessionPath = .liveAPI

    var currentState: VoiceSessionState { stateMachine.state }

    // MARK: - Deps

    private let aiDispatch: AIDispatch
    private let voiceTurnRepository: VoiceTurnRepository
    private let cookingSession: CookingSession
    private let stateMachine = VoiceSessionStateMachine()

    // Transport + audio
    private var transport: LiveWebSocketTransport?
    private var audioPipeline: LiveAudioPipeline?

    // Session state
    private var mintResponse: RealtimeSessionResponse?
    private var turnCount: Int = 0

    // Mic forwarding task — reads mic frames from pipeline and sends
    // to the WebSocket. Started at beginTurn, cancelled at endTurn.
    private var micForwardTask: Task<Void, Never>?

    // Receive dispatcher task — reads inbound frames from transport
    // and updates state / plays audio / handles tool calls. Started
    // after preWarm succeeds.
    private var receiveDispatcherTask: Task<Void, Never>?

    // Per-turn accumulator. Reset at beginTurn.
    private var currentTurnInlineText: String?
    private var turnCompleteContinuation: CheckedContinuation<Void, Error>?
    private var lastUsageMetadata: LiveUsageMetadata?

    // Tool-call side-effect callbacks. Set by CookModeViewModel at
    // Cook Mode entry so this actor can route advance_step / start_timer
    // without direct VM coupling. substitution_check is handled
    // internally (dispatches to /v1/ai/substitution).
    var onAdvanceStepRequested: (() -> Void)?
    var onStartTimerRequested: ((_ seconds: Int, _ label: String?) -> Void)?

    // MARK: - Init

    init(
        aiDispatch: AIDispatch,
        voiceTurnRepository: VoiceTurnRepository,
        cookingSession: CookingSession,
    ) {
        self.aiDispatch = aiDispatch
        self.voiceTurnRepository = voiceTurnRepository
        self.cookingSession = cookingSession
    }

    // MARK: - Errors

    enum RealtimeSessionError: Error, Equatable, Sendable {
        /// Mint failed (backend 5xx or network error). VM → fall back to C.3.
        case mintFailed(message: String)
        /// WebSocket open failed (DNS, TLS, token rejected). VM → fall back.
        case openFailed(message: String)
        /// Didn't receive setupComplete within the handshake budget.
        case setupTimeout
        /// A turn ended without a turnComplete signal and without a
        /// connection drop — indicates a protocol bug. VM → fall back.
        case turnDrained
        /// User tapped mic while already in a conflicting state. Mirrors
        /// SpeechFallbackError.busy — VM branches on the typed error.
        case busy(state: VoiceSessionState)
        /// Caller invoked a method that requires an open session.
        case notOpen
    }

    // MARK: - preWarm

    /// Mint + open + handshake. Three network operations in sequence;
    /// any failure throws and the VM downgrades to C.3.
    ///
    /// Caller must have already activated AVAudioSession for Cook Mode
    /// (same precondition as SpeechFallbackService.preWarm).
    func preWarm() async throws {
        guard stateMachine.state == .idle else {
            throw RealtimeSessionError.busy(state: stateMachine.state)
        }
        #if DEBUG
        VoiceSessionLog.sessionStart()
        // Wire the state machine to echo every advance to the console
        // transcript. Must go through `onTransition` (not advance())
        // so illegal transitions also surface — the state machine
        // logs those separately at warning but D.1 wants a unified view.
        stateMachine.onTransition = { from, to in
            VoiceSessionLog.log("state.advance", [
                "from": from.rawValue,
                "to": to.rawValue,
            ])
        }
        #endif
        stateMachine.advance(to: .connecting)

        do {
            // 1. Mint
            #if DEBUG
            VoiceSessionLog.log("mint.start")
            #endif
            let mintRequest = try buildMintRequest()
            let response = try await aiDispatch.realtimeSession(request: mintRequest)
            self.mintResponse = response
            #if DEBUG
            VoiceSessionLog.log("mint.complete", [
                "session_id": response.sessionID,
                "prompt_version": response.promptVersion,
            ])
            #endif

            // 2. Open WebSocket
            guard let wsURL = URL(string: response.wsURL) else {
                #if DEBUG
                VoiceSessionLog.log("mint.invalid_ws_url")
                #endif
                throw RealtimeSessionError.openFailed(message: "invalid ws_url")
            }
            let transport = LiveWebSocketTransport()
            self.transport = transport
            try transport.open(url: wsURL)
            #if DEBUG
            VoiceSessionLog.log("ws.open")
            #endif

            // 3. Prepare audio pipeline (mic converter + playback node)
            let pipeline = LiveAudioPipeline()
            try pipeline.prepare()
            self.audioPipeline = pipeline
            #if DEBUG
            VoiceSessionLog.log("audio.prepared")
            #endif

            // 4. Start inbound receive dispatcher
            startReceiveDispatcher()

            // 5. Wait for setupComplete (budget named in
            //    LiveSessionBudget — server normally emits this within
            //    200-400 ms). Any inbound frame before setupComplete
            //    is a protocol violation and throws.
            //    TODO(D.1): measure real budget and tune.
            try await awaitSetupComplete(timeoutSec: LiveSessionBudget.setupHandshakeSec)
            #if DEBUG
            VoiceSessionLog.log("ws.setup_complete")
            #endif

            stateMachine.advance(to: .ready)
            Logger.voice.info("live_session_ready session_id=\(response.sessionID, privacy: .public)")
            #if DEBUG
            VoiceSessionLog.log("session.ready")
            #endif
        } catch {
            // Any preWarm failure tears down what we started and
            // surfaces the typed error. State machine moves to error.
            #if DEBUG
            VoiceSessionLog.logError("prewarm.failed", error: error)
            #endif
            stateMachine.advance(to: .error)
            close()
            throw error
        }
    }

    // MARK: - beginTurn

    func beginTurn() async throws {
        guard stateMachine.state == .ready else {
            #if DEBUG
            VoiceSessionLog.log("begin_turn.busy", ["state": stateMachine.state.rawValue])
            #endif
            throw RealtimeSessionError.busy(state: stateMachine.state)
        }
        guard let pipeline = audioPipeline else {
            throw RealtimeSessionError.notOpen
        }

        // Reset per-turn accumulators
        currentTurnInlineText = nil
        lastUsageMetadata = nil

        stateMachine.advance(to: .userSpeaking)
        try pipeline.startCapture()
        startMicForwarding()
        #if DEBUG
        // `turn = turnCount + 1`: the turn about to run. Matches the
        // value `turn.end_submitted` emits for the same turn, so a
        // grep for `turn=5` finds every event in turn 5.
        VoiceSessionLog.log("turn.begin", ["turn": turnCount + 1])
        #endif
    }

    // MARK: - endTurn

    func endTurn(
        recipeContext: RealtimeRecipeContext,
        householdContext: RealtimeHouseholdContext,
        currentStepNumber: Int,
        recipePlanId: UUID,
    ) async throws -> CookTurnResult {
        guard stateMachine.state == .userSpeaking else {
            throw RealtimeSessionError.busy(state: stateMachine.state)
        }
        // Stop mic capture (audio stream done). Server's automatic VAD
        // + turn_coverage config closes the turn on its own; we don't
        // send an explicit "end turn" frame — the audio pause IS the
        // signal on Live.
        audioPipeline?.stopCapture()
        stopMicForwarding()

        stateMachine.advance(to: .thinking)
        #if DEBUG
        VoiceSessionLog.log("turn.end_submitted", ["turn": turnCount + 1])
        #endif

        // Wait for serverContent turnComplete (the dispatch loop
        // advances state and fulfills the continuation).
        let submittedAt = Date()
        do {
            try await awaitTurnComplete()
        } catch {
            #if DEBUG
            VoiceSessionLog.logError("turn.timeout_or_error", error: error)
            #endif
            throw error
        }

        turnCount += 1
        #if DEBUG
        VoiceSessionLog.log("turn.complete", [
            "turn": turnCount,
            "latency_ms": Int(Date().timeIntervalSince(submittedAt) * 1000),
            "prompt_tokens": lastUsageMetadata?.promptTokenCount ?? -1,
            "total_tokens": lastUsageMetadata?.totalTokenCount ?? -1,
        ])
        #endif

        // Gemini Live doesn't return a structured "suggested_action"
        // on the normal response path — tool calls are the out-of-band
        // mechanism. The audio response itself IS the spoken response;
        // we already played it during the turn. Build a CookTurnResult
        // that mirrors the fallback shape but with audio transcribed
        // as empty (we don't have a transcript on Live; the model ate
        // the raw audio).
        //
        // TODO(D.1): if we need transcripts for VoiceTurn persistence,
        // add a post-turn STT pass OR request responseModalities: [AUDIO, TEXT]
        // in the mint. TEXT modality is cheap and gives us transcript.
        let totalMs = Int(Date().timeIntervalSince(submittedAt) * 1000)
        let response = CookTurnResponse(
            spokenResponse: currentTurnInlineText ?? "",
            suggestedAction: .none,
            actionParams: nil,
            promptVersion: mintResponse?.promptVersion ?? "",
            latencyMS: totalMs,
            retryCount: 0,
        )

        // Persist VoiceTurn rows (user + model). Transcript unknown on
        // Live path — empty strings are fine per schema. turnIndex is
        // 1-indexed across the session's lifetime.
        let userIdx = voiceTurnRepository.nextTurnIndex(for: cookingSession)
        try? voiceTurnRepository.persist(.init(
            session: cookingSession,
            speaker: .user,
            turnIndex: userIdx,
            transcriptText: "",
            inputMode: .voice,
            latencyMs: 0,
            resultType: .normal,
        ))
        try? voiceTurnRepository.persist(.init(
            session: cookingSession,
            speaker: .model,
            turnIndex: userIdx + 1,
            transcriptText: currentTurnInlineText ?? "",
            inputMode: .voice,
            latencyMs: totalMs,
            resultType: .normal,
        ))

        stateMachine.advance(to: .ready)
        return CookTurnResult(
            transcript: "",
            response: response,
            sttLatencyMs: 0,
            backendLatencyMs: totalMs,
        )
    }

    // MARK: - speak (no-op on Live)

    /// No-op on the Live path: the model's audio was already streamed
    /// out during endTurn and played through AVAudioPlayerNode. Present
    /// only to satisfy VoiceSessionDriver — C.3 needs it because the
    /// fallback dispatches text then synthesizes after.
    func speak(_ text: String) async {
        // Intentionally empty. `text` is logged at debug so Sentry
        // triage can confirm VM called through, but nothing plays.
        Logger.voice.debug("live_speak_noop text_len=\(text.count, privacy: .public)")
    }

    // MARK: - cancelSpeaking

    func cancelSpeaking() async {
        #if DEBUG
        // Distinguish user-barge-in (this path) from natural
        // end-of-turn (.modelSpeaking → .ready via turnComplete).
        // Both produce the same state transition in the transcript,
        // but only the former carries this tag.
        VoiceSessionLog.log("user.interrupted", ["state": stateMachine.state.rawValue])
        #endif
        audioPipeline?.cancelPlayback()
        // If we were mid-modelSpeaking, snap back to ready so the next
        // beginTurn doesn't hit the state guard. Legal transition per
        // VoiceSessionStateMachine (.modelSpeaking → .ready).
        if stateMachine.state == .modelSpeaking {
            stateMachine.advance(to: .ready)
        }
    }

    // MARK: - close

    func close() {
        #if DEBUG
        VoiceSessionLog.log("close.begin", ["turn_count": turnCount])
        #endif
        // Drain pending continuations BEFORE cancelling tasks — if we
        // cancel `receiveDispatcherTask` first, its `handleTransportError`
        // path (the normal drain site) never fires, and any caller
        // suspended on `awaitSetupComplete` / `awaitTurnComplete` is
        // stranded. On dealloc that becomes a "continuation was not
        // resumed" concurrency runtime crash. Nil-clear before resume so
        // a racing happy-path resolve can't double-resume.
        if let cont = setupCompleteContinuation {
            setupCompleteContinuation = nil
            cont.resume(throwing: RealtimeSessionError.notOpen)
        }
        if let cont = turnCompleteContinuation {
            turnCompleteContinuation = nil
            cont.resume(throwing: RealtimeSessionError.notOpen)
        }
        receiveDispatcherTask?.cancel()
        receiveDispatcherTask = nil
        micForwardTask?.cancel()
        micForwardTask = nil
        transport?.close()
        transport = nil
        audioPipeline?.tearDown()
        audioPipeline = nil
        // AVAudioSession deactivation is the VM's responsibility (see
        // CookModeViewModel.exit). Removed from close() to keep the
        // audio-session lifecycle owned in one place — parity with
        // SpeechFallbackService.close().
        if stateMachine.state != .closed {
            stateMachine.forceClose()
        }
        #if DEBUG
        VoiceSessionLog.sessionEnd()
        #endif
    }

    // MARK: - Session refresh (scaffold only — D.1 gates timer wiring)

    /// Mint a new token, open a new WebSocket, and close the old one
    /// after the new one emits setupComplete. Used at the 10-min /
    /// 15-turn boundary to avoid Gemini's 30-min hard session cap.
    ///
    /// NOT wired to a timer yet — D.1 validation gate will measure
    /// whether the silent-handoff budget holds before productionizing
    /// this path. Current call site: the receive dispatcher on a goAway
    /// frame, which is a defensive opportunistic refresh.
    func refreshSession() async {
        // TODO(D.1): implement full handoff. For now, log that a
        // refresh was requested so we can observe frequency + causes
        // during validation runs.
        Logger.voice.info(
            "live_session_refresh_requested turn=\(self.turnCount, privacy: .public) TODO=D.1",
        )
    }

    /// Send a sessionUpdate frame to prune context to the last N turns
    /// after a step advance. Scaffolded — NOT wired to the VM's
    /// step-advance callback yet. CLAUDE.md #7 says this is mandatory
    /// at scale; the deferral is deliberate so D.1 has baseline data
    /// on unpruned token growth.
    func pruneAfterStepAdvance(keepLastN: Int = 3) async {
        // TODO(D.1): wire from CookModeViewModel.nextStep(advancedBy:)
        // once we've measured unpruned growth and have a baseline to
        // compare pruning-on vs pruning-off.
        Logger.voice.info(
            "live_session_prune_requested keepLastN=\(keepLastN, privacy: .public) TODO=D.1",
        )
    }

    // MARK: - Private: mint + setup

    private func buildMintRequest() throws -> RealtimeSessionRequest {
        guard let sessionID = cookingSession.id else {
            throw RealtimeSessionError.mintFailed(message: "cooking session has no id")
        }
        guard let recipePlan = cookingSession.recipePlan,
              let recipePlanID = recipePlan.id
        else {
            throw RealtimeSessionError.mintFailed(message: "cooking session has no recipe_plan")
        }
        let steps = recipePlan.stepArray
        let currentIndex = Int(cookingSession.currentStepIndex)
        let currentStep = steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
        let currentStepNumber = currentIndex + 1

        let recipeContext = RealtimeRecipeContext(
            title: recipePlan.title ?? "",
            servings: Int(recipePlan.servings),
            estimatedMinutes: Int(recipePlan.estimatedMinutes),
            totalSteps: steps.count,
            currentStepText: currentStep?.instructionText ?? "",
            currentStepTimerSeconds: currentStep.flatMap {
                $0.timerSeconds > 0 ? Int($0.timerSeconds) : nil
            },
            remainingIngredients: recipePlan.ingredientArray.map { ing in
                .init(displayName: ing.displayName ?? "", canonicalSlug: ing.canonicalIngredientSlug)
            },
        )
        let householdContext = buildHouseholdContext()

        return RealtimeSessionRequest(
            clientRequestID: UUID(),
            cookingSessionID: sessionID,
            recipePlanID: recipePlanID,
            currentStepNumber: max(1, currentStepNumber),
            recipeContext: recipeContext,
            householdContext: householdContext,
        )
    }

    private func buildHouseholdContext() -> RealtimeHouseholdContext {
        guard let household = cookingSession.household else {
            return RealtimeHouseholdContext(
                dietaryRules: [],
                availableEquipment: [],
                pantrySnapshot: [],
            )
        }
        // Mirror CookModeViewModel.buildRealtimeHouseholdContext — same
        // property names, same filters, so the two call paths produce
        // identical context bodies to the backend.
        let rules = (household.dietaryRules as? Set<DietaryRule>)?.map {
            DinnerSolveRequest.DietaryRuleLite(
                kind: $0.kind ?? "",
                value: $0.value ?? "",
                severity: $0.severity ?? "soft",
            )
        } ?? []
        let equipment = (household.kitchenEquipment as? Set<KitchenEquipment>)?
            .filter { $0.isAvailable }
            .compactMap { $0.code } ?? []
        let pantry = (household.pantryItems as? Set<PantryItem>)?
            .filter { $0.deletedAt == nil && $0.userConfirmed }
            .map {
                RealtimeHouseholdContext.PantrySnapshotItem(
                    displayName: $0.displayName ?? "",
                    canonicalSlug: $0.canonicalIngredientSlug,
                )
            } ?? []
        return RealtimeHouseholdContext(
            dietaryRules: rules,
            availableEquipment: equipment,
            pantrySnapshot: pantry,
        )
    }

    // MARK: - Private: inbound dispatch

    private func startReceiveDispatcher() {
        guard let transport else { return }
        receiveDispatcherTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await frame in transport.inbound {
                    await self.handleInboundFrame(frame)
                }
            } catch {
                Logger.voice.warning(
                    "live_receive_dispatcher_failed error=\(error.localizedDescription, privacy: .private)",
                )
                await self.handleTransportError(error)
            }
        }
    }

    private var setupCompleteContinuation: CheckedContinuation<Void, Error>?

    /// Await the server's `setupComplete` handshake frame. Returns when
    /// `handleInboundFrame` resumes the continuation; throws
    /// `RealtimeSessionError.setupTimeout` if the budget elapses first.
    ///
    /// Implementation note: earlier drafts used a TaskGroup with one
    /// task blocking on the continuation and another on a timer.
    /// `TaskGroup.cancelAll()` does NOT propagate into a
    /// `withCheckedThrowingContinuation` — the continuation never
    /// resumed and leaked. This version resolves the continuation
    /// explicitly from the timeout path, so neither side leaks.
    private func awaitSetupComplete(timeoutSec: Double) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setupCompleteContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSec))
                guard let self, let pending = self.setupCompleteContinuation else { return }
                self.setupCompleteContinuation = nil
                pending.resume(throwing: RealtimeSessionError.setupTimeout)
            }
        }
    }

    /// Await the server's `turnComplete` frame. Mirrors `awaitSetupComplete`'s
    /// timeout pattern so a stalled server (no close, no `turnComplete`)
    /// can't hang the mic forever. Budget comes from `LiveSessionBudget`
    /// so it's tunable alongside the other Live-path budgets after D.1.
    /// On timeout, the caller's `endTurn` throws `.turnDrained`, the VM
    /// surfaces a toast, and state is recoverable by tapping again.
    private func awaitTurnComplete(
        timeoutSec: Double = LiveSessionBudget.turnCompleteSec,
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.turnCompleteContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSec))
                guard let self, let pending = self.turnCompleteContinuation else { return }
                self.turnCompleteContinuation = nil
                pending.resume(throwing: RealtimeSessionError.turnDrained)
            }
        }
    }

    private func handleInboundFrame(_ frame: LiveInboundFrame) async {
        switch frame {
        case .setupComplete:
            // Nil-clear BEFORE resume so a re-entrant resume (shouldn't
            // happen, but defense-in-depth against Google sending two
            // setupComplete frames) doesn't double-resume.
            if let cont = setupCompleteContinuation {
                setupCompleteContinuation = nil
                cont.resume()
            }

        case let .serverContent(content):
            await handleServerContent(content)

        case let .toolCall(toolCall):
            await handleToolCall(toolCall)

        case let .usageMetadata(usage):
            lastUsageMetadata = usage
            #if DEBUG
            VoiceSessionLog.log("usage.metadata", [
                "prompt_tokens": usage.promptTokenCount,
                "response_tokens": usage.responseTokenCount,
                "total_tokens": usage.totalTokenCount,
            ])
            #endif

        case let .goAway(ms):
            Logger.voice.info(
                "live_session_go_away time_before_disconnect_ms=\(ms ?? -1, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("server.go_away", ["time_before_disconnect_ms": ms ?? -1])
            #endif
            await refreshSession()

        case .sessionResumption:
            #if DEBUG
            VoiceSessionLog.log("server.session_resumption_update")
            #endif
        case let .unknown(key):
            #if DEBUG
            VoiceSessionLog.log("server.unknown_frame", ["key": key])
            #endif
        }
    }

    private func handleServerContent(_ content: LiveServerContent) async {
        if !content.audioChunks.isEmpty {
            #if DEBUG
            VoiceSessionLog.log("audio.chunk", [
                "count": content.audioChunks.count,
                "state": stateMachine.state.rawValue,
            ])
            #endif
            // Audio can arrive either from the first post-thinking
            // response OR after a toolResponse round-trip (Gemini
            // auto-continues the turn, CLAUDE.md §sharp-edge #9). Both
            // `.thinking → .modelSpeaking` and `.toolCalling →
            // .modelSpeaking` are legal state-machine transitions.
            if stateMachine.state == .thinking || stateMachine.state == .toolCalling {
                stateMachine.advance(to: .modelSpeaking)
            }
            // Break on first failure — if `enqueuePlayback` throws,
            // the audio engine is stopped and every subsequent chunk
            // in this frame will fail the same way. One log per failed
            // turn is sufficient for triage; absent the break, a
            // failed turn would log ~50 warnings.
            for chunk in content.audioChunks {
                do {
                    try audioPipeline?.enqueuePlayback(chunk)
                } catch {
                    Logger.voice.warning(
                        "live_playback_enqueue_failed error=\(error.localizedDescription, privacy: .private)",
                    )
                    break
                }
            }
        }
        if let text = content.inlineText, !text.isEmpty {
            currentTurnInlineText = (currentTurnInlineText ?? "") + text
        }
        if content.turnComplete {
            // Guard against `.thinking → .ready` illegal transition:
            // Gemini can emit `turnComplete` with no preceding audio
            // (text-only response or bare completion signal). Without
            // this, `handleServerContent` leaves state in `.thinking`
            // and endTurn's subsequent `advance(to: .ready)` crashes
            // in debug builds / stucks state in release. Advance
            // through `.modelSpeaking` first so the .ready transition
            // is always legal.
            if stateMachine.state == .thinking {
                stateMachine.advance(to: .modelSpeaking)
            }
            // The playback may still be queued — we resume the
            // continuation immediately so the VM can react; audio
            // continues playing in the background. The VM calls
            // cancelSpeaking / next tap to interrupt if needed.
            //
            // Nil-clear before resume so a re-entrant turnComplete
            // (e.g., server emits one on audio end and another on
            // toolCall completion) doesn't double-resume.
            if let cont = turnCompleteContinuation {
                turnCompleteContinuation = nil
                cont.resume()
            }
        }
    }

    private func handleToolCall(_ toolCall: LiveToolCall) async {
        // Guard: only `.thinking → .toolCalling` is legal per the state
        // machine. A stale or duplicate toolCall frame arriving when
        // state is `.ready`, `.userSpeaking`, or `.modelSpeaking` would
        // silently no-op the advance in release and then send a spurious
        // `toolResponse` that poisons the session protocol.
        //
        // We can't salvage the session in that case (Gemini's state has
        // drifted from ours), so fail the pending turn continuation fast
        // rather than letting `awaitTurnComplete`'s 30s timeout absorb
        // it. The VM surfaces a toast and the user can retry.
        guard stateMachine.state == .thinking else {
            Logger.voice.warning(
                "live_tool_call_in_unexpected_state state=\(self.stateMachine.state.rawValue, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("tool_call.dropped_bad_state", [
                "state": stateMachine.state.rawValue,
                "calls": toolCall.functionCalls.map(\.name).joined(separator: ","),
            ])
            #endif
            if let cont = turnCompleteContinuation {
                turnCompleteContinuation = nil
                cont.resume(throwing: RealtimeSessionError.turnDrained)
            }
            return
        }
        stateMachine.advance(to: .toolCalling)
        #if DEBUG
        VoiceSessionLog.log("tool_call.received", [
            "calls": toolCall.functionCalls.map(\.name).joined(separator: ","),
        ])
        #endif

        // 3.1 Flash Live does synchronous tool calls — one in flight
        // at a time (CLAUDE.md §sharp-edge #12). So iterating the
        // (length-1) array in order is the right contract.
        for call in toolCall.functionCalls {
            let response = await dispatchTool(call)
            let frame = LiveOutboundFrame.toolResponse(
                functionResponseId: call.id,
                name: call.name,
                response: response,
            )
            do {
                try await transport?.send(frame)
                #if DEBUG
                VoiceSessionLog.log("tool_response.sent", ["name": call.name])
                #endif
            } catch {
                Logger.voice.warning(
                    "live_tool_response_send_failed name=\(call.name, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
                )
                #if DEBUG
                VoiceSessionLog.logError("tool_response.send_failed", error: error, ["name": call.name])
                #endif
            }
        }

        // After toolResponse, state STAYS in `.toolCalling` until the
        // next serverContent audio frame arrives — the state machine's
        // legal transitions forbid `.toolCalling → .thinking` (only
        // `.toolCalling → .modelSpeaking` is allowed). When Gemini
        // resumes its spoken response (sharp-edge #9: auto-continue
        // after toolResponse), `handleServerContent` advances
        // `.toolCalling → .modelSpeaking` on the first audio chunk.
        // Removing a prior premature `.toolCalling → .thinking` hop
        // that would have hit an assertionFailure in debug builds.
    }

    private func dispatchTool(_ call: LiveFunctionCall) async -> [String: Any] {
        switch call.name {
        case "substitution_check":
            return await dispatchSubstitution(call)
        case "start_timer":
            if let secs = call.timerSeconds {
                onStartTimerRequested?(secs, call.timerLabel)
                return ["ok": true]
            }
            return ["ok": false, "error": "missing_seconds"]
        case "advance_step":
            onAdvanceStepRequested?()
            return ["ok": true]
        default:
            Logger.voice.warning("live_unknown_tool name=\(call.name, privacy: .public)")
            return ["ok": false, "error": "unknown_tool"]
        }
    }

    private func dispatchSubstitution(_ call: LiveFunctionCall) async -> [String: Any] {
        // Route through AIDispatch.substitution. Backend enforces the
        // hard-rule validator identically to the sheet path (single
        // source of truth per CLAUDE.md §north-star constraint #5).
        //
        // TODO(D.1): provide full substitution context (recipe,
        // household). For the scaffold we fail CLOSED — returning
        // `ok: false` prevents the model from rendering an
        // unvalidated substitution to the user. Once the full
        // dispatcher is wired (post-D.1), this returns the real
        // hard-rule-validated result from AIDispatch.substitution.
        Logger.voice.warning(
            "live_substitution_stub tool=\(call.name, privacy: .public) — returning fail-closed result",
        )
        #if DEBUG
        VoiceSessionLog.log("substitution.stub_hit", ["tool": call.name])
        #endif
        return [
            "ok": false,
            "error": "substitution_not_yet_supported",
            "message": "Use the Substitution Sheet for now.",
        ]
    }

    private func handleTransportError(_ error: any Error) async {
        #if DEBUG
        VoiceSessionLog.logError("transport.error", error: error, [
            "state": stateMachine.state.rawValue,
        ])
        #endif
        // Transport errored mid-session. Attempt refresh; if refresh
        // is a no-op (scaffold), degrade to error state so the VM
        // falls back to C.3.
        await refreshSession()
        if stateMachine.state != .closed {
            stateMachine.advance(to: .error)
        }
        // Nil-clear each continuation BEFORE resume so a concurrent
        // happy-path resolve (e.g., a setupComplete / turnComplete
        // frame racing the transport error) can't double-resume the
        // same CheckedContinuation — that's a crash.
        if let cont = turnCompleteContinuation {
            turnCompleteContinuation = nil
            cont.resume(throwing: error)
        }
        if let cont = setupCompleteContinuation {
            setupCompleteContinuation = nil
            cont.resume(throwing: error)
        }
    }

    // MARK: - Private: mic forwarding

    private func startMicForwarding() {
        guard let pipeline = audioPipeline, let transport else { return }
        // No self-capture: the Task reads from `pipeline` and
        // `transport` (captured strongly from locals), both of which
        // outlive the Task because this actor owns them and cancels
        // the task in `stopMicForwarding()` / `close()` before
        // teardown. Earlier drafts carried `[weak self]` + `_ = self`
        // to silence the unused-capture warning, which was misleading.
        micForwardTask = Task {
            for await frame in pipeline.micFrames {
                if Task.isCancelled { break }
                do {
                    try await transport.send(.realtimeInputAudio(
                        base64: frame.base64,
                        mimeType: frame.mimeType,
                    ))
                } catch {
                    Logger.voice.warning("live_mic_send_failed")
                    #if DEBUG
                    VoiceSessionLog.logError("mic.send_failed", error: error)
                    #endif
                    break
                }
            }
        }
    }

    private func stopMicForwarding() {
        micForwardTask?.cancel()
        micForwardTask = nil
    }
}
