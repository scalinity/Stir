// CookModeViewModel
//
// Drives the tap-based Cook Mode flow for a single CookingSession:
//   enter  → StepCardView on step N
//   Next   → step N+1, persist advance, fire cook_step_advanced
//   Prev   → step N-1, persist advance
//   Timer  → TimerService.start/pause/resume/cancel
//   Ask    → (raise navigation to SubstitutionSheet — handled by root)
//   Finish → markCompleted, navigate to OutcomeFeedback
//   Exit   → confirm, markAbandoned or keep active for resume
//
// Step-4 constraint (per Daniel's scope alignment): voice is structurally
// absent. No microphone affordance. The "Ask" button opens a text
// Substitution Sheet only.

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

    // MARK: - Deps

    private let cookingSessionRepository: CookingSessionRepository
    private let cookTimerRepository: CookTimerRepository
    private let timerService: TimerService
    private let analytics: PostHogClient

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

        // Emit cook_mode_started with `within_3min` flag derived from
        // the session's startedAt vs now — covers the spec §15 anchor
        // event `core_success_event` (scan → select → cook within 3 min).
        let within3Min: Bool = {
            guard let started = session.startedAt else { return false }
            return Date().timeIntervalSince(started) <= 3 * 60
        }()
        analytics.capture(.cookModeStarted, properties: [
            "source": source.rawValue,
            "voice_enabled": false,
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
            "voice_enabled": false,
            "recipe_plan_id": recipePlan.id?.uuidString ?? "",
        ])
        finishPresentationRequested = true
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
