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

    // MARK: - Voice transcript display

    /// Most recent user utterance — drives the YOU SAID side of the
    /// voice-active transcript card. Nil pre-first-turn and after
    /// closeVoiceSession. Set from `recordTurnTranscript` on every
    /// `turnComplete` that produced any non-empty text on either side.
    /// Empty strings are coerced to nil so the UI can short-circuit
    /// the "no transcript yet" branch with a single nil check on
    /// either field.
    private(set) var lastUserTranscript: String?

    /// Most recent Stir reply paired with `lastUserTranscript`. See
    /// that property's docstring — same lifecycle.
    private(set) var lastModelTranscript: String?

    /// Raw peak amplitude in [0, 1] from the active voice driver — mic
    /// while the user speaks, model output while Stir speaks. 0 when
    /// no driver is attached.
    ///
    /// This is a thin pass-through, NOT a stored property: the actual
    /// peak lives in `LiveAudioPipeline`'s `OSAllocatedUnfairLock`
    /// storage (non-Observable). The `voiceDriver` reference IS
    /// Observation-tracked, so swapping drivers (attach / detach)
    /// invalidates correctly, but per-frame audio peaks deliberately
    /// skip Observation entirely — there's no stored property here for
    /// the macro to instrument. The voice-active waveform pulls fresh
    /// peaks via this getter on each `TimelineView` tick (30 Hz) and
    /// applies its own attack/decay smoothing, so no Observation
    /// invalidation loop is even possible.
    var currentVoiceAudioLevel: Float {
        voiceDriver?.currentAudioLevel ?? 0
    }

    /// True when the user has explicitly engaged voice mode (tapped
    /// "Ask with voice" or auto-engage fired) AND the underlying voice
    /// session is connecting / established / working. Drives the
    /// `isVoiceActive` switch so the UI:
    ///   - flips to voice chrome IMMEDIATELY on tap, before the
    ///     driver's preWarm + connect awaitables resolve (hence the
    ///     synchronous-set-then-async-work pattern in handleMicTap);
    ///   - reverts to tap chrome the instant the user taps end.
    ///
    /// Without this flag, `isVoiceActive` would gate solely on the
    /// driver's `voiceState` — but `CookModeRoot.task` pre-warms the
    /// driver at Cook Mode entry, which transitions state through
    /// `.connecting → .ready` BEFORE the user has tapped anything. The
    /// UI would then auto-show voice-active chrome on entry, surprising
    /// the user (observed 2026-04-27). The flag captures intent, the
    /// state captures liveness — both must be true to render voice UI.
    private(set) var isVoiceUIRequested: Bool = false

    /// True when a voice session is connecting, established, or working
    /// AND the user has explicitly engaged voice mode. Used by the
    /// view layer to switch between tap-mode chrome and voice-active
    /// chrome. Excludes terminal states (`.idle`, `.closed`, `.error`)
    /// so the chrome reverts the instant the session ends — even if
    /// the user-intent flag still happened to be true.
    var isVoiceActive: Bool {
        guard isVoiceUIRequested else { return false }
        guard let state = voiceState else { return false }
        switch state {
        case .idle, .closed, .error:
            return false
        case .connecting, .ready, .userSpeaking, .transcribing,
             .thinking, .modelSpeaking, .toolCalling, .refreshing,
             .fallingBack:
            return true
        }
    }

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
    private let substitutionRepository: SubstitutionRepository
    /// Used by `performFinishAsyncTail` to auto-consume pantry items per ADR 0029
    /// (SCA-21). Memory-state-aware: ephemeral matches soft-delete,
    /// remembered matches bump `lastSeenAt`. No confirmation prompt;
    /// the conservative match rule is the safety mechanism.
    private let pantryItemRepository: PantryItemRepository
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

    /// P1-K (2026-04-23): set to true when `RealtimeSession.onVoiceFallbackRequired`
    /// fires — i.e., a post-commit refresh failure rendered the current
    /// Live session unrecoverable AND a fresh Live preWarm is likely to
    /// fail the same way. `CookModeRoot.onRequestNewVoiceSession` reads
    /// this on every rebuild and, if true, skips Live entirely and goes
    /// straight to C.3 for the remainder of this Cook Mode entry.
    /// Resets to `false` on Cook Mode exit (new VM instance on re-entry).
    private(set) var pinFallbackForCookSession: Bool = false

    /// Called by driver callbacks when Live becomes unrecoverable. Public
    /// so `CookModeRoot.wireVoiceDriver` can set it as the Live driver's
    /// `onVoiceFallbackRequired` handler.
    func setPinFallbackForCookSession(reason: String) {
        guard !pinFallbackForCookSession else { return }
        pinFallbackForCookSession = true
        Logger.voice.info(
            "voice_pin_fallback_for_cook_session reason=\(reason, privacy: .public) — further rebuilds route to C.3",
        )
    }

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

    // MARK: - Voice session telemetry
    //
    // SCA-80: per-Live-session $ai_trace accumulator + the small cluster
    // of voice event emitters (cook_turn_resolved, screen_error_shown,
    // voice_affordance_tapped, voice_session_refreshed,
    // voice_turn_stuck_watchdog_fired, substitution_requested /
    // substitution_accepted on the voice path) live on this helper.
    // Public-facing methods (`recordLiveTurnSummary`,
    // `recordVoiceSessionRefresh`, etc.) keep their VM-side signatures
    // as thin forwarders so CookModeRoot + the test suite don't change.
    // `recordTurnTranscript` is deliberately NOT delegated here — it's
    // a UI-state mutator (lastUserTranscript / lastModelTranscript), not
    // telemetry — and stays inline below.
    private let voiceTelemetry: VoiceSessionTelemetry

    // MARK: - Init

    init(
        session: CookingSession,
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        source: EntrySource,
        cookingSessionRepository: CookingSessionRepository,
        cookTimerRepository: CookTimerRepository,
        substitutionRepository: SubstitutionRepository,
        pantryItemRepository: PantryItemRepository,
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
        // SCA-189 (review-CR2-C1): repos are required, no `.shared`
        // fallback. A test that omits any of the four now fails to
        // compile — which is the entire bug-class-closure invariant
        // SCA-182 claimed but didn't enforce.
        self.cookingSessionRepository = cookingSessionRepository
        self.cookTimerRepository = cookTimerRepository
        self.substitutionRepository = substitutionRepository
        self.pantryItemRepository = pantryItemRepository
        // Resolve LiveActivityManager FIRST so the same instance can be
        // injected into TimerService below. Without sharing, VM-side
        // `startLiveActivity()` populated dict A while TimerService's
        // pause/resume/cancel/markCompleted fanned out to dict B (empty)
        // — every Lock Screen update/end was a silent no-op (CR1-18
        // contract intact, instance plumbing was the bug; observed
        // device-side 2026-05-03).
        let resolvedLiveActivityManager = liveActivityManager ?? LiveActivityManager()
        self.liveActivityManager = resolvedLiveActivityManager
        // SCA-189: when the caller doesn't pass an explicit timerService,
        // construct one against THIS VM's repos rather than letting
        // TimerService default to .shared. Same controller-routing
        // invariant as the four repos above.
        self.timerService = timerService ?? TimerService(
            repository: cookTimerRepository,
            sessionRepository: cookingSessionRepository,
            liveActivityManager: resolvedLiveActivityManager,
        )
        self.analytics = analytics
        self.sentry = sentry ?? SentryReporter.shared
        self.entitlements = entitlements
        self.voiceDriver = voiceDriver
        self.disableCookRealtimeAtEntry = disableCookRealtime
        self.presentPaywall = presentPaywall
        // Construct telemetry helper AFTER analytics is set; trace seed
        // path below depends on it being live.
        self.voiceTelemetry = VoiceSessionTelemetry(analytics: analytics)
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
            // Voice path reached last step via suggested_action=advance_step.
            // Route through finish() so telemetry + scheduling + donations +
            // timer/LiveActivity/voice teardown run — NOT just the
            // presentation flag. Previously this branch silently dropped
            // cook_session_completed, markCompleted, ReactivationScheduler,
            // IntentDonationService, fireVoiceSessionCloseTrace, and all
            // timer cleanup for every voice-driven recipe completion.
            finish()
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
            // TimerService.pause captures paused-remaining BEFORE the
            // repo flip and calls liveActivityManager.update with the
            // static value internally (CR1-18). No VM-side fan-out.
            try await timerService.pause(timer, on: session)
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1
        } catch {
            Logger.ui.error("pause failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func resumeTimer(_ timer: CookTimer) async {
        do {
            // TimerService.resume advances startedAt then calls
            // liveActivityManager.update with the new fireDate + nil
            // paused flag internally (CR1-18).
            try await timerService.resume(timer, on: session)
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
            // TimerService.cancel ends the Live Activity with reason
            // .cancelled internally (CR1-18).
            try await timerService.cancel(timer, on: session)
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
        /// P0-C (2026-04-23): restart-path bookkeeping. nil for non-restart
        /// flows (start / pause / resume / cancel / status). On the restart
        /// path, `true` means "the cancel-before-start loop completed AND
        /// the new timer is live"; `false` means the pre-restart timer
        /// cancel partially failed and the returned snapshot reflects a
        /// stale still-running timer, NOT the intended restart.
        ///
        /// Prior bug: `restart_timer` dispatch checked only `state ==
        /// .running || .pending` → returned ok=true when the old timer
        /// was still ticking; model narrated "I restarted the timer"
        /// while the original alarm kept its original fire date. Device-
        /// reproduced 2026-04-23.
        var restartSucceeded: Bool? = nil
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
            // Diagnostic detail (step_number, attempted_cancels) is in
            // the sibling `Logger.ui.warning` above — spec §15 only
            // permits `screen_name` + `error_code` on this event.
            emitScreenError(screen: "cook_mode", errorCode: "voice_restart_cancel_failed")
            // Return the stale snapshot but explicitly flag the restart
            // as failed so `dispatchTool`'s restart_timer case maps to
            // ok=false / error=cancel_failed rather than narrating a
            // bogus "restarted" to the user. The original timer is
            // still the live one and its original fire date stands.
            var snap = currentStepTimerSnapshot()
            snap.restartSucceeded = false
            return snap
        }
        // Prefer the explicit label; fall back to the prior timer's
        // label so "restart" keeps the same display string.
        let resolvedLabel: String? = label?.isEmpty == false ? label : fallbackSource?.label
        await startTimerFromVoice(seconds: secs, label: resolvedLabel)
        var snap = currentStepTimerSnapshot()
        // Happy-path sentinel: caller knows the restart pipeline
        // completed cleanly (cancel loop drained + new timer started).
        // Dispatch still double-checks `state == .running || .pending`
        // because `startTimerFromVoice` has its own failure modes
        // (out-of-range seconds, Core Data write failure) that'd leave
        // state at .none even on a clean cancel.
        snap.restartSucceeded = true
        return snap
    }

    /// Call on foreground or Cook Mode re-entry. Natural-completion
    /// timers whose fire date passed while backgrounded get marked
    /// completed. Then any still-running (not-yet-expired) timer that
    /// lacks a Live Activity has one re-created so the Lock Screen
    /// surface matches the in-app countdown after a cold launch (where
    /// `LiveActivityManager.reconcileOnLaunch` cleared every persisted
    /// activity to fix the "force-killed app leaves stale countdown
    /// counting up" bug — observed device-side 2026-05-03).
    func reconcileTimersOnForeground() async {
        do {
            // TimerService.reconcileOnForeground now ends each
            // transitioned timer's Live Activity with reason .completed
            // internally (CR1-18).
            _ = try await timerService.reconcileOnForeground(session: session)
            activeTimers = cookTimerRepository.timers(for: session)
            timerStateVersion &+= 1
            // Restore Live Activities for running OR paused timers without
            // one. After `LiveActivityManager.reconcileOnLaunch` ended every
            // persisted activity at app start, the in-memory dict is empty
            // for any timer carried across the cold launch — so pause/cancel/
            // resume from this VM would otherwise no-op against a missing
            // Lock Screen surface. Paused timers also need a fresh activity
            // so a subsequent `resumeTimer` → `liveActivityManager.update()`
            // has something to update.
            //
            // `start(...)` is itself idempotent (returns early if the
            // timerId is already tracked), but `hasActivity(for:)` keeps
            // the call sites explicit about intent. After re-creating, the
            // paused branch flushes the static paused-remaining snapshot
            // via `update(...)` so the Lock Screen shows the frozen value
            // instead of a fresh count-down from `fireDate`.
            // DB1-1 fix: paused-timer reconcile reads the persisted
            // `pausedRemainingSeconds` rather than recomputing
            // `fireDate - now`. The fireDate doesn't move while paused,
            // so post-cold-launch the recomputation reports a smaller
            // remaining than was actually frozen at pause time, and
            // skips entirely once `now > fireDate`. Persisted snapshot
            // survives the force-quit. The running branch still uses
            // fireDate-based timing (fireDate is authoritative when the
            // timer is counting down).
            let now = Date()
            for timer in activeTimers
            where timer.typedState == .running || timer.typedState == .paused {
                guard let id = timer.id,
                      let step = timer.step else { continue }

                if timer.typedState == .running {
                    guard let fire = timer.fireDate, fire > now,
                          !liveActivityManager.hasActivity(for: id) else { continue }
                    startLiveActivity(for: timer, step: step)
                } else {
                    // Paused branch: reuse the persisted snapshot if any,
                    // else fall back to the fireDate computation. We only
                    // skip recreating the activity when one is already
                    // tracked in-memory (typical mid-session foreground)
                    // — cold-launch survivors will have nothing in the
                    // dict and need a fresh activity.
                    let pausedRemaining: Int
                    if let snapshot = timer.pausedRemainingSeconds {
                        pausedRemaining = snapshot
                    } else if let fire = timer.fireDate {
                        pausedRemaining = max(0, Int(fire.timeIntervalSince(now).rounded()))
                    } else {
                        pausedRemaining = 0
                    }
                    let fireDate = timer.fireDate ?? now.addingTimeInterval(TimeInterval(pausedRemaining))
                    if !liveActivityManager.hasActivity(for: id) {
                        startLiveActivity(for: timer, step: step)
                    }
                    await liveActivityManager.update(
                        timerId: id,
                        fireDate: fireDate,
                        pausedRemainingSec: pausedRemaining,
                    )
                }
            }
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
                // TimerService.cancel ends the Live Activity with
                // reason .cancelled internally (CR1-18). Filter is
                // intentionally `.running`-only: the CA2-R1 dangling-
                // notification rationale doesn't apply to paused
                // timers (their notification was cancelled on pause),
                // AND we want a paused timer to SURVIVE "Pause and
                // resume later" in `.paused` state so the user can
                // resume it on next Cook Mode entry. The orphan Live
                // Activity that paused timers would leak here is
                // handled by the `endAll` defensive sweep below; on
                // resume, `reconcileTimersOnForeground` re-creates
                // the Lock Screen surface for any still-paused timer.
                try await timerService.cancel(timer, on: session)
            } catch {
                Logger.ui.error("exit cancelTimer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Defense in depth: end every Live Activity still tracked
        // (paused-timer orphans the targeted loop intentionally
        // skipped, plus any class of leak we haven't enumerated —
        // dual-instance regressions, future state-machine additions,
        // a CookTimer row deleted out from under its activity).
        // Without this, the Lock Screen surface ticks past 00:00
        // for hours after the user leaves the meal. Idempotent:
        // entries the per-timer cancel above already ended are
        // removed from the manager's dict, so this is a no-op for
        // them. Paused-timer activities re-create on resume via
        // `reconcileTimersOnForeground`'s `!hasActivity` branch.
        await liveActivityManager.endAll(reason: .cancelled)
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

    /// Mark the cook session completed and request OutcomeFeedback.
    ///
    /// Synchronous part — observable test/UI contract:
    ///   - `cookingSessionRepository.markCompleted(session)` flips
    ///     `session.typedStatus`, sets `endedAt`, sticky-saves the recipe.
    ///   - `finishPresentationRequested = true` so CookModeRoot shows
    ///     OutcomeFeedback on the next render pass.
    ///
    /// Async tail (`performFinishAsyncTail`) — fire-and-forget side
    /// effects that don't gate the UI: timer + Live Activity teardown,
    /// voice driver close, audio-session deactivation, pantry auto-
    /// consume, telemetry, reactivation scheduling, intent donation.
    /// Order doesn't matter — none of the tail work reads
    /// `session.typedStatus` (SCA-48 / SCA-49).
    @discardableResult
    func finish() -> Task<Void, Never> {
        do {
            try cookingSessionRepository.markCompleted(session)
        } catch {
            Logger.ui.error("markCompleted failed: \(error.localizedDescription, privacy: .public)")
        }
        finishPresentationRequested = true
        // Task captures self for the duration of the tail. StepCardView
        // discards the returned Task; that's fine — the closure keeps
        // self alive until the tail returns, then releases it. No leak.
        return Task { await performFinishAsyncTail() }
    }

    private func performFinishAsyncTail() async {
        // Mark running AND paused timers complete + end their Live
        // Activities. Paused timers' Lock Screen surfaces stay alive
        // through pause (so the static "2:14" renders) — without
        // including .paused here, the user-paused-then-finished path
        // leaves the Live Activity ticking on the Lock Screen for hours.
        // Use timerService.markCompleted (not .cancel) so the Live
        // Activity ends with reason .completed — matches the "user
        // finished" semantic. exit(markAbandoned:) uses .cancel for
        // "user bailed".
        for timer in activeTimers
        where timer.typedState == .running || timer.typedState == .paused {
            do {
                try await timerService.markCompleted(timer, on: session)
            } catch {
                Logger.ui.error("finish markCompleted timer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Defense in depth: end any tracked Live Activity the targeted
        // loop didn't catch. Idempotent — already-ended activities are
        // no-ops. .completed semantic so the "Done" affordance lingers
        // briefly under the OutcomeFeedback sheet before dismissing.
        await liveActivityManager.endAll(reason: .completed)
        activeTimers = cookTimerRepository.timers(for: session)

        // Voice teardown — idempotent no-op when no driver. Mirrors
        // exit()'s ordering: cancelSpeaking waits for the state machine
        // to settle, close() tears down recognizer + synthesizer,
        // fireVoiceSessionCloseTrace seals the PostHog $ai_trace with
        // endedReason="session_finish", AVAudioSession deactivates last
        // so the system mic indicator drops before the outcome sheet
        // appears.
        await voiceDriver?.cancelSpeaking()
        voiceDriver?.close()
        fireVoiceSessionCloseTrace(endedReason: "session_finish")
        AVAudioSessionConfigurator.deactivate()

        // SCA-21 / ADR 0029: auto-consume pantry items reflecting the
        // recipe the user just cooked. Memory-state-aware rule lives
        // in `PantryItemRepository.consumeForRecipe`. Emit the
        // telemetry event unconditionally — even on an all-zeros
        // outcome — so the time-series stays continuous and a missing
        // emission flags a wiring regression. Failure to consume is
        // logged but not surfaced — the cook session is already
        // complete, and dropping the pantry mutation is strictly
        // less harmful than crashing or rolling back the completion.
        let consumeOutcome: PantryItemRepository.ConsumeOutcome
        do {
            consumeOutcome = try pantryItemRepository.consumeForRecipe(
                recipePlan,
                substitutions: session.substitutionArray,
                on: household,
            )
        } catch {
            Logger.coreData.error("pantry consumeForRecipe failed: \(error.localizedDescription, privacy: .private)")
            consumeOutcome = PantryItemRepository.ConsumeOutcome(
                ephemeralDeleted: [],
                rememberedBumped: [],
                unmatched: 0,
                optionalSkipped: 0,
                substitutedCount: 0,
            )
        }
        analytics.capture(.pantryAutoConsumeResolved, properties: consumeOutcome.telemetryProperties)
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
    }

    /// Teardown hook for `CookModeRoot.onDisappear`. Ends every Live
    /// Activity the manager still tracks. The user-flow paths
    /// (`exit(markAbandoned:)` and `performFinishAsyncTail`) already end
    /// activities through their targeted timer-cancel loops AND the
    /// `endAll` defense-in-depth call there, so this is a no-op in the
    /// happy path. The guarantee is for paths that dismiss Cook Mode
    /// WITHOUT going through exit/finish — programmatic
    /// `coordinator.dismissCookMode()` from a deep link, the parent
    /// view rebuilding the cover, or any future path that nils
    /// `activeCookLaunch` directly. Without this hook, a stale Lock
    /// Screen surface keeps ticking past 00:00 until the system's ~8h
    /// cap removes it. Idempotent: each `end(timerId:reason:)` removes
    /// the entry from the manager's dict, so a follow-up call after
    /// exit/finish is a safe no-op.
    func teardownLiveActivitiesOnDismiss() async {
        await liveActivityManager.endAll(reason: .cancelled)
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
            emitVoiceAffordance(tier: tier, result: .paywallShown)
            presentPaywall?(.voiceAffordanceTapped)
            return
        case .blockedByQuota:
            // Premium+ who's hit the monthly voice cap — Pro-upsell
            // paywall, not the generic trial one.
            emitVoiceAffordance(tier: tier, result: .paywallShown)
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
                isVoiceUIRequested = false
                await closeVoiceSession()
                emitVoiceAffordance(tier: tier, result: .voiceStopped)
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
                isVoiceUIRequested = false
                await closeVoiceSession()
                emitVoiceAffordance(tier: tier, result: .voiceStopped)
                return
            }
        }

        // Engage path — user is starting (or re-starting) voice mode.
        // Flip the UI flag SYNCHRONOUSLY before any await so SwiftUI
        // re-renders into the voice-active chrome on the same frame
        // as the tap, rather than after preWarm/connect resolves a
        // few seconds later. The flag stays true through .connecting
        // → .ready → .userSpeaking; isVoiceActive remains false only
        // if the underlying state hits a terminal value.
        isVoiceUIRequested = true

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
            // Synchronously transition voiceState to .connecting so
            // `isVoiceActive` flips true on the same frame as the tap
            // and the voice chrome appears immediately. Without this,
            // voiceState lingers at `.closed` (set by the prior
            // closeVoiceSession at line 1719) and chrome stays in
            // tap-mode for the entire 2-3 s preWarm window. Mirrors
            // the first-tap UX where preWarm finished at Cook Mode
            // entry. The post-rebuild `attachVoiceDriver` overwrite
            // goes `.connecting → .ready` (both active) on success;
            // on dual Live+C.3 preWarm failure the new driver is
            // returned in `.idle` (CookModeRoot.tryC3Fallback catch
            // arm) and chrome reverts before the toast — informative,
            // not a flicker. Synthetic write deliberately bypasses
            // `applyDriverStateChange` (no `voice_state_transition`
            // telemetry emitted for the synthetic .closed → .connecting
            // jump — matches the synthetic `voiceState = .thinking`
            // pattern at line 1110). Fixed: 2026-04-28.
            voiceState = .connecting

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
        //
        // On ANY failure, drop `isVoiceUIRequested` so the chrome
        // reverts to tap-mode and the user sees the "Ask with voice"
        // button to retry. Without this clear, `voiceState` stays at
        // its pre-tap value (typically `.ready` from preWarm) AND
        // `isVoiceUIRequested` stays true → `isVoiceActive` stays true
        // → voice chrome stays on screen with the listening pill
        // showing "Tap to talk" but no working session behind it
        // (regression observed during 2026-04-27 review). Tracked via
        // `voiceBeginSucceeded` + `defer` so future catch arms that
        // don't fall through this method (e.g., a new typed error)
        // can't accidentally bypass the cleanup.
        var voiceBeginSucceeded = false
        defer {
            if !voiceBeginSucceeded {
                isVoiceUIRequested = false
            }
        }
        do {
            try await beginVoiceTurnInner()
            hasBegunFirstTurn = true
            voiceBeginSucceeded = true
            emitVoiceAffordance(tier: tier, result: .voiceStarted)
        } catch SpeechFallbackError.permissionDenied {
            emitVoiceAffordance(tier: tier, result: .permissionDenied)
            showVoiceError(
                message: "Microphone access is off. You can keep cooking with taps, or turn on the mic in Settings.",
                errorCode: "PERM-MIC-01",
                screen: "cook_mode_voice_begin",
            )
        } catch SpeechFallbackError.recognizerUnavailable {
            emitVoiceAffordance(tier: tier, result: .permissionDenied)
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
            let presented = await presentStirError(error, screen: "cook_mode_voice_begin")
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
        // And clear the transcript card content. Carrying a previous
        // session's "YOU SAID / STIR" exchange into a fresh attach
        // would mislead the user about what they just said — better
        // to start the new session with an empty card.
        self.lastUserTranscript = nil
        self.lastModelTranscript = nil
        // Detach with `driver == nil` → no possibility of a live voice
        // session. Drop the UI-intent flag so the chrome reverts to
        // tap-mode immediately. New attach after this (rebuild path)
        // doesn't auto-flip back true — the user must tap "Ask with
        // voice" again to re-engage, which is the intended UX for any
        // post-close re-entry.
        if driver == nil {
            self.isVoiceUIRequested = false
        }
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
    ///
    /// VM-side shim: builds the $ai_input_state dict from VM-owned data
    /// (session.id, recipePlan.id, currentStepIndex, driver.pathLabel,
    /// driver.voiceSessionPromptVersion) and hands the assembled bag plus
    /// the driver's voiceSessionID off to `voiceTelemetry.seedTrace`. The
    /// telemetry helper owns the storage + idempotence guard + reseed-
    /// over-live-trace error log; the VM owns the data shape.
    private func seedVoiceSessionTrace(from driver: any VoiceSessionDriver) {
        guard let sid = driver.voiceSessionID else { return }
        voiceTelemetry.seedTrace(
            sessionID: sid,
            cookingSessionID: session.id,
            recipePlanID: recipePlan.id,
            currentStepNumber: currentStepIndex + 1,
            pathLabel: driver.pathLabel.rawValue,
            promptVersion: driver.voiceSessionPromptVersion,
        )
    }

    /// Called by CookModeRoot's `onTurnTranscriptFinalized` wiring on
    /// every RealtimeSession `turnComplete` that produced any non-empty
    /// text. Updates the YOU SAID / STIR transcript card with the most
    /// recent exchange. Either field of `snapshot` may be empty (tool-
    /// call-only turns produce no model text; very short utterances
    /// may produce no user transcription).
    ///
    /// SCA-49 — asymmetric blank rule, four-branch contract:
    ///
    ///   1. Both halves non-empty (normal turn) → both populate.
    ///   2. Only userText non-empty (tool-call-only turn) → userText
    ///      populates AND the prior modelText is BLANKED. Pairing a
    ///      fresh "YOU SAID" with the stale STIR reply that was
    ///      addressed to the PRIOR question reads as "Stir replied to
    ///      my latest utterance with this old answer", which is worse
    ///      than a brief blank during the tool round-trip. The post-
    ///      tool model reply lands on the FOLLOWING `turnComplete`
    ///      (after the toolResponse) and falls into branch 3.
    ///   3. Only modelText non-empty (the post-tool reply, or rare
    ///      proactive narration) → modelText populates without
    ///      disturbing prior userText.
    ///   4. Both halves empty (contract violation by the caller —
    ///      `onTurnTranscriptFinalized` is documented to fire only on
    ///      `turnComplete` events that produced any non-empty text)
    ///      → userText preserved (guarded), modelText blanked. Defensive
    ///      and rare; consequence is a brief STIR blank on the card,
    ///      which is the same failure mode as branch 2.
    func recordTurnTranscript(_ snapshot: LiveTurnTranscript) {
        if !snapshot.userText.isEmpty {
            lastUserTranscript = snapshot.userText
        }
        // Tool-call-only turns send modelText="" because the model called
        // a function instead of speaking. Don't preserve the prior turn's
        // reply — pairing the OLD reply with the NEW user input reads as
        // "Stir said this in response to my latest utterance" (SCA-48).
        // userText keeps its preserve-on-empty guard above (model-only
        // proactive-narration turns are rare but valid).
        lastModelTranscript = snapshot.modelText.isEmpty ? nil : snapshot.modelText
    }

    /// SCA-80 forwarder. Per-turn context (step, path, barge-in flag)
    /// is owned by the VM; canonical accumulator + emit logic lives on
    /// `VoiceSessionTelemetry.recordLiveTurnSummary`.
    func recordLiveTurnSummary(_ summary: LiveTurnSummary) {
        voiceTelemetry.recordLiveTurnSummary(
            summary,
            currentStepIndex: currentStepIndex,
            consumeBargeInFlag: { [self] in consumeBargeInFlag() },
        )
    }

    /// SCA-80 forwarder for spec §15 `voice_session_refreshed`.
    func recordVoiceSessionRefresh(
        reason: String,
        turnsAtRefresh: Int,
        sessionID: String,
        success: Bool,
    ) {
        voiceTelemetry.recordVoiceSessionRefresh(
            reason: reason,
            turnsAtRefresh: turnsAtRefresh,
            sessionID: sessionID,
            success: success,
        )
    }

    /// SCA-80 forwarder for `voice_turn_stuck_watchdog_fired`.
    func recordVoiceTurnStuckWatchdogFired(
        sessionID: String,
        turnIndex: Int,
        toolCallType: String?,
        elapsedStuckMs: Int,
        turnLengthAtStuck: Int,
    ) {
        voiceTelemetry.recordVoiceTurnStuckWatchdogFired(
            sessionID: sessionID,
            turnIndex: turnIndex,
            toolCallType: toolCallType,
            elapsedStuckMs: elapsedStuckMs,
            turnLengthAtStuck: turnLengthAtStuck,
        )
    }

    /// SCA-80 forwarder for the voice-path `substitution_requested`.
    func emitVoiceSubstitutionRequested(subEventID: String) {
        voiceTelemetry.emitVoiceSubstitutionRequested(subEventID: subEventID)
    }

    /// SCA-80 forwarder for the voice-path `substitution_accepted`.
    func emitVoiceSubstitutionResolved(constraintSafe: Bool, subEventID: String) {
        voiceTelemetry.emitVoiceSubstitutionResolved(
            constraintSafe: constraintSafe,
            subEventID: subEventID,
        )
    }

    /// Persists + applies a voice-driven substitution to the recipe.
    /// Wired by `CookModeRoot` from
    /// `RealtimeSession.onSubstitutionAppliedFromVoice`. Without this,
    /// voice substitutions are auto-applied at the model-narration level
    /// but invisible to every downstream consumer (substitution picker,
    /// next voice turn's `remainingIngredients`, grocery export). Same
    /// root cause + fix shape as the sheet's `accept()`.
    ///
    /// Resolution rules:
    ///   - exact case-insensitive displayName match → picker-style FK
    ///     event (mutates that RecipeIngredient via applyAcceptedSwap)
    ///   - substring containment in either direction (handles
    ///     "pasta" ↔ "dried pasta") → picker-style FK event
    ///   - no match (e.g. user said "I'm out of cilantro" but cilantro
    ///     isn't in the recipe) → free-text event (no FK, no recipe
    ///     mutation; the SubstitutionEvent itself captures the swap)
    ///
    /// Step instruction text is intentionally NOT auto-rewritten —
    /// matches the sheet path's deliberate scope decision; future
    /// `StepCardView` swap-badge surfaces the change without an AI
    /// rewrite.
    func applyVoiceSubstitution(
        subEventID: UUID,
        missingIngredient: String,
        substitutionText: String,
        amountConversion: String?,
    ) {
        let trimmedMissing = missingIngredient.trimmingCharacters(in: .whitespaces)
        guard !trimmedMissing.isEmpty, !substitutionText.isEmpty else { return }

        // SCA-148: same-length tie → safe-path fallback. Until we ship
        // mid-turn user prompting (Owner-step "as triggered" — needs
        // RealtimeSession state-machine work + a 5s response window),
        // we route ambiguous matches to the free-text persistence path:
        // SubstitutionEvent records the swap WITHOUT mutating any
        // RecipeIngredient row. The model's narration already informed
        // the user of the swap; the cost is that downstream consumers
        // (next voice turn's `remainingIngredients`, grocery export)
        // see the original recipe state for that row. Acceptable
        // because this code path was previously picking the WRONG
        // row arbitrarily — free-text under-specifies, but doesn't
        // mis-mutate.
        //
        // Telemetry: emit `voice_substitution_disambiguated` so we
        // can measure how often this path fires before deciding
        // whether to build the prompt UX (≥1% of voice subs is the
        // ticket's documented trigger).
        let matched: RecipeIngredient?
        switch matchIngredient(named: trimmedMissing) {
        case .exact(let row):
            matched = row
        case .substring(let row, _):
            matched = row
        case .tie(let candidates):
            matched = nil
            voiceTelemetry.recordSubstitutionDisambiguated(
                sessionID: session.id,
                candidateCount: candidates.count,
                surface: .voice,
                resolvedTo: .freeTextFallback,
            )
        case .none:
            matched = nil
        }
        let stepForEvent = recipePlan.stepArray.first { Int($0.stepNumber) == currentStepIndex + 1 }

        // CA1-C1 fix: split into 3 independent do/catch blocks matching the
        // sheet path's two-phase contract (SubstitutionSheetViewModel.accept).
        // The previous single do/catch let a `recordDecision` save-failure
        // skip `applyAcceptedSwap` while leaving a persisted `.pending`
        // SubstitutionEvent in the DB — three-way state divergence (model
        // narrated the swap, recipe unmutated, funnel missing accepted).
        // Order is unchanged (persist → record → apply) so partial-success
        // states are still preserved on save failure: persist alone leaves
        // a `.pending` event for telemetry; persist+record but no apply
        // leaves the recorded accept=true with a recipe that didn't
        // mutate (the StepCardView swap badge will be missing — operator
        // can recover via the picker).
        let event: SubstitutionEvent
        do {
            event = try substitutionRepository.persist(SubstitutionRepository.PersistInput(
                subEventId: subEventID,
                session: session,
                ingredient: matched,
                freeTextName: matched == nil ? trimmedMissing : nil,
                step: stepForEvent,
                userProblemText: "Voice: out of \(trimmedMissing)",
                modelSuggestionText: substitutionText,
                hardConstraintCheckPassed: true,
            ))
        } catch {
            Logger.coreData.error(
                "voice substitution persist failed: \(error.localizedDescription, privacy: .public)",
            )
            return
        }

        do {
            try substitutionRepository.recordDecision(
                event,
                accepted: true,
                acceptedAlternativeText: substitutionText,
            )
        } catch {
            Logger.coreData.error(
                "voice substitution recordDecision failed (event persisted as .pending): \(error.localizedDescription, privacy: .public)",
            )
            // Don't apply the swap if we couldn't record the decision —
            // mismatch between recorded state and recipe is worse than
            // a recipe that didn't mutate.
            return
        }

        do {
            try substitutionRepository.applyAcceptedSwap(
                event,
                substitutionText: substitutionText,
                amountConversion: amountConversion,
            )
        } catch {
            Logger.coreData.error(
                "voice substitution applyAcceptedSwap failed (decision recorded, recipe unmutated): \(error.localizedDescription, privacy: .public)",
            )
        }
    }

    /// SCA-148: outcome of a voice-side ingredient match. Distinguishes
    /// the three cases the caller needs to act on differently:
    /// - `.exact(row)` / `.substring(row, candidateCount: 1)` — single
    ///   confident winner, mutate the recipe row.
    /// - `.substring(row, candidateCount: N>1)` — single longest-length
    ///   winner among multiple substring matches; safe to mutate
    ///   (CA1-H2 longest-match preference covers this case).
    /// - `.tie(rows)` — multiple substring candidates share the SAME
    ///   longest length (e.g. "ric" vs "rice" + "rind" — equal-length).
    ///   The CA1-H2 longest-match preference can't disambiguate, and
    ///   the prior code arbitrarily picked one via `max(by:)`'s stable
    ///   ordering. Voice-side caller now falls back to the free-text
    ///   path (no FK mutation) and emits `voice_substitution_disambiguated`
    ///   so we can MEASURE how often this path fires before investing
    ///   in mid-turn user-prompt UX.
    /// - `.none` — no match; free-text path.
    private enum IngredientMatchResult {
        case exact(RecipeIngredient)
        case substring(RecipeIngredient, candidateCount: Int)
        case tie([RecipeIngredient])
        case none
    }

    /// Case-insensitive match from a model-supplied missing-ingredient
    /// string back to a row in the recipe. Exact-equal first, then
    /// bidirectional substring containment with longest-match preference
    /// (CA1-H2 fix) so "rice" against a recipe with both "white rice"
    /// and "rice noodles" picks the candidate whose displayName length
    /// is largest — Core-Data row order no longer decides which
    /// ingredient gets swapped.
    ///
    /// SCA-148 promoted the return shape from `RecipeIngredient?` to
    /// `IngredientMatchResult` so the caller can distinguish a confident
    /// substring winner from a same-length tie. The tie case (≥2
    /// candidates with the same longest displayName length) used to
    /// silently pick whichever Core-Data row Swift's stable `max(by:)`
    /// handed back; the new caller treats ties as ambiguous and routes
    /// to the safe path.
    ///
    /// SCA-201 (/review-2 S3): both `matchIngredient` and the
    /// `IngredientMatchResult` enum it returns are `private` — they're
    /// CookModeViewModel implementation details. Tests assert via the
    /// observable post-state of `applyVoiceSubstitution` (recipe row
    /// mutation, SubstitutionEvent persistence, telemetry emission),
    /// not via direct match-result inspection. If a future test needs
    /// direct inspection, prefer adding a thin assertion helper rather
    /// than relaxing access — keeping the matcher private blocks the
    /// SCA-204 empty-string footgun from leaking to callers.
    private func matchIngredient(named query: String) -> IngredientMatchResult {
        let q = query.lowercased()
        // SCA-204 (/review-2 S6): defensive empty-string guard.
        // `applyVoiceSubstitution` already upstream-guards via
        // `trimmedMissing.isEmpty`, but if a future caller skips the
        // upstream guard, `name.contains("")` would return true for
        // every non-empty ingredient name — every ingredient would
        // qualify as a substring match, ties would form on the longest
        // single name length, and the result would be a non-empty
        // `.tie([…])` of all the longest ingredients. SCA-201 made
        // this method `private` so the realistic blast radius is
        // small, but the guard is one line and removes the footgun
        // class entirely.
        guard !q.isEmpty else { return .none }
        let candidates = recipePlan.ingredientArray
        if let exact = candidates.first(where: {
            ($0.displayName ?? "").caseInsensitiveCompare(query) == .orderedSame
        }) {
            return .exact(exact)
        }
        let containmentMatches = candidates.compactMap { ing -> (RecipeIngredient, String)? in
            let name = (ing.displayName ?? "").lowercased()
            guard !name.isEmpty else { return nil }
            guard name.contains(q) || q.contains(name) else { return nil }
            return (ing, name)
        }
        guard !containmentMatches.isEmpty else { return .none }
        // SCA-148: detect same-length ties at the LONGEST length. The
        // CA1-H2 longest-match preference is robust against
        // "rice" vs "white rice" + "rice noodles" (10 vs 12); it
        // collapses on "ric" vs "rice" + "rind" (both 4). Tie ⇒ caller
        // disambiguates; otherwise the longest single match wins.
        let maxLen = containmentMatches.map { $0.1.count }.max() ?? 0
        let winners = containmentMatches.filter { $0.1.count == maxLen }
        if winners.count == 1 {
            return .substring(winners[0].0, candidateCount: containmentMatches.count)
        }
        return .tie(winners.map { $0.0 })
    }

    /// SCA-80 forwarder for the close-summary $ai_trace (ADR 0009).
    /// endedReason: "user_exit" | "user_stop" | "user_pause" |
    /// "session_finish" | "error".
    private func fireVoiceSessionCloseTrace(endedReason: String) {
        voiceTelemetry.fireCloseTrace(endedReason: endedReason)
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
    /// Public end-voice entry for the voice-active UI's listening
    /// pill. ALWAYS closes the session regardless of current state —
    /// distinct from `handleMicTap`'s nuanced submit-turn-early /
    /// start-session branching. The voice-active chrome's only pill
    /// affordance is "exit voice mode"; routing it through
    /// `handleMicTap` would surface the legacy `.submit` branch (mid-
    /// utterance → submit turn → state goes to `.thinking`), leaving
    /// the user trapped in the voice UI watching a "thinking" pill
    /// instead of returning to tap-mode. Observed 2026-04-27.
    ///
    /// Synchronous flag flip first so the chrome reverts on the same
    /// frame as the tap; the async close runs while tap-mode is
    /// already on screen.
    func endVoiceMode() async {
        // Capture whether a real session is being torn down BEFORE
        // we touch state, so the telemetry guard below reflects the
        // user's tap landing on a live voice session vs a stuck
        // chrome (no driver attached). The pill is only visible when
        // `isVoiceActive` is true → in normal flow `voiceDriver` is
        // populated, but defensive: don't fire `voice_stopped` for a
        // session that never existed.
        let hadActiveSession = voiceDriver != nil
        let tier = entitlements?.tier ?? .free
        // Capture barge-in for the imminent close-trace turn record:
        // tapping during model speech is a polished interruption
        // signal, distinct from giving up on `.thinking` / `.refreshing`.
        if voiceState == .modelSpeaking {
            currentTurnBargedIn = true
        }
        isVoiceUIRequested = false
        // Cancel any in-flight rebuild — user no longer wants voice,
        // so the eventual driver attach would orphan a freshly-minted
        // ephemeral session. CookModeRoot's rebuild closure checks
        // `Task.isCancelled` after preWarm and tears down the
        // partially-wired driver (CookModeRoot.swift:331-334), then
        // returns nil. The subsequent `attachVoiceDriver(nil)` writes
        // voiceState = .closed cleanly. Pre-existing wasted-mint
        // window before the cancellation point lands (preWarm doesn't
        // honor cooperative cancellation through the WS handshake) is
        // unchanged by this — but at least avoids the post-attach
        // orphan. Added: 2026-04-28.
        rebuildDriverTask?.cancel()
        await closeVoiceSession()
        if hadActiveSession {
            emitVoiceAffordance(tier: tier, result: .voiceStopped)
        }
    }

    /// Idempotent: safe to call with no active driver (guard early).
    /// Callers:
    ///   - `handleMicTap`'s `.listening` / `.busy` end-branches (user
    ///     taps mic in tap-mode while a session is live).
    ///   - `endVoiceMode` (user taps the voice-active pill).
    ///   - `exit(markAbandoned:)` and `finish()` (Cook Mode lifecycle
    ///     teardown).
    ///   - Refresh-failure paths in `RealtimeSession` callbacks.
    /// CookModeRoot's `.onDisappear` uses `driver.close()` directly
    /// because it doesn't need the VM-side state cleanup.
    ///
    /// `isVoiceUIRequested` is cleared inside this method as a
    /// defensive net for the lifecycle paths (`exit` / `finish` /
    /// refresh failure) that don't clear it before calling. The
    /// explicit user-tap paths clear it synchronously beforehand so
    /// SwiftUI re-renders into tap-mode chrome on the same frame as
    /// the tap, before any `await` in this method suspends.
    /// SCA-57: host-callable wrapper around the private
    /// `closeVoiceSession()` so `CookModeRoot.handlePostSubmit` can
    /// release the voice driver the moment cooking finishes — before
    /// the user spends 60-180s in LeftoversRoot's prompt + solve. The
    /// underlying `closeVoiceSession` is idempotent (guards on `let
    /// driver = voiceDriver else { return }`); calling this when no
    /// driver is active is a no-op. `driverTeardown?()` on
    /// `CookModeRoot.onDisappear` continues to run as defense-in-depth
    /// — `Driver.close()` is documented idempotent within the driver
    /// and the `voiceDriver = nil` after the early call makes the
    /// late teardown's closure body a no-op.
    func closeVoiceSessionFromHost() async {
        await closeVoiceSession()
    }

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
        // Drop the visible transcript so the next "Ask with voice" tap
        // opens to a clean card. Mirrors the `attachVoiceDriver` clear
        // — same reasoning (carrying prior content forward misleads).
        lastUserTranscript = nil
        lastModelTranscript = nil
        // Drop the UI-intent flag too. Defensive — explicit close
        // paths (handleMicTap's `.listening`/`.busy` branches and
        // `endVoiceMode`) clear it before they reach this
        // method so the synchronous flip happens before any await,
        // but cleanup paths (exit, error, refresh-failure) reach
        // `closeVoiceSession` directly and must also revert the UI.
        isVoiceUIRequested = false
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
            let presented = await presentStirError(error, screen: "cook_mode_voice_end")
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

    /// SCA-80 forwarder. Consumes `currentTurnBargedIn` (read+reset) so
    /// the next turn starts clean; emit logic lives on the helper.
    private func emitCookTurnResolved(
        submittedAt: Date,
        pathLabel: String,
        resultType: String,
        latencyTtfaMs: Int,
        errorCode: ErrorCode? = nil,
    ) {
        voiceTelemetry.emitCookTurnResolved(
            submittedAt: submittedAt,
            pathLabel: pathLabel,
            resultType: resultType,
            latencyTtfaMs: latencyTtfaMs,
            errorCode: errorCode,
            bargedIn: consumeBargeInFlag(),
        )
    }

    /// Read + reset `currentTurnBargedIn` for the imminent
    /// cook_turn_resolved emission. The flag is set in handleMicTap /
    /// endVoiceMode when the user interrupts during `.modelSpeaking`;
    /// resetting after each emit preserves the spec §15 line 1695
    /// "this turn began by interrupting the previous turn's playback"
    /// semantic.
    private func consumeBargeInFlag() -> Bool {
        let bargedIn = currentTurnBargedIn
        currentTurnBargedIn = false
        return bargedIn
    }

    // MARK: - Voice error presentation

    /// Map typed StirErrors to the appropriate UX (toast + optional
    /// paywall hand-off) so voice errors land consistently with the
    /// rest of the app instead of getting swallowed by a generic catch.
    /// Returns true if the error was handled; false if the caller
    /// should fall through to a generic toast.
    private func presentStirError(_ error: any Error, screen: String) async -> Bool {
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
            emitVoiceAffordance(tier: entitlements?.tier ?? .free, result: .paywallShown)
            // P0-J (2026-04-23): close the live voice session BEFORE
            // presenting the paywall. Mid-cook paywall triggers land
            // while the WebSocket + mic + audio engine are live; if we
            // just flip the paywall state, the audio keeps billing to
            // Gemini behind the sheet (observed review finding CA2-H1).
            // closeVoiceSession is idempotent and no-ops when no driver.
            await closeVoiceSession()
            presentPaywall?(.voiceCookQuotaExhausted)
            return true
        case .entitlementRequired(let code, _) where code == .entVoice01:
            // Entitlement slipped mid-session (RC webhook lag, grace
            // period expired during a running cook). Route to upgrade
            // paywall rather than a generic toast. Close the live
            // session first (see P0-J comment above).
            await closeVoiceSession()
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
        emitScreenError(screen: screen, errorCode: errorCode)
    }

    /// SCA-80 forwarder for spec §15 `screen_error_shown`.
    private func emitScreenError(screen: String, errorCode: String) {
        voiceTelemetry.emitScreenError(screen: screen, errorCode: errorCode)
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
        // P2-I (2026-04-23): routed through `HouseholdProfile.voiceContextSnapshot()`
        // shared seam. Filter rules are the canonical
        // `deletedAt == nil && userConfirmed && !displayName.isEmpty`
        // set regardless of caller; prior inline projections had drift
        // (substitution accepted unconfirmed items).
        return RealtimeHouseholdContext(snapshot: household.voiceContextSnapshot())
    }

    /// SCA-80 forwarder for spec §15 `voice_affordance_tapped`.
    private func emitVoiceAffordance(tier: Tier, result: VoiceAffordanceResult) {
        voiceTelemetry.emitVoiceAffordance(tier: tier, result: result)
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

    /// Test-only hook for flipping the user-intent UI flag without
    /// going through `handleMicTap`'s full driver setup path. Pairs
    /// with `_testForceVoiceState` so unit tests of `isVoiceActive`
    /// can pin both signals independently.
    func _testForceVoiceUIRequested(_ requested: Bool) {
        isVoiceUIRequested = requested
    }

    /// Test-only hook for flipping the first-turn flag. Drives the
    /// pre-first-turn vs between-turns split on `.ready` that
    /// `micButtonRole` uses. Production code flips this via
    /// `handleMicTap`'s success path / reset sites only.
    func _testForceHasBegunFirstTurn(_ value: Bool) {
        hasBegunFirstTurn = value
    }

    /// Test-only hooks for the SCA-80 barge-in flag lifecycle. Pin the
    /// invariant that `currentTurnBargedIn` is only consumed when an
    /// emission actually fires — a late `turnComplete` frame arriving
    /// after `fireCloseTrace` ran must NOT clear the flag.
    func _testSetCurrentTurnBargedIn(_ value: Bool) {
        currentTurnBargedIn = value
    }
    func _testGetCurrentTurnBargedIn() -> Bool {
        currentTurnBargedIn
    }
    #endif
}
