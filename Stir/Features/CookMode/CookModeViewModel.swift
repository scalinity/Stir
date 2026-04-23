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

    /// Monotonic counter bumped on every timer state mutation (start /
    /// pause / resume / cancel / complete / reconcile). Views read this
    /// to participate in @Observable invalidation even when the
    /// `activeTimers` array contains the same `CookTimer` references
    /// (NSManagedObject mutations do NOT propagate through @Observable
    /// on their own, so SwiftUI wouldn't re-run the button-routing
    /// filter without this explicit bump). Observed 2026-04-22: UI
    /// continued to show pause/cancel buttons after a cancel because
    /// the array-reassignment's `==` compare yielded "unchanged" on
    /// reference-equal contents; the counter dependency forces a
    /// render every time regardless.
    private(set) var timerStateVersion: Int = 0

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
        case nil, .idle, .error, .closed:
            // No live session. Tap begins one.
            return .askWithVoice
        case .ready:
            // `.ready` has TWO distinct meanings that the mic button
            // needs to differentiate:
            //
            //   PRE-FIRST-TURN: preWarm finished (WebSocket open,
            //     setupComplete received) but beginTurn hasn't been
            //     called yet — AUDIO ENGINE IS NOT CAPTURING. User
            //     must tap to start the first turn. Button:
            //     "Ask with voice".
            //
            //   BETWEEN-TURNS: one or more turns have completed in
            //     hands-free mode; mic tap is still installed and
            //     VAD is driving the loop server-side. Button:
            //     "Listening — tap to stop".
            //
            // Observed 2026-04-22: mapping all `.ready` to `.listening`
            // made Cook Mode entry confusing — button said "Listening"
            // seconds after open but the mic wasn't hot, and the first
            // tap closed the session instead of starting a turn.
            return hasBegunFirstTurn ? .listening : .askWithVoice
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

    /// Tracks whether beginTurn has succeeded for the CURRENT voice
    /// session. Flips true on the first successful beginVoiceTurnInner
    /// and back to false on closeVoiceSession / attachVoiceDriver(nil).
    /// Used by `micButtonRole` to differentiate pre-first-turn `.ready`
    /// (show "Ask with voice") from between-turns `.ready` (show
    /// "Listening — tap to stop").
    private(set) var hasBegunFirstTurn: Bool = false

    /// Flipped true when the user taps the mic while voiceState ==
    /// .modelSpeaking (barges in on the model's playback). Consumed by
    /// the NEXT `emitCookTurnResolved` so the `barge_in` property on
    /// the resolved turn reflects whether that turn was started by
    /// interrupting the prior one. `emitCookTurnResolved` resets it
    /// after emission so subsequent non-barged turns stay false.
    /// Semantics: "this turn began by interrupting the previous turn's
    /// playback", not "this turn was interrupted" (that's impossible to
    /// know at emission time — turnComplete fires before playback
    /// finishes).
    private var currentTurnBargedIn: Bool = false

    /// What the mic button is showing right now. Drives icon, label,
    /// color, and enabled-state in StepCardView.
    enum MicButtonRole: Equatable, Sendable {
        /// Default — tap begins a new turn.
        case askWithVoice
        /// Session live, VAD listening between turns — tap ends session.
        case listening
        /// User mid-utterance — tap submits the turn early.
        case submit
        /// Backend/TTS in flight — showing activity, tap escapes.
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
    private let presentPaywall: ((PaywallTrigger) -> Void)?
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

    /// Single-flight sentinel for the driver-rebuild path. When the user
    /// taps "Ask with voice" after a `closeVoiceSession()` teardown, the
    /// VM asks the root for a fresh driver via `onRequestNewVoiceSession`.
    /// That rebuild is async (mint + WebSocket open + setup handshake,
    /// typically 1.5-3s). A rapid second tap during that window would
    /// otherwise see `voiceDriver == nil` and fire a SECOND rebuild in
    /// parallel, spinning up a second WebSocket; the second attach then
    /// clobbers the first driver reference while the first session's
    /// transport stays alive in the background — both sessions process
    /// audio and the model double-responds ("repeat loop" observed
    /// 2026-04-22 PM). This task acts as a fence: the first tap owns
    /// the rebuild; subsequent taps await the same task and then
    /// re-evaluate state. Cleared in `defer` inside handleMicTap so a
    /// failed rebuild doesn't wedge future taps.
    private var rebuildDriverTask: Task<Void, Never>? = nil

    // MARK: - Voice session trace accumulator (PostHog LLM Observability)
    //
    // Populated on every RealtimeSession turnComplete via
    // `recordLiveTurnSummary`. Drained when `fireVoiceSessionCloseTrace`
    // runs (on exit / close / finish) — emits the close-summary
    // $ai_trace per ADR 0009.
    //
    // These are only populated on the Live path; fallback path has no
    // session concept (cook-turn is per-turn standalone via cook-turn's
    // own $ai_generation capture, which covers its own trace implicitly).

    /// Per-turn summaries accumulated from RealtimeSession.
    /// Cleared on each fireVoiceSessionCloseTrace emission to prevent
    /// double-firing on multi-close sequences (exit-after-close).
    private var liveTurnSummaries: [LiveTurnSummary] = []

    /// Wall-clock start of the currently-active Live voice session.
    /// Set when a RealtimeSession attaches; cleared on close trace fire.
    private var voiceSessionStartedAt: Date?

    /// Session id of the currently-active Live voice session, captured
    /// when the driver attaches (so it's available even after `close()`
    /// nulls the driver's mintResponse).
    private var voiceSessionTraceID: String?

    /// $ai_input_state snapshot captured at driver-attach time. Paired
    /// with $ai_output_state in a single close-summary $ai_trace
    /// emission (ADR 0009 — PostHog is append-only, so one emission
    /// carrying both states is the only way to get a complete trace
    /// record). Cleared alongside other session-trace state.
    private var voiceSessionInputState: [String: Any]?

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
            // Seed the $ai_trace session context from the driver passed
            // at construction. `attachVoiceDriver` owns the same logic
            // for the rebuild path, but the initial construction went
            // through `self.voiceDriver = voiceDriver` directly and
            // bypassed trace-id seeding entirely — which silenced
            // voice_session_token_snapshot for the whole session and
            // rolled up $ai_trace close-summary to zero tokens (observed
            // 2026-04-22 across every 5+ turn prod session).
            seedVoiceSessionTrace(from: voiceDriver)
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

    func jumpToStep(_ index: Int, advancedBy: String = "manual") {
        // Guard totalSteps == 0 to avoid `min(-1, index)` producing a
        // negative upper bound (CA1 finding). With no steps there's
        // nowhere to jump.
        guard totalSteps > 0 else { return }
        let clamped = max(0, min(totalSteps - 1, index))
        guard clamped != currentStepIndex else { return }
        do {
            try cookingSessionRepository.advanceStep(session, to: clamped)
            currentStepIndex = clamped
            analytics.capture(.cookStepAdvanced, properties: [
                "step_index": clamped,
                "manual_or_voice": advancedBy,
            ])
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
        // Skip if ANY active timer for this step exists — running,
        // paused, or pending. Voice "start_timer" is idempotent: if
        // there's already a live timer on this step, the model
        // shouldn't produce a duplicate. Extending from the old
        // "running only" check closes the 2026-04-23 device-observed
        // gap where a paused step-4 timer from a resumed session let
        // a second timer slip through, producing the restart-can't-
        // cancel-both bug rooted in `restartCurrentTimerFromVoice`.
        if activeTimers.contains(where: {
            $0.step?.id == step.id
            && ($0.typedState == .running || $0.typedState == .paused || $0.typedState == .pending)
        }) {
            // Log the no-op so a model narration "timer is now running"
            // that doesn't match a visible state change surfaces in
            // device logs instead of being invisible. Silent idempotence
            // is correct behavior, but knowing when it fired helps debug
            // user-reported "model said it started a timer but nothing
            // happened" without instrumenting every device session.
            Logger.ui.info(
                "voice_start_timer_suppressed step=\(Int(step.stepNumber), privacy: .public) reason=active_timer_exists",
            )
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
            // resume (TimerService advances startedAt). Refresh the
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

    /// Lookup the wall-clock time at which this timer was paused.
    /// Nil if the timer isn't currently paused. Drives the static
    /// paused-remaining display in `TimerCountdownView` so the text
    /// stops ticking down while paused.
    func pauseStartedAt(for timer: CookTimer) -> Date? {
        timerService.pauseStartedAt(for: timer)
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

    // MARK: - Voice-initiated timer control (2026-04-22)
    //
    // The model calls these via tool invocations. Each method picks the
    // "current" timer — the running / paused one attached to the user's
    // current step — and applies the action. Returns a small snapshot
    // the driver can stuff into the tool response so the model can
    // narrate state accurately without a follow-up query.

    struct VoiceTimerSnapshot: Sendable, Equatable {
        enum State: String, Sendable, Equatable {
            case running, paused, pending, completed, cancelled, none
        }
        let state: State
        let remainingSeconds: Int     // 0 when state is none/completed/cancelled
        let totalSeconds: Int         // original duration; 0 if no timer exists
        let label: String?
        let stepNumber: Int?          // 1-indexed
    }

    /// Snapshot of the current step's most relevant timer for voice
    /// tool responses. "Most relevant" = running > paused > pending >
    /// completed > cancelled; if none match, returns `.none` state.
    func currentStepTimerSnapshot() -> VoiceTimerSnapshot {
        guard let step = currentStep else {
            return VoiceTimerSnapshot(state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil)
        }
        let matches = activeTimers.filter { $0.step?.id == step.id }
        let priority: [CookTimer.State] = [.running, .paused, .pending, .completed, .cancelled]
        for candidate in priority {
            if let timer = matches.first(where: { $0.typedState == candidate }) {
                let total = Int(timer.durationSec)
                let remaining: Int = {
                    switch candidate {
                    case .running:
                        guard let fire = timer.fireDate else { return 0 }
                        return max(0, Int(fire.timeIntervalSinceNow.rounded()))
                    case .paused:
                        guard let fire = timer.fireDate else { return 0 }
                        // Read the wall-clock pauseStartedAt out of
                        // TimerService's in-memory log so the snapshot
                        // returns a STATIC paused-remaining that doesn't
                        // drift as wall-clock advances. Without this, a
                        // user who pauses at 9:42 and asks voice 2 min
                        // later gets back `remaining_seconds=462` (not
                        // 582) — model narrates the wrong value (review
                        // 2026-04-22 §Critical #4). Fallback to `now` if
                        // the pause context was lost across a cold app
                        // relaunch (documented cross-session limit).
                        let reference = timerService.pauseStartedAt(for: timer) ?? Date()
                        return max(0, Int(fire.timeIntervalSince(reference).rounded()))
                    default:
                        return 0
                    }
                }()
                return VoiceTimerSnapshot(
                    state: .init(rawValue: candidate.rawValue) ?? .none,
                    remainingSeconds: remaining,
                    totalSeconds: total,
                    label: timer.label,
                    stepNumber: Int(step.stepNumber),
                )
            }
        }
        return VoiceTimerSnapshot(
            state: .none,
            remainingSeconds: 0,
            totalSeconds: Int(step.timerSeconds),
            label: nil,
            stepNumber: Int(step.stepNumber),
        )
    }

    /// Voice-initiated pause of the current step's running timer.
    /// Returns the post-action snapshot so the tool handler can include
    /// it in the response. Returns `.none` state if nothing pauseable.
    func pauseCurrentTimerFromVoice() async -> VoiceTimerSnapshot {
        guard let step = currentStep,
              let target = activeTimers.first(where: {
                  $0.step?.id == step.id && $0.typedState == .running
              })
        else {
            return currentStepTimerSnapshot()
        }
        await pauseTimer(target)
        return currentStepTimerSnapshot()
    }

    /// Voice-initiated resume of the current step's paused timer.
    func resumeCurrentTimerFromVoice() async -> VoiceTimerSnapshot {
        guard let step = currentStep,
              let target = activeTimers.first(where: {
                  $0.step?.id == step.id && $0.typedState == .paused
              })
        else {
            return currentStepTimerSnapshot()
        }
        await resumeTimer(target)
        return currentStepTimerSnapshot()
    }

    /// Voice-initiated cancel of the current step's running / paused
    /// / pending timer.
    func cancelCurrentTimerFromVoice() async -> VoiceTimerSnapshot {
        guard let step = currentStep,
              let target = activeTimers.first(where: {
                  $0.step?.id == step.id
                  && ($0.typedState == .running || $0.typedState == .paused || $0.typedState == .pending)
              })
        else {
            return currentStepTimerSnapshot()
        }
        await cancelTimer(target)
        return currentStepTimerSnapshot()
    }

    /// Voice-initiated atomic restart of the current step's timer.
    /// Added 2026-04-22 PM (prompt v1.6.0 + ADR 0014 amendment). The
    /// `start_timer` path early-returns when a running timer for the
    /// step already exists — correct for "start a new timer" intent but
    /// wrong for "restart the current timer" intent. Device test
    /// confirmed the model was saying "restarting timer" while calling
    /// `start_timer` which silently no-opped; user had to say "cancel"
    /// + "start" as two separate turns to actually restart.
    ///
    /// Behavior:
    /// - If there's an existing running/paused/pending timer for this
    ///   step, cancel it first.
    /// - If `seconds` is non-nil, use it; otherwise reuse the original
    ///   timer's total duration.
    /// - If there's no existing timer AND no seconds, return the
    ///   current snapshot (state=.none). The tool handler maps that to
    ///   `ok=false, error=no_existing_timer` so the model advises the
    ///   user to specify a duration.
    /// - Start a fresh timer with the resolved seconds + label (reuse
    ///   prior label when no new label given).
    /// - Return post-restart snapshot.
    func restartCurrentTimerFromVoice(seconds: Int?, label: String?) async -> VoiceTimerSnapshot {
        guard let step = currentStep else {
            return currentStepTimerSnapshot()
        }
        // Find ALL active timers on this step (not just the first). The
        // `.first(where:)` variant hit a device bug 2026-04-23: a
        // resumed session carried forward a running timer on step 4,
        // then a voice `start_timer` couldn't short-circuit (guard
        // only looked at .running — paused/pending slipped through),
        // producing two step-4 active timers. `restart_timer` cancelled
        // only the first, `startTimerFromVoice`'s guard then refused
        // to create the replacement — reproducing the exact "restart didn't restart"
        // symptom the loop is meant to cure. Log so the device-logs
        // surface the bug class rather than hiding it.
        let existingAll = activeTimers.filter {
            $0.step?.id == step.id
            && ($0.typedState == .running || $0.typedState == .paused || $0.typedState == .pending)
        }
        // Duration/label fallback uses the first active timer's
        // configuration — if there are multiple, any is fine since
        // they all represent "the current step's timer."
        let fallbackSource = existingAll.first
        let resolvedSeconds: Int? = seconds ?? fallbackSource.map { Int($0.durationSec) }
        guard let secs = resolvedSeconds, (1...14400).contains(secs) else {
            // No existing timer + no seconds given, OR pathological
            // out-of-range value. Caller will map to no_existing_timer.
            return currentStepTimerSnapshot()
        }
        // Cancel each serially — `cancelTimer` awaits the underlying
        // TimerService cancel + refreshes activeTimers after each one,
        // so by the time startTimerFromVoice runs its guard, all
        // cancelled-then-current state is fully synced.
        for target in existingAll {
            await cancelTimer(target)
        }
        // Partial-failure check: `cancelTimer` swallows TimerService
        // errors internally (logs without rethrowing). If the cancel
        // loop didn't actually clear all step-scoped active timers,
        // startTimerFromVoice's guard will then refuse to create the
        // replacement — reproducing the exact "restart didn't restart"
        // symptom the loop is meant to cure. Log so the device-logs
        // surface the bug class rather than hiding it.
        let stillActive = activeTimers.contains(where: {
            $0.step?.id == step.id
            && ($0.typedState == .running || $0.typedState == .paused || $0.typedState == .pending)
        })
        if stillActive {
            Logger.ui.warning(
                "voice_restart_timer_partial_cancel step=\(Int(step.stepNumber), privacy: .public) attempted=\(existingAll.count, privacy: .public)",
            )
            analytics.capture(.screenErrorShown, properties: [
                "screen": "cook_mode",
                "error_code": "voice_restart_cancel_failed",
                "step_number": Int(step.stepNumber),
                "attempted_cancels": existingAll.count,
            ])
        }
        // Prefer the explicit label; fall back to the prior timer's
        // label so "restart" keeps the same display string.
        let resolvedLabel: String? = label?.isEmpty == false ? label : fallbackSource?.label
        await startTimerFromVoice(seconds: secs, label: resolvedLabel)
        return currentStepTimerSnapshot()
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
        // Fire close-summary $ai_trace AFTER close but BEFORE audio
        // deactivate so the emission happens on the main actor with
        // final state. Idempotent — no-op if no Live trace was active.
        fireVoiceSessionCloseTrace(endedReason: markAbandoned ? "user_exit" : "user_pause")
        AVAudioSessionConfigurator.deactivate()
        // endedAt writes ONLY on abandon — pause-and-resume-later must
        // leave endedAt nil so Tonight Home's Resume banner still picks
        // up the session on the next app open. markAbandoned() in the
        /// repository sets endedAt + status=abandoned atomically, so
        /// the abandon branch's endedAt is already written above.
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
        // Fire-and-forget: schedule the 7-day reactivation nudge (gated
        // on NotificationPreferencesStore.reactivation) and donate the
        // StartNewDinnerSolveIntent to Siri so shortcut suggestions
        // become contextual after the habit's established. Both
        // services internally gate on their own preconditions; we just
        // ask them on every completion.
        Task { await ReactivationScheduler.shared.scheduleAfterCook() }
        Task { await IntentDonationService().donateStartNewDinnerSolveIfEligible() }
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

        // Dispatch on the BUTTON ROLE, not on state directly — the
        // role already encodes what the mic button is showing to the user,
        // so the action must match the label:
        //
        //   .askWithVoice → begin a new turn (fall through below)
        //   .submit        → user wants to submit the current turn
        //                    (tap-to-end UX for .userSpeaking /
        //                    .transcribing)
        //   .busy          → escape trap: close the session
        //                    (.connecting, .thinking, .modelSpeaking,
        //                    .toolCalling, .refreshing, .fallingBack)
        //
        // Prior bug (observed 2026-04-22): dispatch keyed on
        // `isActiveVoiceState(.ready) == true` routed the first tap
        // after preWarm into `closeVoiceSession()` because the button
        // label was "Ask with voice" but the state was `.ready`. User
        // saw no effect and tapped again — the second tap rebuilt the
        // driver and finally started a turn, producing "first tap
        // nothing, second tap works" symptom in every session.
        if voiceDriver != nil {
            switch micButtonRole {
            case .askWithVoice:
                // No live turn running. Driver may be in `.ready`
                // (pre-first-turn), `.idle` (mock / pre-preWarm), or
                // a terminal state. For genuinely-dead drivers
                // (`.error` / `.closed`) drop the reference so the
                // rebuild path below can mint a fresh one — otherwise
                // `beginVoiceTurnInner` would call `beginTurn()` on
                // a driver guaranteed to reject it. `.idle` and
                // `.ready` fall through to beginTurn (mock accepts
                // `.idle`; real driver accepts only `.ready`).
                if let s = voiceDriver?.currentState,
                   s == .error || s == .closed
                {
                    await closeVoiceSession()
                }
                break
            case .listening:
                // Session is live and VAD is hot. Tap = end voice
                // session and return to tap-only Cook Mode.
                await closeVoiceSession()
                emitVoiceAffordance(tier: tier, result: "voice_stopped")
                return
            case .submit:
                // User is mid-utterance → submit the turn early.
                voiceState = .thinking
                await endVoiceTurn()
                return
            case .busy:
                // Escape hatch out of any processing state the user
                // doesn't want to wait on. Flag barge-in specifically
                // when the user interrupts playback — the NEXT `cook_turn_resolved`
                // will carry `barge_in: true` on its
                // `cook_turn_resolved` so dashboards can split
                // polished-interaction turns from interrupted-recovery
                // turns. Non-modelSpeaking .busy escapes (.thinking,
                // .refreshing, etc.) aren't barge-ins; they're the
                // user giving up on a stuck state.
                if voiceState == .modelSpeaking {
                    currentTurnBargedIn = true
                }
                await closeVoiceSession()
                emitVoiceAffordance(tier: tier, result: "voice_stopped")
                return
            }
        }

        // Idle / post-close path — user wants to (re)start voice.
        //
        // If we have no driver (either CookModeRoot never got to
        // preWarm OR the user just closed a prior session via
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
            // Single-flight: if a rebuild is already in flight (user
            // double-tapped), await the in-progress one instead of
            // spawning a parallel rebuild that would orphan the first
            // driver's WebSocket. `rebuildDriverTask` is @MainActor-
            // serialized so the read-then-write is race-free.
            if let inflight = rebuildDriverTask {
                await inflight.value
            } else {
                let task = Task { @MainActor in
                    await rebuild()
                }
                rebuildDriverTask = task
                await task.value
                rebuildDriverTask = nil
            }
        }

        // Begin listening. Emit the success telemetry after
        // beginTurn() actually starts; on failure, map the typed
        // error to copy + emit permission_denied OR forward to the
        // server-error presentation path.
        do {
            try await beginVoiceTurnInner()
            hasBegunFirstTurn = true
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
        // Defensive close on replace. If a non-nil driver is attached
        // while a prior driver is still live, close the prior one first
        // so its WebSocket / mic forwarder / receive dispatcher are torn
        // down instead of orphaned. Normal flow (closeVoiceSession →
        // rebuild) already nils voiceDriver before re-attach, so this
        // branch is a safety net for out-of-order calls or future
        // callers that skip the close step. Without it, 2026-04-22 PM
        // device tests produced "repeat loop" symptoms when rapid taps
        // raced two rebuilds and the second attach replaced the first
        // reference while the first session's frames kept streaming.
        if let existing = self.voiceDriver, existing !== driver {
            Logger.voice.warning(
                "attach_voice_driver_replacing_live_driver old_state=\(existing.currentState.rawValue, privacy: .public)",
            )
            existing.close()
        }
        self.voiceDriver = driver
        // Any driver swap (new attach OR detach) resets the first-turn
        // tracking so the mic button correctly reverts to "Ask with
        // voice" until a fresh beginTurn lands.
        self.hasBegunFirstTurn = false
        if let driver {
            self.voiceState = driver.currentState
            seedVoiceSessionTrace(from: driver)
        } else {
            self.voiceState = .closed
        }
    }

    /// Start a new Live-session trace when a driver arrives with a
    /// mint-populated session id. Idempotent: re-entry with the same
    /// session id is a no-op, so attach/rebuild paths don't double-count
    /// duration. Called from BOTH the VM init (initial attach via the
    /// constructor parameter) AND `attachVoiceDriver` (rebuild after
    /// closeVoiceSession). Before this was factored out, the init path
    /// silently skipped trace-id seeding, which silenced
    /// voice_session_token_snapshot for the whole session and rolled
    /// up $ai_trace close-summary to zero tokens.
    private func seedVoiceSessionTrace(from driver: any VoiceSessionDriver) {
        guard let sid = driver.voiceSessionID, sid != voiceSessionTraceID else { return }
        // If a prior trace id is still populated at reseed time, the
        // previous session's `fireVoiceSessionCloseTrace` never fired —
        // which means the previous session's $ai_trace is about to be
        // silently dropped (liveTurnSummaries.removeAll() + trace id
        // overwrite below). All current call sites close the prior
        // session BEFORE rebuilding (CookModeViewModel.exit →
        // CookModeRoot.onRequestNewVoiceSession), so this should never
        // fire in practice. Logging at error severity keeps the
        // invariant observable so we catch regressions that route
        // around the close step.
        if let priorTraceID = voiceSessionTraceID {
            Logger.telemetry.error(
                "voice_session_reseed_over_live_trace prior=\(priorTraceID, privacy: .public) new=\(sid, privacy: .public) — previous close-trace never fired",
            )
        }
        voiceSessionTraceID = sid
        voiceSessionStartedAt = Date()
        liveTurnSummaries.removeAll()
        // Assemble $ai_input_state now while driver has fresh mint
        // metadata. Drained alongside $ai_output_state in
        // `fireVoiceSessionCloseTrace` — one emission, both states,
        // per ADR 0009.
        var inputState: [String: Any] = [
            "cooking_session_id": session.id?.uuidString ?? "",
            "recipe_plan_id": recipePlan.id?.uuidString ?? "",
            "current_step_number": currentStepIndex + 1,
            "path": driver.pathLabel.rawValue,
        ]
        if let promptVersion = driver.voiceSessionPromptVersion {
            inputState["prompt_version"] = promptVersion
        }
        voiceSessionInputState = inputState
    }

    /// Called by CookModeRoot's `onTurnFinalized` wiring on every
    /// RealtimeSession `turnComplete`. Accumulates tokens/latency so
    /// the close-summary $ai_trace can publish totals when the user
    /// ends the session. Drops silently if no trace is active (e.g.,
    /// summaries arriving after fireVoiceSessionCloseTrace already ran).
    ///
    /// Also emits the spec §15 `voice_session_token_snapshot` event
    /// every 5 turns for runaway-cost detection. Cumulative tokens are
    /// computed from the same summaries array the close-summary trace
    /// uses, so a live sum at snapshot time + a final sum at close
    /// agree without any separate counter to drift.
    func recordLiveTurnSummary(_ summary: LiveTurnSummary) {
        guard let traceID = voiceSessionTraceID else { return }
        liveTurnSummaries.append(summary)

        // Fire cook_turn_submitted + cook_turn_resolved here rather
        // than from endVoiceTurn, because hands-free Live sessions
        // don't call endVoiceTurn at all — VAD drives turn boundaries
        // server-side and the VM never taps to submit. A 30-turn
        // hands-free session on 2026-04-22 produced zero
        // cook_turn_submitted / cook_turn_resolved events (bug) while
        // the backend billed 10 $ai_generation rows and the token
        // snapshot fired at turns 5/10/15/20 — confirming the session
        // was healthy and the emission site was simply wrong. Events
        // fire per-turn at finalize. `result_type` is "tool_call" when
        // the driver observed a `toolCall` frame during the turn
        // (`summary.containedToolCall`), else "normal" — gating ADR
        // 0012's split TTFA thresholds. Tap-to-end paths on the fallback
        // path keep their endVoiceTurn emission; the Live path's
        // endVoiceTurn skips emission to avoid double-firing.
        let submittedAt = Date(timeIntervalSince1970: summary.endedAt.timeIntervalSince1970 - Double(summary.latencyMs) / 1000.0)
        let pathLabel = voiceDriver?.pathLabel.rawValue ?? "live_api"
        analytics.capture(.cookTurnSubmitted, properties: [
            "turn_type": "voice",
            "current_step_index": currentStepIndex,
            "path": pathLabel,
        ])
        emitCookTurnResolved(
            submittedAt: submittedAt,
            pathLabel: pathLabel,
            resultType: summary.containedToolCall ? "tool_call" : "normal",
            latencyTtfaMs: summary.latencyTtfaMs,
            errorCode: nil,
        )

        // C.5: token snapshot every 5 turns (5, 10, 15, …). Skip when
        // count == 0 (unreachable in practice — append above guarantees
        // count >= 1 — but guards against misuse if a test injects a
        // zero-index summary). Properties are spec §15 verbatim.
        let turnsSoFar = liveTurnSummaries.count
        if turnsSoFar > 0 && turnsSoFar % 5 == 0 {
            // Raw totals (prompt + response) so runaway-cost detection
            // catches the AUDIO-mode per-pass overhead that the text+audio
            // breakdown undersums. Matches `total_prompt_tokens` +
            // `total_response_tokens` on the close-summary $ai_trace.
            let cumulative = liveTurnSummaries.reduce(0) {
                $0 + $1.promptTokensTotal + $1.responseTokensTotal
            }
            analytics.capture(.voiceSessionTokenSnapshot, properties: [
                "session_id": traceID,
                "turns_so_far": turnsSoFar,
                "cumulative_tokens": cumulative,
                "current_step_index": currentStepIndex,
            ])
        }
    }

    /// Called by the RealtimeSession actor when `refreshSession()` resolves
    /// — success OR failure. Emits spec §15 `voice_session_refreshed`
    /// with a `success: bool` property so the Voice session health
    /// dashboard can compute refresh success rate.
    ///
    /// On success the sessionID is the NEW (post-swap) id; on failure
    /// it's the OLD id (swap didn't commit, or committed-but-handshake-
    /// failed and the session transitioned to .error).
    func recordVoiceSessionRefresh(
        reason: String,
        turnsAtRefresh: Int,
        sessionID: String,
        success: Bool,
    ) {
        analytics.capture(.voiceSessionRefreshed, properties: [
            "session_id": sessionID,
            "refresh_reason": reason,
            "turns_at_refresh": turnsAtRefresh,
            "success": success,
        ])
    }

    /// Called by the RealtimeSession actor when the stuck-modelSpeaking
    /// watchdog fires. Emits `voice_turn_stuck_watchdog_fired` so ops
    /// can track incidence rate of the underlying Gemini Live protocol
    /// bug (ADR 0015 cap-reversal trigger threshold: >5% of tool-call
    /// turns = revisit §18 vendor contingency).
    ///
    /// `sessionID` is always populated ("unknown" fallback applied at
    /// the callback's call site in RealtimeSession if the invariant
    /// ever breaks). `toolCallType` is nullable because a watchdog fire
    /// on a non-tool-call turn is theoretically possible (haven't
    /// observed yet); omitted-from-props when nil.
    func recordVoiceTurnStuckWatchdogFired(
        sessionID: String,
        turnIndex: Int,
        toolCallType: String?,
        elapsedStuckMs: Int,
        turnLengthAtStuck: Int,
    ) {
        var props: [String: Any] = [
            "session_id": sessionID,
            "turn_index": turnIndex,
            "elapsed_stuck_ms": elapsedStuckMs,
            "turn_length_at_stuck": turnLengthAtStuck,
        ]
        if let toolCallType { props["tool_call_type"] = toolCallType }
        analytics.capture(.voiceTurnStuckWatchdogFired, properties: props)
    }

    /// Called by the RealtimeSession actor on each `substitution_check`
    /// tool invocation, before the dispatch hits /v1/ai/substitution.
    /// Emits spec §15 `substitution_requested` with
    /// `invocation: "realtime_function_call"` so the rescue-usage
    /// dashboard can split voice-driven vs sheet-driven substitutions
    /// (the sheet path fires the same event with `invocation: "sheet"`
    /// in SubstitutionSheetViewModel.submit).
    ///
    /// problem_type is "free_text" here — voice has no picker UX, so
    /// the value mirrors the sheet's free-text path. Dashboards split
    /// voice vs sheet via the `invocation` property, not `problem_type`,
    /// so reusing the existing vocabulary avoids a spec §15 amendment.
    func recordVoiceSubstitutionRequested(subEventID: String? = nil) {
        // Voice path doesn't have a picker UX; problem_type mirrors the
        // sheet's free-text classification so dashboards can split by
        // `invocation` rather than needing different problem_type vocab.
        // Paired with `recordVoiceSubstitutionResolved` below — both
        // carry `sub_event_id` so the funnel joins cleanly.
        Logger.telemetry.info(
            "substitution_requested invocation=realtime_function_call sub_event_id=\(subEventID ?? "-", privacy: .public)",
        )
        var props: [String: Any] = [
            "problem_type": "free_text",
            "invocation": "realtime_function_call",
        ]
        if let subEventID { props["sub_event_id"] = subEventID }
        analytics.capture(.substitutionRequested, properties: props)
    }

    /// Emits `substitution_accepted` on the voice path. Voice has no
    /// user confirm step — safe substitutions are auto-applied
    /// (accepted=true, reason=auto_applied), unsafe results are refused
    /// by the system (accepted=false, reason=unsafe_refused). The
    /// funnel joins this event back to the requested event on
    /// `sub_event_id`. Driver (`RealtimeSession`) fires
    /// `onSubstitutionResolvedFromVoice` from the substitution
    /// tool-response path with the hard-rule-validator outcome.
    func recordVoiceSubstitutionResolved(constraintSafe: Bool, subEventID: String) {
        let reason = constraintSafe ? "auto_applied" : "unsafe_refused"
        Logger.telemetry.info(
            "substitution_accepted invocation=realtime_function_call sub_event_id=\(subEventID, privacy: .public) accepted=\(constraintSafe, privacy: .public) constraint_safe=\(constraintSafe, privacy: .public) reason=\(reason, privacy: .public)",
        )
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": constraintSafe,
            "constraint_safe": constraintSafe,
            "invocation": "realtime_function_call",
            "sub_event_id": subEventID,
            "reason": reason,
        ])
    }

    /// Fires the single `$ai_trace` per voice session (ADR 0009).
    /// Emits with BOTH `$ai_input_state` (captured at attach time) and
    /// `$ai_output_state` (session totals) populated in one event —
    /// PostHog is append-only, so one emission carrying both states is
    /// the only way to get a complete trace record. Idempotent: guard on
    /// voiceSessionTraceID prevents exit-after-close double-fire.
    ///
    /// endedReason values:
    ///   "user_exit"      — user tapped Exit
    ///   "user_stop"      — user tapped mic to stop voice (kept cook mode)
    ///   "user_pause"     — user paused mid-session (not abandoning)
    ///   "session_finish" — user completed the recipe
    ///   "error"          — driver surfaced an unrecoverable error
    private func fireVoiceSessionCloseTrace(endedReason: String) {
        guard let traceID = voiceSessionTraceID else { return }
        let startedAt = voiceSessionStartedAt ?? Date()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let summaries = liveTurnSummaries
        let totalPromptText = summaries.reduce(0) { $0 + $1.promptTokensText }
        let totalPromptAudio = summaries.reduce(0) { $0 + $1.promptTokensAudio }
        let totalPromptRaw = summaries.reduce(0) { $0 + $1.promptTokensTotal }
        let totalResponseText = summaries.reduce(0) { $0 + $1.responseTokensText }
        let totalResponseAudio = summaries.reduce(0) { $0 + $1.responseTokensAudio }
        let totalResponseRaw = summaries.reduce(0) { $0 + $1.responseTokensTotal }
        // `total_prompt_tokens` / `total_response_tokens` are Gemini's
        // raw totals (matches backend `ai_request_log.input_tokens` /
        // `output_tokens` SUM). Text+audio breakdowns may undersum the
        // total by the AUDIO-mode per-pass overhead — that delta is
        // documented in LiveTurnSummary + spec §15.
        let outputState: [String: Any] = [
            "total_turns": summaries.count,
            "total_prompt_tokens": totalPromptRaw,
            "total_response_tokens": totalResponseRaw,
            "total_prompt_tokens_text": totalPromptText,
            "total_prompt_tokens_audio": totalPromptAudio,
            "total_response_tokens_text": totalResponseText,
            "total_response_tokens_audio": totalResponseAudio,
            "ended_reason": endedReason,
            "duration_ms": durationMs,
            "path": "live_api",
        ]
        analytics.captureAITrace(
            traceID: traceID,
            spanName: "voice_session_start",
            inputState: voiceSessionInputState,
            outputState: outputState,
            feature: "cook_mode_realtime",
        )
        Logger.ui.info(
            "voice_session_close_trace session_id=\(traceID, privacy: .public) turns=\(summaries.count, privacy: .public) duration_ms=\(durationMs, privacy: .public) reason=\(endedReason, privacy: .public)",
        )
        voiceSessionTraceID = nil
        voiceSessionStartedAt = nil
        voiceSessionInputState = nil
        liveTurnSummaries.removeAll()
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
        hasBegunFirstTurn = false
        // Fire close-summary $ai_trace (idempotent). Cook Mode stays
        // open — user kept the session active but stopped voice; the
        // trace emission seals the PostHog trace record regardless.
        fireVoiceSessionCloseTrace(endedReason: "user_stop")
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
        let pathLabel = voiceDriver.pathLabel.rawValue
        // Live path fires cook_turn_submitted + cook_turn_resolved from
        // `recordLiveTurnSummary` (onTurnFinalized callback) because
        // hands-free sessions never reach this endVoiceTurn method —
        // VAD drives turn boundaries server-side and the VM never taps
        // to submit. Firing here too would double-count. Fallback path
        // (Speech) has no onTurnFinalized equivalent, so it keeps the
        // emission here. See `recordLiveTurnSummary` for the Live-side
        // emission docstring.
        let isLivePath = pathLabel == "live_api"
        if !isLivePath {
            analytics.capture(.cookTurnSubmitted, properties: [
                "turn_type": "voice",
                "current_step_index": currentStepIndex,
                "path": pathLabel,
            ])
        }

        // `cook_turn_resolved` MUST fire on every terminal turn path —
        // success, tool_call, or error — so the success rate is
        // measurable and the submitted:resolved ratio stays ~1:1.
        // `emitResolved` is a fallback-only wrapper: skipped entirely
        // on the Live path where recordLiveTurnSummary fires the pair.
        let emitResolved: (_ resultType: String, _ latencyTtfaMs: Int, _ errorCode: ErrorCode?) -> Void = { [submittedAt, pathLabel, isLivePath] resultType, latencyTtfaMs, errorCode in
            if isLivePath { return }
            self.emitCookTurnResolved(
                submittedAt: submittedAt,
                pathLabel: pathLabel,
                resultType: resultType,
                latencyTtfaMs: latencyTtfaMs,
                errorCode: errorCode,
            )
        }

        do {
            let result = try await voiceDriver.endTurn(
                recipeContext: recipeCtx,
                householdContext: householdCtx,
                currentStepNumber: currentStepIndex + 1,
                recipePlanId: recipePlanId,
            )
            voiceState = voiceDriver.currentState

            // Classify success terminal path. A non-`.none` suggestedAction
            // means the model executed a tool (advance step / start timer
            // / etc) and the turn's outcome is a tool-driven state change
            // rather than a plain conversational reply.
            let resultType: String = {
                switch result.response.suggestedAction {
                case .advanceStep, .startTimer: return "tool_call"
                case .none: return "normal"
                }
            }()
            emitResolved(resultType, result.sttLatencyMs, nil)

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
            emitResolved("error", 0, ErrorCode.ai02)
        } catch {
            voiceState = voiceDriver.currentState
            let presented = presentStirError(error, screen: "cook_mode_voice_end")
            // Surface a best-effort error code for the resolved event —
            // StirError's presentableCode if typed, NET-01 otherwise.
            let errorCode: ErrorCode = (error as? StirError)?.presentableCode ?? .net01
            emitResolved("error", 0, errorCode)
            if !presented {
                Logger.ui.error("voice endTurn failed: \(error.localizedDescription, privacy: .public)")
                showVoiceError(
                    message: "Voice didn't start. Try again.",
                    errorCode: "NET-01",
                    screen: "cook_mode_voice_begin",
                )
            }
        }
    }

    /// Emit `cook_turn_resolved` with spec §15 properties. Must fire on
    /// every terminal turn path — success (`normal`), tool-driven
    /// success (`tool_call`), or error (`error` + `error_code`) — so
    /// the submitted:resolved ratio stays ~1:1 and error rate per path
    /// is measurable. Callers pass the per-turn `submittedAt` so
    /// `latency_total_ms` is anchored at turn submission, not method
    /// entry. `latency_ttfa_ms` is 0 on error paths where TTFA couldn't
    /// be clocked.
    private func emitCookTurnResolved(
        submittedAt: Date,
        pathLabel: String,
        resultType: String,
        latencyTtfaMs: Int,
        errorCode: ErrorCode? = nil,
    ) {
        let totalMs = Int(Date().timeIntervalSince(submittedAt) * 1000)
        var props: [String: Any] = [
            "latency_ttfa_ms": latencyTtfaMs,
            "latency_total_ms": totalMs,
            // Barge-in deferred per ADR 0011 (half-duplex gate in place
            // of native barge-in); always false for v1. Reintroduce a
            // VM-owned bool here when the driver-side barge-in telemetry
            // lands.
            "barge_in": false,
            "path": pathLabel,
            "result_type": resultType,
        ]
        if let errorCode { props["error_code"] = errorCode.rawValue }
        analytics.capture(.cookTurnResolved, properties: props)
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
        // Build the full numbered-step list so the model can answer
        // cross-step questions accurately ("what's step 3?") without
        // hallucinating. stepNumber is 1-indexed. Backend Zod schema
        // requires `text: z.string().min(1)` so any step with
        // nil/whitespace-only instruction text would VAL-01 the mint —
        // coerce to a safe placeholder that the model can recognize.
        let allSteps = recipePlan.stepArray.map {
            RealtimeRecipeContext.StepDescription(
                stepNumber: Int($0.stepNumber),
                text: Self.safeInstructionText($0.instructionText),
                // 0 = no timer. Backend schema requires the key present.
                timerSeconds: Int($0.timerSeconds),
            )
        }
        return RealtimeRecipeContext(
            title: recipePlan.title ?? "",
            servings: Int(recipePlan.servings),
            estimatedMinutes: Int(recipePlan.estimatedMinutes),
            totalSteps: totalSteps,
            currentStepText: Self.safeInstructionText(step?.instructionText),
            // 0 when no timer on this step. DTO is non-Optional because
            // backend requires the key to be present — see
            // RealtimeRecipeContext.currentStepTimerSeconds doc comment.
            currentStepTimerSeconds: Int(step?.timerSeconds ?? 0),
            allSteps: allSteps,
            remainingIngredients: remaining,
        )
    }

    /// Coerces nil / whitespace-only instruction text into a safe
    /// placeholder. Zod validates `text: z.string().min(1)` on every
    /// step and on the current step; if the source recipe has a blank
    /// step (malformed import, broken AI output), the raw empty string
    /// would VAL-01 the mint and silently downgrade the user to C.3.
    /// Placeholder is human-readable so the model can acknowledge
    /// it rather than hallucinate.
    static func safeInstructionText(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(step instruction unavailable)" : trimmed
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

    /// Test-only hook for flipping the first-turn flag. Drives the
    /// pre-first-turn vs between-turns split on `.ready` that
    /// `micButtonRole` uses. Production code flips this via
    /// `handleMicTap`'s success path / reset sites only.
    func _testForceHasBegunFirstTurn(_ value: Bool) {
        hasBegunFirstTurn = value
    }
    #endif
}
