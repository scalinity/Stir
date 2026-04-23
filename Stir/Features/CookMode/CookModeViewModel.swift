// CookModeViewModel
//
// Drives the Cook Mode flow for a single CookingSession:
//   enter  → StepCardView on step N
//   Next   → step N+1, persist advance, fire cook_step_advanced
//   Prev   → step N-1, persist advance
//   Timer  → TimerService.start/pause/resume/cancel
//   Ask    → (raise navigation to SubstitutionSheet — handled by root)
//   Mic    → voice cook turn via VoiceSessionDriver
//             Free: paywall trigger (voiceAffordanceTapped)
//             Premium+: preWarm → beginTurn → endTurn → speak
//   Finish → markCompleted, navigate to OutcomeFeedback
//   Exit   → confirm + CLEANUP (driver.close, AVAudioSession deactivate)
//
// Step 6 (C.4) wires VoiceSessionDriver. The mic button is visible on
// ALL tiers — tap-behavior branches by entitlement:
//   Free       → paywall + voice_affordance_tapped(result=paywall_shown)
//   Premium/Pro → voice session starts +         (result=voice_started)
//   Permission denied →                           (result=permission_denied)
//
// C.2's Gemini Live RealtimeSession will conform to VoiceSessionDriver
// and plug in without changes here (ADR 0007).

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CookModeViewModel {
    // MARK: - State

    let session: CookingSession
    let recipePlan: RecipePlan
    let household: HouseholdProfile
    private let startedAtWallClock: Date

    /// 0-based index into `steps`. Persisted to CookingSession on every
    /// change so cross-device resume sees the same step.
    private(set) var currentStepIndex: Int

    private(set) var activeTimers: [CookTimer] = []

    /// Present-substitution flag — observed by the view to push the sheet.
    var substitutionPresentationRequested: Bool = false

    /// Present-finish flag — observed by the view to push OutcomeFeedback.
    var finishPresentationRequested: Bool = false

    /// Exit confirm flag.
    var exitConfirmRequested: Bool = false

    /// Set to true by `exit(markAbandoned:)` when the user chose either
    /// "Pause and resume later" or "Abandon". The root observes this and
    /// dismisses the fullScreenCover. Staying distinct from
    /// `exitConfirmRequested` matters because the confirmation dialog
    /// auto-flips that one back to false on ANY button tap (including
    /// "Keep cooking"), which would otherwise incorrectly dismiss.
    var shouldDismiss: Bool = false

    // MARK: - Voice session state

    /// Live state of the voice session driver (when present). Views
    /// observe this to render the mic button + waveform + thinking
    /// affordance. `nil` when no driver has been set (e.g. permission
    /// denied or disable_cook_realtime at session start).
    ///
    /// Only the VM itself mutates this in production. The DEBUG-only
    /// `_testForceVoiceState(_:)` hook lets integration tests simulate
    /// mid-session states (e.g., tap-while-thinking) without having to
    /// drive a full turn through the mock to reach them.
    private(set) var voiceState: VoiceSessionState? = nil

    /// Transient inline toast — set by voice failures (empty transcript,
    /// net error, permission denied). View binds + clears on tap.
    var voiceToastMessage: String?

    /// UX-level role the mic button plays right now. The view binds
    /// this single property instead of computing its own enabled /
    /// tinting / labeling logic from raw state bits. Changes only via
    /// voiceState mutations, so SwiftUI diffing stays predictable.
    var micButtonRole: MicButtonRole {
        switch voiceState {
        case nil, .idle, .ready, .error, .closed:
            return .askWithVoice
        case .userSpeaking:
            return .submit
        case .transcribing, .thinking, .modelSpeaking:
            return .busy
        case .connecting, .toolCalling, .refreshing, .fallingBack:
            // C.2-only states. Treated as "busy" for the C.3 UX until
            // the Live path lands. Distinct labels can be added later.
            return .busy
        }
    }

    /// What the mic button is showing right now. Drives icon, label,
    /// color, and enabled-state in StepCardView.
    enum MicButtonRole: Equatable, Sendable {
        /// Default — tap begins a new turn.
        case askWithVoice
        /// Listening — tap submits the turn.
        case submit
        /// Backend/TTS in flight — disabled, showing spinner.
        case busy
    }

    /// Legacy convenience — kept so existing tests don't have to update.
    /// Prefer `micButtonRole` in view code.
    var voiceIsListening: Bool { micButtonRole == .submit }
    var voiceIsBusy: Bool { micButtonRole == .busy }

    // MARK: - Deps

    private let cookingSessionRepository: CookingSessionRepository
    private let cookTimerRepository: CookTimerRepository
    private let timerService: TimerService
    private let liveActivityManager: LiveActivityManager
    private let analytics: PostHogClient
    private let sentry: any SentryReporting
    private let entitlements: EntitlementService?
    /// Injected by the root on entry. nil for Free users who would hit
    /// the paywall anyway. When non-nil, CookModeViewModel has already
    /// called `preWarm()` on it. May be cleared mid-session if an
    /// unrecoverable invariant violation (e.g., nil recipe_plan_id)
    /// forces teardown; subsequent taps then route through the
    /// "no driver" path and show "Voice isn't available" rather than
    /// loop on the same error.
    private var voiceDriver: (any VoiceSessionDriver)?
    /// Captured at entry so mid-session flag flips don't confuse the
    /// driver-selection logic. Read by callers that want to explain
    /// WHY a specific driver was chosen; the driver itself was already
    /// picked by the root.
    let disableCookRealtimeAtEntry: Bool
    /// Closure the root passes in to present the paywall. Avoids
    /// leaking RootCoordinator into the view model's imports.
    private let presentPaywall: ((PaywallTrigger) -> Void)? = nil
    /// Closure the root passes in AFTER VM construction so the VM can
    /// ask for a fresh voice driver when the user reopens voice mode
    /// after a `closeVoiceSession()` teardown. Without this, the user
    /// would see "Voice isn't available on this device" on every
    /// re-tap post-close because the driver had been nilled — observed
    /// 2026-04-22. The root runs the same preWarm logic it used at
    /// Cook Mode entry and then calls `attachVoiceDriver(_:)` to wire
    /// the new instance back into the VM. Nil in tests that stub
    /// `voiceDriver` directly — driver rebuild isn't exercised there.
    var onRequestNewVoiceSession: (@MainActor () async -> Void)? = nil

    // MARK: - Init

    init(
        session: CookingSession,
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        source: EntrySource,
        cookingSessionRepository: CookingSessionRepository? = nil,
        cookTimerRepository: CookTimerRepository? = nil,
        timerService: TimerService? = nil,
        liveActivityManager: LiveActivityManager? = nil,
        analytics: PostHogClient = .shared,
        sentry: (any SentryReporting)? = nil,
        entitlements: EntitlementService? = nil,
        voiceDriver: (any VoiceSessionDriver)? = nil,
        disableCookRealtime: Bool = false,
        presentPaywall: ((PaywallTrigger) -> Void)? = nil,
    ) {
        self.session = session
        self.recipePlan = recipePlan
        self.household = household
        self.currentStepIndex = Int(session.currentStepIndex)
        self.startedAtWallClock = Date()
        self.cookingSessionRepository = cookingSessionRepository ?? CookingSessionRepository()
        self.cookTimerRepository = cookTimerRepository ?? CookTimerRepository()
        self.timerService = timerService ?? TimerService()
        self.liveActivityManager = liveActivityManager ?? LiveActivityManager()
        self.analytics = analytics
        self.sentry = sentry ?? SentryReporter.shared
        self.entitlements = entitlements
        self.voiceDriver = voiceDriver
        self.disableCookRealtimeAtEntry = disableCookRealtime
        self.presentPaywall = presentPaywall
        if let voiceDriver {
            self.voiceState = voiceDriver.currentState
        }

        // Emit cook_mode_started. `voice_enabled` reflects the Core
        // Data column, not the tier — it flips to true only after the
        // first successful normal VoiceTurn (ADR 0007). So for brand-
        // new sessions it's false even on Premium, which is intended.
        let within3Min: Bool = {
            guard let started = session.startedAt else { return false }
            return Date().timeIntervalSince(started) <= 3 * 60
        }()
        analytics.capture(.cookModeStarted, properties: [
            "source": source.rawValue,
            "voice_enabled": session.voiceEnabled,
            "within_3min": within3Min,
            "recipe_plan_id": recipePlan.id?.uuidString ?? "",
        ])
    }

    /// Where Cook Mode entered from (surfaced to telemetry). Spec §15 uses
    /// the same shape for scan-derived vs saved-derived starts.
    enum EntrySource: String, Sendable {
        case solve
        case saved
        case imported
        case leftovers
    }

    // MARK: - Derived

    var steps: [RecipeStep] { recipePlan.stepArray }
    var totalSteps: Int { steps.count }
    var currentStep: RecipeStep? {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }
    var isFirstStep: Bool { currentStepIndex <= 0 }
    // Guard totalSteps == 0: without it, the `>= totalSteps - 1` check
    // evaluates `>= -1` which is always true, so an empty recipe would
    // immediately enter the finish flow on any Next tap (CA1 finding).
    var isLastStep: Bool { totalSteps > 0 && currentStepIndex >= totalSteps - 1 }

    // MARK: - Navigation

    /// Advance one step.
    ///
    /// `advancedBy` → telemetry key `manual_or_voice` on the
    /// `cook_step_advanced` event (spec §15). The param name reflects
    /// the intent ("what advanced the step"); the telemetry key is a
    /// wire-format contract with PostHog dashboards and can't change
    /// without breaking downstream queries. Passing `"manual"` covers
    /// Prev/Next button taps; `"voice"` is used by voice endVoiceTurn.
    func nextStep(advancedBy: String = "manual") {
        // Empty recipe → nowhere to go. Don't advance, don't present
        // OutcomeFeedback for a session that never had a step.
        guard totalSteps > 0 else { return }
        guard !isLastStep else {
            finishPresentationRequested = true
            return
        }
        let newIndex = currentStepIndex + 1
        do {
            try cookingSessionRepository.advanceStep(session, to: newIndex)
            currentStepIndex = newIndex
            analytics.capture(.cookStepAdvanced, properties: [
                "step_index": newIndex,
                "manual_or_voice": advancedBy,
            ])
        } catch {
            Logger.ui.error("cook mode advanceStep failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func previousStep() {
        guard !isFirstStep else { return }
        let newIndex = currentStepIndex - 1
        do {
            try cookingSessionRepository.advanceStep(session, to: newIndex)
            currentStepIndex = newIndex
            analytics.capture(.cookStepAdvanced, properties: [
                "step_index": newIndex,
                "manual_or_voice": "manual",
            ])
        } catch {
            Logger.ui.error("cook mode previousStep failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func jumpToStep(_ index: Int) {
        // Guard totalSteps == 0 to avoid `min(-1, index)` producing a
        // negative upper bound (CA1 finding). With no steps there's
        // nowhere to jump.
        guard totalSteps > 0 else { return }
        let clamped = max(0, min(totalSteps - 1, index))
        guard clamped != currentStepIndex else { return }
        do {
            try cookingSessionRepository.advanceStep(session, to: clamped)
            currentStepIndex = clamped
        } catch {
            Logger.ui.error("cook mode jumpToStep failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Timer coordination

    /// Create + start a timer for the current step using its recorded
    /// timerSeconds. Idempotent — if the current step already has a
    /// running timer, do nothing.
    func startTimerForCurrentStep(generated: Bool = true) async {
        guard let step = currentStep else { return }
        let secs = Int(step.timerSeconds)
        guard secs > 0 else { return }

        // Skip if a running timer for this step already exists.
        if activeTimers.contains(where: { $0.step?.id == step.id && $0.typedState == .running }) {
            return
        }

        do {
            let label = (step.title?.isEmpty == false ? step.title! : "Step \(step.stepNumber)") + " timer"
            let timer = try cookTimerRepository.createTimer(
                for: session,
                step: step,
                label: label,
                durationSec: secs,
            )
            await timerService.requestAuthorizationIfNeeded()
            try await timerService.start(timer, on: session)
            startLiveActivity(for: timer, step: step)
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1

            analytics.capture(.timerStarted, properties: [
                "duration_bucket": bucketForDuration(secs),
                "generated_vs_manual": generated ? "generated" : "manual",
                "step_number": Int(step.stepNumber),
            ])
        } catch {
            Logger.ui.error("cook mode startTimer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Voice-driven timer start. The Live `start_timer` tool call
    /// passes an explicit `seconds` argument — this method honors it
    /// (as distinct from `startTimerForCurrentStep` which always reads
    /// the configured step duration). Use for the C.2 path; the C.3
    /// path's `start_timer` suggested_action continues to call
    /// `startTimerForCurrentStep` because the fallback cook-turn
    /// response doesn't carry a seconds arg today.
    ///
    /// Seconds are already clamped to 1...14400 by `LiveFunctionCall.timerSeconds`;
    /// the guard here is defensive.
    func startTimerFromVoice(seconds: Int, label: String?) async {
        guard let step = currentStep else { return }
        guard (1...14400).contains(seconds) else { return }
        // Skip if a running timer for this step already exists.
        if activeTimers.contains(where: { $0.step?.id == step.id && $0.typedState == .running }) {
            return
        }
        do {
            let resolvedLabel = label?.isEmpty == false
                ? label!
                : (step.title?.isEmpty == false ? step.title! : "Step \(step.stepNumber)") + " timer"
            let timer = try cookTimerRepository.createTimer(
                for: session,
                step: step,
                label: resolvedLabel,
                durationSec: seconds,
            )
            await timerService.requestAuthorizationIfNeeded()
            try await timerService.start(timer, on: session)
            startLiveActivity(for: timer, step: step)
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1

            analytics.capture(.timerStarted, properties: [
                "duration_bucket": bucketForDuration(seconds),
                "generated_vs_manual": "voice",
                "step_number": Int(step.stepNumber),
            ])
        } catch {
            Logger.ui.error("cook mode startTimerFromVoice failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func pauseTimer(_ timer: CookTimer) async {
        do {
            // Capture paused-remaining BEFORE the state flip — once
            // typedState == .paused, remainingSeconds returns 0 (the
            // computed prop gates on .running). The Live Activity needs
            // the time-left at the pause moment for the static display.
            let pausedRemaining = pausedRemainingSecondsSnapshot(for: timer)
            try await timerService.pause(timer, on: session)
            if let tid = timer.id, let fire = timer.fireDate {
                await liveActivityManager.update(
                    timerId: tid,
                    fireDate: fire,
                    pausedRemainingSec: pausedRemaining,
                )
            }
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1
        } catch {
            Logger.ui.error("pause failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resumeTimer(_ timer: CookTimer) async {
        do {
            try await timerService.resume(timer, on: session)
            // `fireDate` has shifted forward by the paused duration after
            // resume (TimerService only shifts `startedAt` on resume). Refresh the
            // activity with the new fireDate and clear the paused flag.
            if let tid = timer.id, let fire = timer.fireDate {
                await liveActivityManager.update(
                    timerId: tid,
                    fireDate: fire,
                    pausedRemainingSec: nil,
                )
            }
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1
        } catch {
            Logger.ui.error("resume failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelTimer(_ timer: CookTimer) async {
        do {
            try await timerService.cancel(timer, on: session)
            if let tid = timer.id {
                await liveActivityManager.end(timerId: tid, reason: .cancelled)
            }
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1
        } catch {
            Logger.ui.error("cancel timer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Call on foreground or Cook Mode re-entry. Natural-completion
    /// timers whose fire date passed while backgrounded get marked
    /// completed.
    func reconcileTimersOnForeground() async {
        do {
            let transitioned = try await timerService.reconcileOnForeground(session: session)
            for timer in transitioned {
                if let tid = timer.id {
                    await liveActivityManager.end(timerId: tid, reason: .completed)
                }
            }
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1
        } catch {
            Logger.ui.error("timer reconcile failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sheet hooks

    func requestSubstitution() {
        substitutionPresentationRequested = true
    }

    func requestExitConfirm() {
        // If nothing's started (no timers running, step 0), exit cleanly.
        // Mark abandoned so the session doesn't linger as a "Resume
        // cooking" ghost — the user never actually started cooking.
        // Without this, every ProgressView → immediate back-tap left an
        // active session that permanently populated the Resume banner.
        let hasRunningTimers = activeTimers.contains { $0.typedState == .running }
        if currentStepIndex == 0 && !hasRunningTimers {
            Task { await self.exit(markAbandoned: true) }
            return
        }
        exitConfirmRequested = true
    }

    /// User confirmed exit. If `markAbandoned`, transition the session
    /// state; otherwise leave it active so Tonight Home's Resume card
    /// can pick it up. Either way, `shouldDismiss` flips true so the
    /// root dismisses the cover.
    ///
    /// Cancel running timers INLINE before flipping `shouldDismiss` —
    /// dispatching a detached Task here races with the root's onChange
    /// dismissal, which can tear the VM down before the cancellation
    /// runs. A dangling `UNNotificationRequest` then fires minutes
    /// later for an abandoned session (CA2-R1).
    ///
    /// Voice cleanup (ADR 0007 pre-commit): close the driver + write
    /// endedAt so the AVAudioSession deactivates before the VM tears
    /// down. Leaked audio session = system mic indicator stays on
    /// after exit.
    func exit(markAbandoned: Bool) async {
        if markAbandoned {
            do {
                try cookingSessionRepository.markAbandoned(session)
            } catch {
                Logger.ui.error("markAbandoned failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for timer in activeTimers where timer.typedState == .running {
            do {
                try await timerService.cancel(timer, on: session)
                if let tid = timer.id {
                    await liveActivityManager.end(timerId: tid, reason: .cancelled)
                }
            } catch {
                Logger.ui.error("exit cancelTimer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Voice teardown — idempotent. cancelSpeaking is now async and
        // waits for the state machine to settle; close() then tears
        // down the recognizer + synthesizer; AVAudioSession is
        // deactivated last so the system mic indicator drops. Runs on
        // BOTH pause and abandon paths — kitchen UX cares more about
        // the mic indicator going dark than about any pause/abandon
        // semantics.
        await voiceDriver?.cancelSpeaking()
        voiceDriver?.close()
        AVAudioSessionConfigurator.deactivate()
        // endedAt writes ONLY on abandon — pause-and-resume-later must
        // leave endedAt nil so Tonight Home's Resume banner still picks
        // up the session on the next app open. markAbandoned() in the
        // repository sets endedAt + status=abandoned atomically, so
        // the abandon branch's endedAt is already written above.
        shouldDismiss = true
    }

    // MARK: - Completion

    /// User tapped Finish on the last step. Marks completed, computes
    /// duration, fires cook_session_completed, and raises the outcome
    /// feedback flag so the root can present the sheet.
    func finish() {
        do {
            try cookingSessionRepository.markCompleted(session)
        } catch {
            Logger.ui.error("markCompleted failed: \(error.localizedDescription, privacy: .public)")
        }
        let durationMinutes = Int(Date().timeIntervalSince(startedAtWallClock) / 60)
        analytics.capture(.cookSessionCompleted, properties: [
            "duration_min": max(0, durationMinutes),
            "steps_completed": totalSteps == 0 ? 0 : currentStepIndex + 1,
            "voice_enabled": session.voiceEnabled,
            "recipe_plan_id": recipePlan.id?.uuidString ?? "",
        ])
        finishPresentationRequested = true
    }

    // MARK: - Voice session

    /// User tapped the mic button. Branches by entitlement per
    /// spec §15 `voice_affordance_tapped` result values:
    ///   Free               → paywall, result=paywall_shown
    ///   Premium/Pro        → begin/end turn, result=voice_started
    ///   Permission denied  → inline toast, result=permission_denied
    ///
    /// Telemetry fires at the tap site (not deferred to C.5) per
    /// Daniel's pre-commit: per-action events instrument at the action.
    func handleMicTap() async {
        let tier = entitlements?.tier ?? .free

        // Free / entitlement gate — paywall.
        let decision = entitlements?.canAccess(.voiceCookMode) ?? .blockedByTier(required: .premium)
        switch decision {
        case .allowed:
            break
        case .blockedByTier, .blockedByBilling:
            emitVoiceAffordance(tier: tier, result: "paywall_shown")
            presentPaywall?(.voiceAffordanceTapped)
            return
        case .blockedByQuota:
            // Premium+ who's hit the monthly voice cap — Pro-upsell
            // paywall, not the generic trial one.
            emitVoiceAffordance(tier: tier, result: "paywall_shown")
            presentPaywall?(.voiceCookQuotaExhausted)
            return
        }

        // Premium+ path. Hands-free model: VAD drives turn boundaries,
        // so the user never NEEDS to tap mid-session. Taps during an
        // active session have TWO meanings depending on state:
        //
        //   .userSpeaking / .transcribing → "I'm done, submit this turn"
        //       — backward compat for explicit-submit UX and the
        //         tap-only fallback flow (C.3 without VAD).
        //   any other active state        → "Stop voice mode entirely"
        //       — prevents the trap Daniel hit 2026-04-22 where the
        //         mic button was `.disabled` during .busy states, so
        //         tapping it during .thinking/.modelSpeaking did
        //         nothing visible and the user was stuck.
        if let driver = voiceDriver, isActiveVoiceState(driver.currentState) {
            switch driver.currentState {
            case .userSpeaking, .transcribing:
                // Flip VM voiceState to .thinking BEFORE awaiting so
                // the button stops reading as .submit for the full
                // 30s endTurn wait (observed spam-tap scenario
                // 2026-04-22). Driver also advances internally.
                voiceState = .thinking
                await endVoiceTurn()
                return
            default:
                // .connecting, .ready, .thinking, .modelSpeaking,
                // .toolCalling, .refreshing, .fallingBack — tap
                // closes the session.
                await closeVoiceSession()
                emitVoiceAffordance(tier: tier, result: "voice_stopped")
                return
            }
        }

        // Idle / post-close path — user wants to (re)start voice.
        //
        // If we have no driver (either Cook Mode preWarm never
        // succeeded OR the user just closed a prior session via
        // closeVoiceSession() which nulls the reference), ask the
        // root for a fresh one before we try to begin a turn. Without
        // this, every "Ask with voice" tap after a close throws
        // .recognizerUnavailable and surfaces "Voice isn't available
        // on this device" — the exact trap observed 2026-04-22.
        //
        // The root's closure does the same driver-selection logic
        // .task runs at Cook Mode entry (killSwitch → C.3, Premium+
        // Live → preWarm → fallback). When it returns, either
        // voiceDriver is populated (via attachVoiceDriver) or the
        // driver build genuinely failed, in which case
        // beginVoiceTurnInner below surfaces recognizerUnavailable
        // as the legitimate outcome.
        if voiceDriver == nil, let rebuild = onRequestNewVoiceSession {
            await rebuild()
        }

        // Begin listening. Emit the success telemetry after
        // beginTurn() actually starts; on failure, map the typed
        // error to copy + emit permission_denied OR forward to the
        // server-error presentation path.
        do {
            try await beginVoiceTurnInner()
            emitVoiceAffordance(tier: tier, result: "voice_started")
        } catch SpeechFallbackError.permissionDenied {
            emitVoiceAffordance(tier: tier, result: "permission_denied")
            showVoiceError(
                message: "Microphone access is off. You can keep cooking with taps, or turn on the mic in Settings.",
                errorCode: "PERM-MIC-01",
                screen: "cook_mode_voice_begin",
            )
        } catch SpeechFallbackError.recognizerUnavailable {
            emitVoiceAffordance(tier: tier, result: "permission_denied")
            showVoiceError(
                message: "Voice isn't available on this device.",
                errorCode: "PERM-MIC-01",
                screen: "cook_mode_voice_begin",
            )
        } catch SpeechFallbackError.busy {
            // Should be rare after the cancel-await above. If it still
            // happens, the driver is wedged in a state we didn't expect
            // — surface a soft recovery hint.
            showVoiceError(
                message: "Voice is still catching up. Try again.",
                errorCode: "AI-03",
                screen: "cook_mode_voice_begin",
            )
        } catch {
            // Typed-error mapping for backend failures on preWarm()
            // retries (rare for C.3 — most pre-warm failures surface
            // at Cook Mode entry, not mic tap). Route StirError via
            // the presenter so copy is consistent with the rest of
            // the app.
            let presented = presentStirError(error, screen: "cook_mode_voice_begin")
            if !presented {
                Logger.ui.error("voice begin failed: \(error.localizedDescription, privacy: .public)")
                showVoiceError(
                    message: "Voice didn't start. Try again.",
                    errorCode: "NET-01",
                    screen: "cook_mode_voice_begin",
                )
            }
        }
    }

    private func beginVoiceTurnInner() async throws {
        guard let voiceDriver else {
            // This happens when the driver failed to initialize (kill
            // switch flipped mid-session, or CookModeRoot never got to
            // preWarm). Treat as recognizerUnavailable UX-wise.
            throw SpeechFallbackError.recognizerUnavailable
        }
        try await voiceDriver.beginTurn()
        voiceState = voiceDriver.currentState
    }

    /// Driver-to-VM state mirror. Called from CookModeRoot's
    /// `onVoiceStateChange` wiring on every state-machine advance so
    /// the mic button label tracks hands-free VAD-driven transitions
    /// (userSpeaking → modelSpeaking → ready etc.) that happen
    /// without any VM method call.
    func applyDriverStateChange(_ state: VoiceSessionState) {
        voiceState = state
    }

    /// External setter used by CookModeRoot's rebuild closure.
    /// voiceDriver is `private` so the root can't assign directly;
    /// this method is the only external mutation point. Also sync
    /// voiceState to the new driver's current state so the button
    /// label reflects reality immediately.
    func attachVoiceDriver(_ driver: (any VoiceSessionDriver)?) {
        self.voiceDriver = driver
        if let driver {
            self.voiceState = driver.currentState
        } else {
            self.voiceState = .closed
        }
    }

    /// States in which a voice session is "live" — mic is hot, WS is
    /// connected, or work is in flight. The ONLY state that is not
    /// live is the pre/post-session ones (`.idle` before preWarm,
    /// `.closed` / `.error` after teardown).
    private func isActiveVoiceState(_ state: VoiceSessionState) -> Bool {
        switch state {
        case .idle, .closed, .error:
            return false
        case .connecting, .ready, .userSpeaking, .transcribing,
             .thinking, .modelSpeaking, .toolCalling, .refreshing,
             .fallingBack:
            return true
        }
    }

    /// Tear down the voice session entirely and drop back to tap
    /// cooking. Called when the user taps the mic button during an
    /// active session — the hands-free contract says VAD drives
    /// turn boundaries, so any user-initiated button tap is a
    /// session-level action, not a turn-level one.
    ///
    /// Idempotent: safe to call with no active driver (guard early).
    /// The mic button's `handleMicTap` is the only caller for now;
    /// CookModeRoot's `.onDisappear` uses driver.close() directly
    /// because it doesn't care about the VM-side state cleanup.
    private func closeVoiceSession() async {
        guard let driver = voiceDriver else { return }
        // Cancel any in-flight playback synchronously — gives
        // immediate audible feedback that the stop registered even
        // before the WS tears down.
        await driver.cancelSpeaking()
        // Driver close: WS disconnect, mic tap removal, audio engine
        // stop, continuations drained. Idempotent within the driver.
        driver.close()
        voiceDriver = nil
        voiceState = .closed
        // Deactivate the AVAudioSession we activated for Cook Mode so
        // other apps can take the audio stack. CookModeRoot's
        // .onDisappear also calls deactivate; this is defense in
        // depth for the "exit voice but stay in Cook Mode" path.
        AVAudioSessionConfigurator.deactivate()
        Logger.ui.info("voice_session_closed_by_user_tap")
    }

    private func endVoiceTurn() async {
        guard let voiceDriver else { return }
        // recipePlan.id should never be nil on an active session (Core
        // Data + step-3 repository creation always stamps it). If it
        // ever IS nil, surface a toast + screen_error_shown + Sentry
        // breadcrumb rather than silently dropping the turn — a silent
        // drop orphans the transcript and leaves the user tapping.
        guard let recipePlanId = recipePlan.id else {
            Logger.ui.error("endVoiceTurn: recipePlan.id is nil — unrecoverable")
            sentry.captureError(
                StirError.validation(
                    fieldErrors: [FieldError(field: "recipe_plan.id", issue: "nil on active cook session")],
                    message: "endVoiceTurn recipePlan.id nil",
                ),
                context: ["cooking_session_id": session.id?.uuidString ?? ""],
            )
            showVoiceError(
                message: "Voice turn failed. Try again or tap through.",
                errorCode: "VAL-01",
                screen: "cook_mode_voice_end",
            )
            // Recover from the "dead mic loop": without this teardown,
            // the driver stays in `.userSpeaking` waiting for an
            // endTurn that'll never come. `voiceIsListening` stays
            // true and every subsequent tap re-enters endVoiceTurn →
            // re-hits this guard → re-emits screen_error_shown, and
            // the user is stuck tapping a dead mic.
            //
            // Force-close stops recognition / TTS / AVAudioSession and
            // moves state to `.closed`. Dropping the reference routes
            // the next tap through beginVoiceTurnInner's "no driver"
            // path (surfaces "Voice isn't available on this device")
            // — a clean dead end that keeps tap-only Cook Mode usable.
            voiceDriver.close()
            self.voiceDriver = nil
            voiceState = .closed
            return
        }

        let recipeCtx = buildRealtimeRecipeContext()
        let householdCtx = buildRealtimeHouseholdContext()

        let submittedAt = Date()
        analytics.capture(.cookTurnSubmitted, properties: [
            "turn_type": "voice",
            "current_step_index": currentStepIndex,
            "path": voiceDriver.pathLabel.rawValue,
        ])

        do {
            let result = try await voiceDriver.endTurn(
                recipeContext: recipeCtx,
                householdContext: householdCtx,
                currentStepNumber: currentStepIndex + 1,
                recipePlanId: recipePlanId,
            )
            voiceState = voiceDriver.currentState

            let totalMs = Int(Date().timeIntervalSince(submittedAt) * 1000)
            analytics.capture(.cookTurnResolved, properties: [
                "latency_ttfa_ms": result.sttLatencyMs,
                "latency_total_ms": totalMs,
                "barge_in": false,
                "helpful_vote": "",
                "path": voiceDriver.pathLabel.rawValue,
            ])

            // Speak the response. The driver updates the state machine
            // as modelSpeaking → ready so the mic button re-enables.
            await voiceDriver.speak(result.response.spokenResponse)
            voiceState = voiceDriver.currentState

            // Act on suggested_action. `advancedBy: "voice"` is the
            // spec §15 discrimination — product dashboards need to
            // tell manual vs voice-driven step advances apart.
            switch result.response.suggestedAction {
            case .advanceStep:
                nextStep(advancedBy: "voice")
            case .startTimer:
                // The current step's own timer takes precedence; if
                // the model wants a custom timer we'd need a dedicated
                // CookTimer creation path. For v1 we honor the action
                // by starting the step's own timer only if the step
                // has one configured.
                await startTimerForCurrentStep(generated: true)
            case .none:
                break
            }
        } catch SpeechFallbackError.emptyTranscript {
            voiceToastMessage = "I didn't catch that. Tap again and try once more."
            voiceState = voiceDriver.currentState
        } catch {
            voiceState = voiceDriver.currentState
            let presented = presentStirError(error, screen: "cook_mode_voice_end")
            if !presented {
                Logger.ui.error("voice endTurn failed: \(error.localizedDescription, privacy: .public)")
                showVoiceError(
                    message: "Voice turn failed. Try again or tap through.",
                    errorCode: "NET-01",
                    screen: "cook_mode_voice_end",
                )
            }
        }
    }

    // MARK: - Voice error presentation

    /// Map typed StirErrors to the appropriate UX (toast + optional
    /// paywall hand-off) so voice errors land consistently with the
    /// rest of the app instead of getting swallowed by a generic catch.
    /// Returns true if the error was handled; false if the caller
    /// should fall through to a generic toast.
    private func presentStirError(_ error: any Error, screen: String) -> Bool {
        guard let stirError = error as? StirError else { return false }
        // Breadcrumb every typed error for Sentry — voice failures are
        // otherwise hard to triage from user reports alone.
        //
        // Privacy: `message` is strictly the error CODE (never
        // `String(describing: stirError)`, which walks the enum mirror
        // and would pull in user-entered recipe/substitution text via
        // associated values). Full error payload is still captured
        // when `sentry.captureError(...)` fires on an unhandled path.
        let code = stirError.presentableCode.rawValue
        sentry.breadcrumb(
            category: "voice",
            message: code,
            data: ["screen": screen, "code": code],
        )
        switch stirError {
        case .rateLimited:
            // User hit voice_cook_session monthly cap — Pro-upsell path.
            emitVoiceAffordance(tier: entitlements?.tier ?? .free, result: "paywall_shown")
            presentPaywall?(.voiceCookQuotaExhausted)
            return true
        case .entitlementRequired(let code, _) where code == .entVoice01:
            // Entitlement slipped mid-session (RC webhook lag, grace
            // period expired during a running cook). Route to upgrade
            // paywall rather than a generic toast.
            presentPaywall?(.voiceAffordanceTapped)
            return true
        case .server(let code, _, _) where code == .aiVoice01:
            showVoiceError(
                message: "Voice mode is unavailable right now. Tap Cook Mode still works.",
                errorCode: code.rawValue,
                screen: screen,
            )
            return true
        case .server(let code, _, _) where code == .ai01 || code == .ai03:
            showVoiceError(
                message: "Voice is taking a moment. Try again shortly.",
                errorCode: code.rawValue,
                screen: screen,
            )
            return true
        case .networkUnreachable, .timeout:
            showVoiceError(
                message: "Couldn't reach Stir. Check your connection and try again.",
                errorCode: "NET-01",
                screen: screen,
            )
            return true
        default:
            // AUTH-01, VAL-01, unknown — let the caller fall back to
            // the generic toast + logger.error path.
            return false
        }
    }

    /// Set the inline toast + fire spec §15 `screen_error_shown` so
    /// voice errors are queryable in PostHog alongside other UX errors.
    private func showVoiceError(message: String, errorCode: String, screen: String) {
        voiceToastMessage = message
        analytics.capture(.screenErrorShown, properties: [
            "screen_name": screen,
            "error_code": errorCode,
        ])
    }

    /// Build the recipe context shape the backend expects. Snapshot of
    /// the current step + total steps + remaining ingredients.
    private func buildRealtimeRecipeContext() -> RealtimeRecipeContext {
        let step = currentStep
        let remaining = recipePlan.ingredientArray.map {
            RealtimeRecipeContext.RemainingIngredient(
                displayName: $0.displayName ?? "",
                canonicalSlug: $0.canonicalIngredientSlug,
            )
        }
        return RealtimeRecipeContext(
            title: recipePlan.title ?? "",
            servings: Int(recipePlan.servings),
            estimatedMinutes: Int(recipePlan.estimatedMinutes),
            totalSteps: totalSteps,
            currentStepText: step?.instructionText ?? "",
            // 0 when no timer on this step. DTO is non-Optional because
            // backend requires the key to be present — see
            // RealtimeRecipeContext.currentStepTimerSeconds doc comment.
            currentStepTimerSeconds: Int(step?.timerSeconds ?? 0),
            remainingIngredients: remaining,
        )
    }

    private func buildRealtimeHouseholdContext() -> RealtimeHouseholdContext {
        let dietaryRules = (household.dietaryRules as? Set<DietaryRule>)?.map {
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
            dietaryRules: dietaryRules,
            availableEquipment: equipment,
            pantrySnapshot: pantry,
        )
    }

    private func emitVoiceAffordance(tier: Tier, result: String) {
        analytics.capture(.voiceAffordanceTapped, properties: [
            "tier": tier.rawValue,
            "result": result,
        ])
    }

    // MARK: - Private

    private func bucketForDuration(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: return "under_1m"
        case ..<300: return "1_5m"
        case ..<900: return "5_15m"
        case ..<1800: return "15_30m"
        default: return "over_30m"
        }
    }

    /// Start a Live Activity for a freshly-started CookTimer. Pulls the
    /// static attributes from the recipe plan + step metadata; the manager
    /// is responsible for handling "activities disabled" and "already
    /// active for this timerId" gracefully (both no-op). No-ops on
    /// timers without an id (shouldn't happen in practice — repos always
    /// assign `UUID()` at creation — but defensive).
    private func startLiveActivity(for timer: CookTimer, step: RecipeStep) {
        guard let tid = timer.id, let fire = timer.fireDate else { return }
        let title = recipePlan.title?.isEmpty == false ? recipePlan.title! : "Your recipe"
        let description: String = {
            if let t = step.title, !t.isEmpty { return t }
            if let body = step.instructionText, !body.isEmpty {
                // First-sentence trim so the Lock Screen doesn't wrap a
                // 4-line step.
                let firstStop = body.firstIndex(where: { $0 == "." }) ?? body.endIndex
                return String(body[..<firstStop])
            }
            return "Step \(step.stepNumber)"
        }()
        liveActivityManager.start(
            timerId: tid,
            recipeTitle: title,
            stepDescription: description,
            stepNumber: Int(step.stepNumber),
            totalSteps: totalSteps,
            fireDate: fire,
        )
    }

    /// Compute remaining seconds at the moment of pause. `fireDate` is
    /// stable across the pause transition (TimerService only shifts
    /// `startedAt` on resume), so `fireDate.timeIntervalSinceNow`
    /// captures the instant-of-pause delta regardless of whether the
    /// caller invokes this before or after `timerService.pause(_:)`.
    private func pausedRemainingSecondsSnapshot(for timer: CookTimer) -> Int {
        guard let fire = timer.fireDate else { return 0 }
        return max(0, Int(fire.timeIntervalSinceNow.rounded()))
    }

    #if DEBUG
    /// Test-only hook for simulating mid-session voice states without
    /// having to drive a full turn through the mock driver. Production
    /// code must never call this — the DEBUG gate ensures release
    /// builds can't accidentally bypass the state machine.
    func _testForceVoiceState(_ state: VoiceSessionState?) {
        voiceState = state
    }
    #endif
}
