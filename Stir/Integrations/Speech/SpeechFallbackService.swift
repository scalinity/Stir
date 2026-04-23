// SpeechFallbackService
//
// Cook Mode voice fallback path (C.3). Triggered when:
//   - Gemini Live is unavailable (server flag `disable_cook_realtime`)
//   - Live session fails to mint
//   - Live session drops mid-turn and reconnect fails (C.2 transition)
//
// Pipeline: SFSpeechRecognizer (on-device) → /v1/ai/cook-turn → AVSpeechSynthesizer.
//
// ADR 0007 pre-commits honored:
//   - Enhanced voice, NOT Premium (Premium requires download-on-demand
//     and fails silently when absent).
//   - Pre-warm STT + TTS on Cook Mode entry. Engagement <200 ms.
//   - `requiresOnDeviceRecognition = true` for privacy.
//   - Tap-to-speak — no barge-in. Barge-in is a Live-only UX.
//   - VoiceTurn rows persisted on both paths with inputMode='voice';
//     telemetry `path` property discriminates (`gemini_fallback` here).
//   - Shared AVAudioSession from AVAudioSessionConfigurator.
//   - Error paths: STT fail → inline toast; backend fail → AIDispatch
//     mapping; TTS fail → caller renders spoken_response as visible text.

import AVFoundation
import Foundation
import OSLog
import Speech

// MARK: - Public error type

enum SpeechFallbackError: Error, Equatable, Sendable {
    /// One of: SFSpeechRecognizer authorization denied, microphone
    /// permission denied. Distinguish via the associated `kind`.
    case permissionDenied(kind: PermissionKind)
    /// Device has no speech recognizer available (e.g. unsupported
    /// locale or no on-device model for this language).
    case recognizerUnavailable
    /// User ended the turn without saying anything the recognizer
    /// could hear. Inline toast copy.
    case emptyTranscript
    /// STT task itself errored mid-session (hardware fault, etc.).
    case transcriptionFailed(message: String)
    /// Synthesizer rejected the voice / went silent. Caller falls back
    /// to rendering `spoken_response` as visible text in the step card.
    case synthesisFailed(message: String)
    /// `beginTurn` was called while a prior turn is still in-flight
    /// (state is one of userSpeaking / transcribing / thinking /
    /// modelSpeaking). Caller should surface a toast rather than
    /// silently no-op — a silent reject looks like a dead mic button.
    /// Typed state (not String) so consumers can branch on the specific
    /// sub-state without rawValue parsing.
    case busy(state: VoiceSessionState)

    enum PermissionKind: String, Sendable, Equatable {
        case microphone
        case speechRecognition
    }
}

// MARK: - Result

/// The outcome of one round-trip fallback turn. Caller feeds the
/// `spoken_response` to AVSpeechSynthesizer via `speak(_:)`, and acts
/// on `suggestedAction` if any.
struct CookTurnResult: Sendable {
    let transcript: String
    let response: CookTurnResponse
    /// Milliseconds from turn-begin → transcript-final. Plumbed into
    /// the user VoiceTurn row and the `cook_turn_resolved` telemetry
    /// event's `latency_ttfa_ms`.
    let sttLatencyMs: Int
    /// Milliseconds from transcript-final → response-received. Pipeline's
    /// latency_total = sttLatencyMs + backendLatencyMs.
    let backendLatencyMs: Int
}

// MARK: - Service

@MainActor
@Observable
final class SpeechFallbackService: VoiceSessionDriver {
    /// Identifies this driver as the degraded / fallback path. Stamped
    /// on telemetry events by CookModeViewModel per spec §15.
    nonisolated let pathLabel: VoiceSessionPath = .geminiFallback

    // SCOPE NOTE — stuck-modelSpeaking watchdog is Live-only.
    //
    // The `turnStuckWatchdog` in `RealtimeSession.swift` catches the
    // Gemini Live protocol bug where `turnComplete` can go missing
    // after multi-pass tool-call turns (observed 2026-04-23, ADR
    // 0015). It does NOT apply here because:
    //
    //   1. The fallback path has no long-lived WebSocket — each turn
    //      is a discrete HTTP round-trip via `/v1/ai/cook-turn`, so
    //      there is no equivalent "dropped turnComplete frame" class
    //      of bug to guard against.
    //   2. The local AVSpeechSynthesizer reliably signals
    //      `didFinish` (see `SynthesisDelegate` below); if that
    //      delegate call is ever missed it's a local iOS issue, not
    //      a preview-API protocol bug.
    //   3. An 8-second threshold against AVSpeechSynthesizer playback
    //      (which routinely runs 10-25s for multi-sentence model
    //      responses at Stir's speaking rate) would false-positive
    //      mid-sentence, cutting the TTS off and advancing state
    //      before the user had a chance to hear the response.
    //
    // If the fallback path ever grows its own "model is producing
    // multi-stage output" behavior (e.g. streaming text responses
    // with server-sent events), revisit this note and design a
    // watchdog with an appropriate threshold. Until then, keep the
    // scope pinned to the Live driver.

    /// Stateless per-turn — cook-turn carries its own client_request_id
    /// per call; there is no session trace on the fallback path.
    var voiceSessionID: String? { nil }

    /// No session-level prompt on the fallback path — each cook-turn
    /// call carries its own prompt_version via the response DTO.
    var voiceSessionPromptVersion: String? { nil }

    // MARK: Dependencies

    private let aiDispatch: AIDispatch
    private let voiceTurnRepository: VoiceTurnRepository
    private let cookingSession: CookingSession

    // MARK: Published state

    /// The voice session's current state. UI observes this to render
    /// the mic button, waveform indicator, and thinking animation.
    /// Changes on every legal transition per VoiceSessionStateMachine.
    private(set) var currentState: VoiceSessionState = .idle

    // MARK: Private

    private let stateMachine = VoiceSessionStateMachine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private var synthesisDelegate: SynthesisDelegate?
    private var turnStartTime: Date?
    private var sttFinalTime: Date?
    private var currentTranscript: String = ""

    // Voice selection: Enhanced Samantha per ADR 0007. Loaded lazily on
    // pre-warm so the first speak() isn't blocked by a 200-400ms voice
    // lookup on device.
    // ASSUMPTION: Enhanced Samantha ships on every iOS 17+ device. If a
    // future user's device returns nil, we fall back to any en-US voice;
    // TTS still works, just with the default system voice.
    private var cachedVoice: AVSpeechSynthesisVoice?
    private static let preferredVoiceID = "com.apple.voice.enhanced.en-US.Samantha"

    /// P0-D (2026-04-23): observes AVAudioSession interruption /
    /// route-change / media-services-reset events. Fallback-path recovery
    /// is strictly "cancel + surface the AI-VOICE-01 banner" — unlike
    /// the Live path, we don't attempt any in-place refresh because
    /// SFSpeechRecognizer recognitionTask state after an interruption
    /// is undocumented and we'd rather degrade cleanly than half-work.
    private var audioInterruptionObserver: AudioInterruptionObserver?

    // MARK: Init

    init(
        aiDispatch: AIDispatch,
        voiceTurnRepository: VoiceTurnRepository,
        cookingSession: CookingSession,
    ) {
        self.aiDispatch = aiDispatch
        self.voiceTurnRepository = voiceTurnRepository
        self.cookingSession = cookingSession
        // en_US locale matches CLAUDE.md's English-only v1 scope. If the
        // system doesn't support the locale at all, `SFSpeechRecognizer(
        // locale:)` returns nil and preWarm() surfaces .recognizerUnavailable.
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        stateMachine.onTransition = { [weak self] _, next in
            self?.currentState = next
            // Chain to the VM's optional subscriber so the mic button
            // label stays in sync during internal state changes (e.g.
            // the state advances inside beginTurn/endTurn without the
            // VM being able to read currentState until those methods
            // return). Mirror of RealtimeSession's hook.
            self?.onVoiceStateChange?(next)
        }
    }

    /// See `RealtimeSession.onVoiceStateChange` — same contract. Set
    /// by CookModeRoot when wiring the driver; invoked on MainActor.
    var onVoiceStateChange: (@MainActor (VoiceSessionState) -> Void)?

    // MARK: - Pre-warm

    /// Eagerly load the STT recognizer + TTS voice so the first mic tap
    /// engages in <200 ms (ADR 0007 pre-commit). Call from Cook Mode
    /// entry on the main actor — NOT from the first mic tap.
    ///
    /// Does NOT request microphone permission (that's granted per-first-
    /// tap via the system primer). Does request speech-recognition
    /// authorization because that's a one-shot grant the user must have
    /// accepted before the first tap.
    ///
    /// Throws `.recognizerUnavailable` if the device can't run the
    /// recognizer at all (locale unsupported, etc.). Throws
    /// `.permissionDenied(.speechRecognition)` if the user has explicitly
    /// denied speech recognition authorization — caller should pivot to
    /// "tap Cook Mode still works" copy.
    func preWarm() async throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            // P2-H (2026-04-23): voice_fallback_* log prefix convention
            // so ops dashboards can filter fallback-path logs uniformly.
            Logger.voice.warning("voice_fallback_recognizer_unavailable_on_prewarm")
            throw SpeechFallbackError.recognizerUnavailable
        }
        // On-device recognition matches CLAUDE.md privacy invariant:
        // user audio never hits Apple's servers. Devices that can't
        // run on-device (pre-A12 / unsupported locale) return false
        // for `supportsOnDeviceRecognition` — we hard-fail rather
        // than silently upload.
        guard recognizer.supportsOnDeviceRecognition else {
            Logger.voice.warning("voice_fallback_no_on_device_support")
            throw SpeechFallbackError.recognizerUnavailable
        }

        // Request speech-recognition authorization. Only call the
        // one-shot primer if status is still `.notDetermined`. When
        // the user has already granted/denied, `authorizationStatus()`
        // returns the cached value synchronously — re-requesting just
        // re-fires the callback without re-showing the primer, but it
        // burns a turnaround on every Cook Mode entry / driver rebuild.
        // Review 2026-04-22 §Warning #2.
        let cached = SFSpeechRecognizer.authorizationStatus()
        let status: SFSpeechRecognizerAuthorizationStatus
        if cached == .notDetermined {
            status = await withCheckedContinuation {
                (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
            }
        } else {
            status = cached
        }
        switch status {
        case .authorized:
            break
        case .denied, .restricted:
            throw SpeechFallbackError.permissionDenied(kind: .speechRecognition)
        case .notDetermined:
            // System didn't present the primer — unusual but possible on
            // hardware restrictions. Treat as unavailable for this
            // session; caller falls to tap Cook Mode.
            throw SpeechFallbackError.recognizerUnavailable
        @unknown default:
            throw SpeechFallbackError.recognizerUnavailable
        }

        // Load the preferred voice synchronously. Nil return means
        // Enhanced Samantha isn't installed on this device — fall back
        // to any en-US voice (still works, just default quality).
        let voice = AVSpeechSynthesisVoice(identifier: Self.preferredVoiceID)
            ?? AVSpeechSynthesisVoice(language: "en-US")
        cachedVoice = voice
        Logger.voice.info(
            "voice_fallback_prewarm_ok voice=\(voice?.identifier ?? "nil", privacy: .public) on_device=true",
        )

        // Transition to `ready` — mic isn't hot yet, but the service is
        // prepared to begin a turn on the first tap.
        stateMachine.advance(to: .ready)

        // P0-D (2026-04-23): observe system audio events so phone calls
        // / Siri / AirPods-yanks tear down cleanly instead of silently
        // leaving the fallback service in a broken-mid-turn state. The
        // observer handler flips us to `.error` + surfaces AI-VOICE-01.
        audioInterruptionObserver?.stop()
        audioInterruptionObserver = AudioInterruptionObserver { [weak self] event in
            self?.handleAudioInterruption(event)
        }
        audioInterruptionObserver?.start()
    }

    /// React to system audio events. The fallback path's recovery is
    /// always "cancel + advance to .error" — SFSpeechRecognizer state
    /// after an interruption is not documented as safe to resume, and
    /// the user's next tap will re-initialize the whole path cleanly.
    private func handleAudioInterruption(_ event: AudioInterruptionObserver.Event) {
        Logger.voice.info(
            "voice_fallback_audio_interruption event=\(String(describing: event), privacy: .public)",
        )
        switch event {
        case .interruptionBegan, .routeOldDeviceUnavailable, .mediaServicesReset:
            // Cancel any in-flight recognition + speech. No-op if idle.
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            if synthesizer.isSpeaking {
                synthesizer.stopSpeaking(at: .immediate)
            }
            if stateMachine.state != .closed && stateMachine.state != .error {
                stateMachine.advance(to: .error)
            }
        case .interruptionEnded:
            // Fallback: user's next tap re-initializes via preWarm.
            break
        }
    }

    // MARK: - Turn lifecycle

    /// Begin listening. Call on mic-tap. Mic permission is requested
    /// lazily via AVAudioSession — the first call will surface the iOS
    /// system primer if not yet granted. Returns immediately after the
    /// audio tap is installed; the caller keeps the session alive and
    /// calls `endTurn()` when the user releases / taps again.
    ///
    /// Throws `.permissionDenied(.microphone)` if permission is denied.
    /// Throws `.recognizerUnavailable` if SFSpeechRecognizer hasn't been
    /// pre-warmed or is temporarily unavailable.
    func beginTurn() async throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw SpeechFallbackError.recognizerUnavailable
        }
        // Must be `.ready` — preWarm() is the only legal transition
        // `idle → ready`, so `.idle` here means preWarm never completed
        // (fail-closed cascade from the Live path, or recognizer/mic
        // permission denial). Without this guard, the subsequent
        // `stateMachine.advance(to: .userSpeaking)` tries the illegal
        // `idle → userSpeaking` transition and trips the DEBUG-only
        // assertionFailure — a cascade we hit 2026-04-20 after Live
        // setupTimeout pushed us onto a C.3 driver whose preWarm also
        // failed.
        guard currentState == .ready else {
            // Active-turn states (userSpeaking / transcribing /
            // thinking / modelSpeaking) are "busy" — the user tapped
            // faster than we can drain. Anything else (idle / error /
            // closed) is recognizerUnavailable — the driver isn't
            // primed and won't be without a full session restart.
            switch currentState {
            case .userSpeaking, .transcribing, .thinking, .modelSpeaking:
                Logger.voice.warning(
                    "voice_fallback_begin_turn_while_active state=\(self.currentState.rawValue, privacy: .public)",
                )
                throw SpeechFallbackError.busy(state: currentState)
            default:
                Logger.voice.warning(
                    "voice_fallback_begin_turn_before_ready state=\(self.currentState.rawValue, privacy: .public)",
                )
                throw SpeechFallbackError.recognizerUnavailable
            }
        }

        // Mic permission primer (first-tap only).
        let micGranted = await requestMicrophonePermission()
        guard micGranted else {
            throw SpeechFallbackError.permissionDenied(kind: .microphone)
        }

        // Build a fresh recognition request + task. SFSpeechRecognizer
        // requires one per utterance — reusing mid-session causes
        // "Recognition request failed" errors.
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request
        self.currentTranscript = ""
        self.turnStartTime = Date()
        self.sttFinalTime = nil

        // Install mic tap. inputFormat gives us the device's native mic
        // format (usually 48 kHz); SFSpeechRecognizer handles its own
        // internal resampling. We don't need 16 kHz PCM16 here — that's
        // for Gemini Live (C.2) only.
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        // Guard: an in-flight prior session could still have a tap
        // installed. Remove before installing a new one.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SpeechFallbackError.transcriptionFailed(
                message: "Audio engine failed to start: \(error.localizedDescription)",
            )
        }

        // Start the recognition task. Partial results accumulate into
        // `currentTranscript` via the closure; endTurn() reads it.
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.currentTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.sttFinalTime = Date()
                    }
                }
                if let error {
                    Logger.voice.warning(
                        "voice_fallback_stt_error: \(error.localizedDescription, privacy: .public)",
                    )
                }
            }
        }

        stateMachine.advance(to: .userSpeaking)
    }

    /// End the turn: stop listening, send transcript to backend, return
    /// the result. Caller is expected to call `speak(response.spoken_response)`
    /// immediately after. This method handles VoiceTurn persistence for
    /// BOTH the user and model rows.
    ///
    /// Throws:
    ///   - `.emptyTranscript` — user released without saying anything.
    ///   - `StirError.*` — backend failures (NET-01 / AI-01 / AUTH-01
    ///     / RATE-01 / ENT-VOICE-01). Presenter layer maps to user copy.
    func endTurn(
        recipeContext: RealtimeRecipeContext,
        householdContext: RealtimeHouseholdContext,
        currentStepNumber: Int,
        recipePlanId: UUID,
    ) async throws -> CookTurnResult {
        // Tear down the audio engine + recognition task immediately so
        // the mic indicator drops.
        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.finish()

        let transcript = currentTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let sttLatencyMs: Int = {
            guard let start = turnStartTime, let final = sttFinalTime else { return 0 }
            return Int(final.timeIntervalSince(start) * 1000)
        }()
        self.recognitionRequest = nil
        self.recognitionTask = nil

        guard !transcript.isEmpty else {
            stateMachine.advance(to: .ready)
            throw SpeechFallbackError.emptyTranscript
        }

        // Persist user VoiceTurn now — before the backend call — so a
        // backend failure doesn't orphan the transcript. Spec §4.12:
        // every user turn writes a row on BOTH paths. If the persist
        // throws we log it explicitly AND skip the matching model row
        // so Core Data / ops-replay never sees a "model turn with no
        // user turn" orphan (review 2026-04-22 §Critical #5). Earlier
        // `try?`-swallowed failures could create that orphan.
        let userTurnIndex = voiceTurnRepository.nextTurnIndex(for: cookingSession)
        var userRowPersisted = true
        do {
            try voiceTurnRepository.persist(.init(
                session: cookingSession,
                speaker: .user,
                turnIndex: userTurnIndex,
                transcriptText: transcript,
                inputMode: .voice,
                latencyMs: sttLatencyMs,
                resultType: .normal,
            ))
        } catch {
            userRowPersisted = false
            Logger.voice.error(
                "voice_fallback_user_turn_persist_failed error=\(error.localizedDescription, privacy: .public)",
            )
        }

        stateMachine.advance(to: .thinking)

        // Backend call.
        let backendStart = Date()
        let body = CookTurnRequest(
            clientRequestID: UUID(),
            cookingSessionID: cookingSession.id ?? UUID(),
            recipePlanID: recipePlanId,
            currentStepNumber: currentStepNumber,
            transcript: String(transcript.prefix(500)),
            recipeContext: recipeContext,
            householdContext: householdContext,
        )

        let response: CookTurnResponse
        do {
            response = try await aiDispatch.cookTurn(request: body)
        } catch {
            // Persist an error VoiceTurn for the model side so ops can
            // replay exactly where the session died — BUT only if the
            // user row is in. Skipping when user persist failed avoids
            // an orphan model row with no matching user turn.
            if userRowPersisted {
                do {
                    try voiceTurnRepository.persist(.init(
                        session: cookingSession,
                        speaker: .model,
                        turnIndex: userTurnIndex + 1,
                        transcriptText: "",
                        inputMode: .voice,
                        latencyMs: Int(Date().timeIntervalSince(backendStart) * 1000),
                        resultType: .error,
                    ))
                } catch {
                    Logger.voice.error(
                        "voice_fallback_error_turn_persist_failed error=\(error.localizedDescription, privacy: .public)",
                    )
                }
            }
            stateMachine.advance(to: .error)
            throw error
        }

        let backendLatencyMs = Int(Date().timeIntervalSince(backendStart) * 1000)

        // Compute resultType once: .normal when the model gave a
        // pure conversational answer, .toolCall when it emitted a
        // suggested action. Persisted on the model VoiceTurn row AND
        // gates the voiceEnabled flip below.
        let modelResultType: VoiceTurn.ResultType =
            response.suggestedAction == .none ? .normal : .toolCall

        // Persist model VoiceTurn — same orphan-avoidance guard.
        if userRowPersisted {
            do {
                try voiceTurnRepository.persist(.init(
                    session: cookingSession,
                    speaker: .model,
                    turnIndex: userTurnIndex + 1,
                    transcriptText: response.spokenResponse,
                    inputMode: .voice,
                    latencyMs: backendLatencyMs,
                    resultType: modelResultType,
                ))
            } catch {
                Logger.voice.error(
                    "voice_fallback_model_turn_persist_failed error=\(error.localizedDescription, privacy: .public)",
                )
            }
        }

        stateMachine.advance(to: .modelSpeaking)

        // Set CookingSession.voiceEnabled on the first model VoiceTurn
        // with resultType='normal' (ADR 0007 pre-commit). Gated
        // explicitly (not on mic tap and not on tool_call turns): voice
        // was "successfully used" only after a clean conversational
        // response. Error turns + tool_call turns are legal but
        // shouldn't flip the flag — an all-tool-call session could
        // legitimately hide real voice errors otherwise.
        //
        // Idempotent: second+ normal turns no-op the check.
        if modelResultType == .normal && cookingSession.voiceEnabled == false {
            cookingSession.voiceEnabled = true
            try? cookingSession.managedObjectContext?.save()
        }

        return CookTurnResult(
            transcript: transcript,
            response: response,
            sttLatencyMs: sttLatencyMs,
            backendLatencyMs: backendLatencyMs,
        )
    }

    // MARK: - Speak

    /// Render the given text via AVSpeechSynthesizer. Resolves when the
    /// utterance is fully spoken or on synthesizer failure. On failure
    /// the caller renders the text as visible copy (ADR 0007 pre-commit).
    func speak(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        if let voice = cachedVoice { utterance.voice = voice }
        // Rate tuning: .defaultSpeechRate is slightly slow for a
        // kitchen-assistant tone. 1.05× pulls toward casual pace
        // without over-enunciating.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.05

        // P0-H (2026-04-23): single-resume latch + bounded timeout.
        // AVSpeechSynthesizer can silently no-op if the voice install is
        // corrupt or the audio session is in a weird interruption state
        // — didFinish never fires and the prior continuation hung
        // forever, pinning the session in `.modelSpeaking`. 10s covers
        // the p95 tail for ~25-30 token responses (~8s at default rate
        // + postUtteranceDelay); anything longer than that means the
        // synthesizer is broken and we should recover rather than wait.
        //
        // Re-entrancy: if a prior `speak()` call stranded a continuation
        // because its delegate was overwritten, this run's
        // `self.synthesisDelegate = delegate` would lose the reference.
        // The new delegate's closure guards single-resume via the
        // `hasResumed` box so even if both fire, the continuation
        // resumes exactly once. Preserving the prior delegate's
        // resume semantics via explicit drain before overwrite.
        final class ResumeLatch: @unchecked Sendable {
            private var resumed = false
            private let lock = NSLock()
            func tryResume() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let latch = ResumeLatch()

        // `speak()` is called serially from `endTurn`'s await chain,
        // so `self.synthesisDelegate` is nil on entry under normal
        // flow. The latch + timeout below are the backstops against
        // synthesizer misbehavior (no-ops, silent failures) rather
        // than against re-entrancy, which the call-site ordering
        // already prevents.

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Retain the delegate as a stored prop so it outlives the
            // closure scope — AVSpeechSynthesizer weakly references
            // its delegate, and the delegate needs to survive until
            // didFinish fires.
            let delegate = SynthesisDelegate { [weak self] in
                guard latch.tryResume() else { return }
                Task { @MainActor [weak self] in
                    self?.synthesisDelegate = nil
                    cont.resume()
                    if self?.stateMachine.state == .modelSpeaking {
                        self?.stateMachine.advance(to: .ready)
                    }
                }
            }
            self.synthesisDelegate = delegate
            self.synthesizer.delegate = delegate
            self.synthesizer.speak(utterance)

            // Timeout guard. 10s ceiling; resumes the continuation once
            // via the shared latch so both paths (delegate-fires-first
            // vs timeout-fires-first) are race-safe.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard latch.tryResume() else { return }
                Logger.ui.warning("voice_fallback_synthesizer_timeout — didFinish never fired after 10s")
                self?.synthesisDelegate = nil
                cont.resume()
                if self?.stateMachine.state == .modelSpeaking {
                    self?.stateMachine.advance(to: .ready)
                }
            }
        }
    }

    /// Cancel any in-flight speech. Awaits the state-machine transition
    /// back to `.ready` before returning so a caller that immediately
    /// invokes `beginTurn()` won't hit the `.busy` guard from the race
    /// between `stopSpeaking(at: .immediate)` (which returns before the
    /// delegate's `didCancel` callback fires) and our state-machine
    /// update.
    ///
    /// Bounded wait (~500 ms max) so a stuck synthesizer can't deadlock
    /// the mic tap — if the cap is reached we return anyway and let
    /// `beginTurn` throw `.busy`, which the VM already handles.
    func cancelSpeaking() async {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        // Poll the state machine until it settles. 50 × 10ms = 500ms cap.
        // In practice the delegate fires within one runloop tick.
        for _ in 0..<50 {
            if stateMachine.state != .modelSpeaking { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Teardown

    /// Stop all audio, cancel tasks, advance to `.closed`. Idempotent.
    /// Call from Cook Mode exit regardless of current state.
    func close() {
        // Drop the external VM subscriber first so any final
        // `forceClose()` transition below doesn't fire a callback
        // into a VM that's mid-dismissal.
        onVoiceStateChange = nil

        // Teardown audio side BEFORE the state-machine transition so a
        // bad engine state can't leave the session in limbo. Each of
        // these is a no-op if the corresponding resource was never
        // acquired (the close() contract is "idempotent; call from any
        // state"). Wrap the audio-engine teardown in `isRunning`
        // guards because `audioEngine.inputNode.removeTap(onBus:)`
        // raises an ObjC exception in the simulator when no tap was
        // ever installed — which is the exact state a
        // constructed-but-never-used service lands in (observed via
        // SpeechFallbackServiceTests `test_close_fromIdle` where the
        // raise short-circuited forceClose and left currentState .idle).
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        // P0-D (2026-04-23): stop AVAudioSession observers so no late
        // notification fires callbacks into a torn-down service.
        audioInterruptionObserver?.stop()
        audioInterruptionObserver = nil

        // Transition the state machine. The mirror closure set in init
        // writes `self.currentState = .closed` synchronously. Belt-and-
        // suspenders: set currentState directly too, so any future
        // refactor of the mirror (or a test that pre-sets onTransition
        // to nil) doesn't silently leave currentState stale.
        if stateMachine.state != .closed {
            stateMachine.forceClose()
        }
        currentState = .closed

        // Drop the internal mirror closure AFTER forceClose so the
        // state update propagated to `currentState`. Any further
        // state writes (none expected post-close) are inert.
        stateMachine.onTransition = nil
    }

    // MARK: - Private

    private func requestMicrophonePermission() async -> Bool {
        // iOS 17+ uses AVAudioApplication.requestRecordPermission(completionHandler:)
        // in production code. The older AVAudioSession.requestRecordPermission
        // is deprecated but still functional — using the new API keeps
        // us on the supported path as iOS 18/26 evolve.
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

// MARK: - Synthesis delegate

/// Minimal AVSpeechSynthesizerDelegate that resolves a continuation
/// when the utterance finishes. Bundled here so SpeechFallbackService
/// doesn't have to expose delegate-shaped public API.
@MainActor
private final class SynthesisDelegate: NSObject, AVSpeechSynthesizerDelegate {
    private let onComplete: () -> Void
    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onComplete() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onComplete() }
    }
}
