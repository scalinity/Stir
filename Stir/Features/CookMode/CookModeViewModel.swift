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
    private(set) var voiceState: VoiceSessionState? = nil

    /// Transient inline toast — set by voice failures (empty transcript,
    /// net error, permission denied). View binds + clears on tap.
    var voiceToastMessage: String?

    /// Whether the voice session is in a state where a mic tap starts
    /// a new turn (as opposed to ending one). Derived from voiceState.
    var voiceIsIdle: Bool {
        voiceState == nil || voiceState == .idle || voiceState == .ready
            || voiceState == .error
    }

    /// Whether we're mid-user-turn — a second mic tap submits.
    var voiceIsListening: Bool { voiceState == .userSpeaking }

    /// Whether a backend call or TTS is in flight. Mic is disabled.
    var voiceIsBusy: Bool {
        voiceState == .transcribing || voiceState == .thinking
            || voiceState == .modelSpeaking
    }

    // MARK: - Deps

    private let cookingSessionRepository: CookingSessionRepository
    private let cookTimerRepository: CookTimerRepository
    private let timerService: TimerService
    private let analytics: PostHogClient
    private let entitlements: EntitlementService?
    /// Injected by the root on entry. nil for Free users who would hit
    /// the paywall anyway. When non-nil, CookModeViewModel has already
    /// called `preWarm()` on it.
    private var voiceDriver: (any VoiceSessionDriver)?
    /// Captured at entry so mid-session flag flips don't confuse the
    /// driver-selection logic. Read by callers that want to explain
    /// WHY a specific driver was chosen; the driver itself was already
    /// picked by the root.
    let disableCookRealtimeAtEntry: Bool
    /// Closure the root passes in to present the paywall. Avoids
    /// leaking RootCoordinator into the view model's imports.
    private let presentPaywall: ((PaywallTrigger) -> Void)?

    // MARK: - Init

    init(
        session: CookingSession,
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        source: EntrySource,
        cookingSessionRepository: CookingSessionRepository? = nil,
        cookTimerRepository: CookTimerRepository? = nil,
        timerService: TimerService? = nil,
        analytics: PostHogClient = .shared,
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
        self.analytics = analytics
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

    func nextStep() {
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
                "manual_or_voice": "manual",
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
            activeTimers = cookTimerRepository.timers(for: session)

            analytics.capture(.timerStarted, properties: [
                "duration_bucket": bucketForDuration(secs),
                "generated_vs_manual": generated ? "generated" : "manual",
                "step_number": Int(step.stepNumber),
            ])
        } catch {
            Logger.ui.error("cook mode startTimer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func pauseTimer(_ timer: CookTimer) async {
        do {
            try await timerService.pause(timer, on: session)
            activeTimers = cookTimerRepository.timers(for: session)
        } catch {
            Logger.ui.error("pause failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resumeTimer(_ timer: CookTimer) async {
        do {
            try await timerService.resume(timer, on: session)
            activeTimers = cookTimerRepository.timers(for: session)
        } catch {
            Logger.ui.error("resume failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelTimer(_ timer: CookTimer) async {
        do {
            try await timerService.cancel(timer, on: session)
            activeTimers = cookTimerRepository.timers(for: session)
        } catch {
            Logger.ui.error("cancel timer failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Call on foreground or Cook Mode re-entry. Natural-completion
    /// timers whose fire date passed while backgrounded get marked
    /// completed.
    func reconcileTimersOnForeground() async {
        do {
            _ = try await timerService.reconcileOnForeground(session: session)
            activeTimers = cookTimerRepository.timers(for: session)
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
            } catch {
                Logger.ui.error("exit cancelTimer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Voice teardown — idempotent. Close the driver FIRST so
        // cancelSpeaking/recognitionTask stop before the audio session
        // deactivates. Runs on BOTH paths so the system mic indicator
        // drops regardless of whether the user paused or abandoned.
        voiceDriver?.cancelSpeaking()
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
        case .blockedByTier, .blockedByBilling, .blockedByQuota:
            emitVoiceAffordance(tier: tier, result: "paywall_shown")
            presentPaywall?(.voiceAffordanceTapped)
            return
        }

        // Premium+ path. State-branch on what the current turn is doing.
        if voiceIsListening {
            // Second tap → end the turn and dispatch.
            await endVoiceTurn()
            return
        }
        if voiceIsBusy {
            // Mid-turn (backend in flight or model speaking). A tap
            // while modelSpeaking cancels + starts a new turn; a tap
            // while thinking does nothing (request can't be aborted
            // cleanly in v1).
            if voiceState == .modelSpeaking {
                voiceDriver?.cancelSpeaking()
                // Fall through to start a fresh turn below.
            } else {
                return
            }
        }

        // Idle/ready path → begin listening. Emit the success telemetry
        // after beginTurn() actually starts; on failure, emit
        // permission_denied or bubble the toast.
        do {
            try await beginVoiceTurnInner()
            emitVoiceAffordance(tier: tier, result: "voice_started")
        } catch SpeechFallbackError.permissionDenied {
            emitVoiceAffordance(tier: tier, result: "permission_denied")
            voiceToastMessage =
                "Microphone access is off. You can keep cooking with taps, or turn on the mic in Settings."
        } catch SpeechFallbackError.recognizerUnavailable {
            emitVoiceAffordance(tier: tier, result: "permission_denied")
            voiceToastMessage = "Voice isn't available on this device."
        } catch {
            Logger.ui.error("voice begin failed: \(error.localizedDescription, privacy: .public)")
            voiceToastMessage = "Voice didn't start. Try again."
        }
    }

    private func beginVoiceTurnInner() async throws {
        guard let voiceDriver else {
            // This happens when the driver failed to initialize (kill
            // switch flipped mid-session, or CookModeRoot never got to
            // preWarm). Treat as permission-denied UX-wise.
            throw SpeechFallbackError.recognizerUnavailable
        }
        try await voiceDriver.beginTurn()
        voiceState = voiceDriver.currentState
    }

    private func endVoiceTurn() async {
        guard let voiceDriver, let recipePlanId = recipePlan.id else { return }

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

            // Act on suggested_action.
            switch result.response.suggestedAction {
            case .advanceStep:
                nextStep()
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
            Logger.ui.error("voice endTurn failed: \(error.localizedDescription, privacy: .public)")
            voiceToastMessage = "Voice turn failed. Try again or tap through."
        }
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
            currentStepTimerSeconds: step.flatMap {
                $0.timerSeconds > 0 ? Int($0.timerSeconds) : nil
            },
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
}
