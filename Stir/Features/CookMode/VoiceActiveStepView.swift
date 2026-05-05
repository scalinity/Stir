// VoiceActiveStepView
//
// The voice-mode chrome for Cook Mode. Replaces StepCardView's
// tap-mode body whenever `viewModel.isVoiceActive` is true (i.e., a
// Live or Speech-fallback voice session is connecting / ready /
// userSpeaking / thinking / modelSpeaking / etc.). Returns to the
// tap-mode body the instant the session terminates (.idle / .closed
// / .error).
//
// Layout (matches Daniel's 2026-04-25 voice-mode mockup):
//   - Top bar:
//       X close (left, 36×36 paper200 rounded square)
//       VOICE · PREMIUM pill (center, voice100 bg + voice600 ink)
//       "N / total" step counter (right, ink500 plain text)
//   - STEP N small-caps eyebrow (voice600)
//   - Recipe instruction text (displayMd, ink900, serif)
//   - YOU SAID / STIR transcript card (only when transcript present)
//   - Listening pill (state-driven label + animated waveform)
//
// No bottom navigation row. Voice handles "next" / "back" via the
// model's `advance_step` / `set_step` tools; the user's only escape
// hatch is the X close button. If voice is unrecoverable (driver
// nilled, fallback pinned), the chrome reverts to tap-mode and the
// existing Previous/Next buttons return.
//
// Wave motion is state-driven (no real audio metering) so it stays
// responsive even when the iOS audio engine is muted by the model
// playback path. See `WaveformView` below — 7 vertical bars with
// staggered sine-driven y-scale, identical to the design mockup's
// `vbar` keyframe animation. Bars rest flat (.4 scale) on
// non-active states and animate up to 1.0 on active states.

import SwiftUI

struct VoiceActiveStepView: View {
    @Bindable var viewModel: CookModeViewModel

    @Environment(\.coachMarks) private var coachMarks

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    stepEyebrow
                    instructionBody
                    if showTranscriptCard {
                        transcriptCard
                    }
                }
                .padding(.horizontal, CGFloat.Stir.screenMarginHero)
                .padding(.top, CGFloat.Stir.space4)
                // 120pt bottom clearance so the listening pill (mounted
                // via safeAreaInset) doesn't visually clip the
                // transcript card on small phones (iPhone 13 mini /
                // iPhone SE 3 height). Bumped implicitly for the timer
                // pill via safeAreaInset auto-extension when active.
                .padding(.bottom, 120)
            }
        }
        .background(Color.Stir.paper50.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: CGFloat.Stir.space2) {
                activeTimerPill
                listeningPill
            }
            .padding(.horizontal, CGFloat.Stir.space4)
            .padding(.bottom, CGFloat.Stir.space3)
            .padding(.top, CGFloat.Stir.space2)
        }
        .confirmationDialog(
            "Leave Cook Mode?",
            isPresented: $viewModel.exitConfirmRequested,
            titleVisibility: .visible,
        ) {
            Button("Keep cooking", role: .cancel) {}
            Button("Pause and resume later") {
                Task { await viewModel.exit(markAbandoned: false) }
            }
            Button("Abandon session", role: .destructive) {
                Task { await viewModel.exit(markAbandoned: true) }
            }
        } message: {
            Text("Your progress is saved. You can resume from Tonight Home.")
        }
    }

    // MARK: - Active timer pill (model-driven start_timer surface)

    /// Picks the most-relevant active timer for the current step. Voice
    /// chrome only surfaces running / paused timers — completed and
    /// cancelled stay hidden so the pill doesn't linger after a tool
    /// call ends a timer.
    private var activeTimerForCurrentStep: CookTimer? {
        guard let stepId = viewModel.currentStep?.id else { return nil }
        return viewModel.activeTimers.first {
            $0.step?.id == stepId
            && ($0.typedState == .running || $0.typedState == .paused)
        }
    }

    /// Compact countdown affordance shown above the listening pill while
    /// a timer for the current step is running or paused. Without this,
    /// `start_timer` voice tool calls produced an invisible state change
    /// — the timer fired and showed up in tap mode but was completely
    /// hidden inside the voice chrome (observed device-side 2026-05-03).
    /// Reading `viewModel.timerStateVersion` registers this view as a
    /// dependent of @Observable invalidation on every timer mutation;
    /// NSManagedObject property changes on CookTimer don't propagate
    /// through @Observable on their own.
    @ViewBuilder
    private var activeTimerPill: some View {
        let _ = viewModel.timerStateVersion
        if let timer = activeTimerForCurrentStep {
            VoiceTimerPill(
                timer: timer,
                pauseStartedAt: viewModel.pauseStartedAt(for: timer),
                onPauseResume: {
                    Task {
                        if timer.typedState == .running {
                            await viewModel.pauseTimer(timer)
                        } else if timer.typedState == .paused {
                            await viewModel.resumeTimer(timer)
                        }
                    }
                },
                onCancel: {
                    Task { await viewModel.cancelTimer(timer) }
                },
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: CGFloat.Stir.space2) {
            Button {
                viewModel.requestExitConfirm()
            } label: {
                Image.Stir.close
                    .stirFont(.labelMd).fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink700)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                            .fill(Color.Stir.paper200),
                    )
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Exit Cook Mode")
            .coachMarkAnchor(.voiceExitButton)
            .frame(maxWidth: .infinity, alignment: .leading)

            voicePremiumPill
                .layoutPriority(1)

            // Step counter "N / total" — mirrored width via leading-spacer
            // pattern keeps the pill centered against the X button on
            // the left without a third reserved slot. Aligned trailing.
            Text("\(viewModel.currentStepIndex + 1) / \(viewModel.totalSteps)")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Step \(viewModel.currentStepIndex + 1) of \(viewModel.totalSteps)")
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space2)
    }

    private var voicePremiumPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .stirFont(.labelMicroEyebrow)
                .foregroundStyle(Color.Stir.voice600)
            Text("Voice")
                .stirFont(.labelMicroEyebrow)
                .foregroundStyle(Color.Stir.voice600)
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.Stir.voice100),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice mode")
    }

    // MARK: - Body content

    private var stepEyebrow: some View {
        Text("Step \(viewModel.currentStepIndex + 1)")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.voice600)
    }

    private var instructionBody: some View {
        Text(viewModel.currentStep?.instructionText ?? "")
            .stirFont(.displayMd)
            .foregroundStyle(Color.Stir.ink900)
            .lineSpacing(6)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Transcript card

    /// Render the YOU SAID / STIR card only when at least one side
    /// has content. Pre-first-turn (both nil) the card is hidden so
    /// the user's first impression of voice mode is just the
    /// instruction + listening pill — mirrors the mockup's "fresh
    /// session" state implicitly.
    private var showTranscriptCard: Bool {
        let hasUser = !(viewModel.lastUserTranscript ?? "").isEmpty
        let hasModel = !(viewModel.lastModelTranscript ?? "").isEmpty
        return hasUser || hasModel
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2Half) {
            if let userText = viewModel.lastUserTranscript, !userText.isEmpty {
                transcriptBlock(label: "You said", text: userText, isModel: false)
            }
            if viewModel.lastUserTranscript?.isEmpty == false &&
                viewModel.lastModelTranscript?.isEmpty == false {
                Rectangle()
                    .fill(Color.Stir.voice600.opacity(0.2))
                    .frame(height: 1)
                    .padding(.vertical, 2)
            }
            if let modelText = viewModel.lastModelTranscript, !modelText.isEmpty {
                transcriptBlock(label: "Stir", text: modelText, isModel: true)
            }
        }
        .padding(CGFloat.Stir.space4)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusAccent, style: .continuous)
                .fill(Color.Stir.voice100.opacity(0.4)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusAccent, style: .continuous)
                .strokeBorder(Color.Stir.voice600, lineWidth: 1),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            let user = viewModel.lastUserTranscript ?? ""
            let model = viewModel.lastModelTranscript ?? ""
            if !user.isEmpty && !model.isEmpty {
                return "You said: \(user). Stir replied: \(model)"
            } else if !user.isEmpty {
                return "You said: \(user)"
            } else {
                return "Stir said: \(model)"
            }
        }())
    }

    @ViewBuilder
    private func transcriptBlock(label: String, text: String, isModel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .stirFont(.labelMicroEyebrow)
                .foregroundStyle(Color.Stir.voice600)
            Text(text)
                .stirFont(isModel ? .bodyMd : .displaySm)
                .foregroundStyle(isModel ? Color.Stir.ink700 : Color.Stir.ink900)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Listening pill

    private var listeningPill: some View {
        Button {
            // Voice-active chrome's only pill action is "exit voice
            // mode" — route through `endVoiceMode` rather than
            // `handleMicTap` so we always close fully and revert to
            // tap-mode. `handleMicTap`'s `.submit` branch (active when
            // state is `.userSpeaking`) would otherwise submit the
            // turn early and transition to `.thinking`, leaving the
            // user trapped in the voice UI watching a "thinking" pill.
            Task { await viewModel.endVoiceMode() }
        } label: {
            HStack(spacing: CGFloat.Stir.space2Half) {
                MicCircleView(state: viewModel.voiceState)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pillTitle)
                        .stirFont(.labelMicroEyebrow)
                        .foregroundStyle(Color.Stir.voice600)
                    Text(pillSubtitle)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink700)
                        .lineLimit(1)
                }
                Spacer(minLength: CGFloat.Stir.space2)
                if pillRole == .listening || pillRole == .speaking {
                    WaveformView(viewModel: viewModel, active: true)
                        .frame(width: 28, height: 18)
                } else if pillRole == .connecting {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(Color.Stir.voice600)
                }
            }
            .padding(.leading, CGFloat.Stir.space3)
            .padding(.trailing, CGFloat.Stir.space4)
            .padding(.vertical, CGFloat.Stir.space2)
            .frame(minWidth: 240, minHeight: 52)
            .background(
                Capsule()
                    .fill(Color.Stir.voice100.opacity(0.6)),
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.Stir.voice600, lineWidth: 1),
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pillAccessibilityLabel)
        .accessibilityHint(pillAccessibilityHint)
        // Both voice tutorial steps (intro + mic-states) anchor on the
        // listening pill — the mic circle is rendered inside it, so
        // the user's eye lands on the mic regardless of which step is
        // active. A separate `.voiceMicCircle` anchor was removed (it
        // resolved to the same frame, just via a fragile stacked-
        // background GeometryReader).
        .coachMarkAnchor(.voiceListeningPill)
    }

    // MARK: - Pill state mapping

    /// Coarse pill-role enum derived from the VM's voiceState. Drives
    /// label, mic-circle pulse animation, and waveform run state.
    ///
    /// No `.disabled` case: this view only renders when
    /// `viewModel.isVoiceActive == true`, which already filters out
    /// `.idle` / `.closed` / `.error` (the states that would otherwise
    /// produce a disabled pill). On nil `voiceState` we fall back to
    /// `.connecting` since that's the natural pre-state-machine moment
    /// — the user has just engaged voice and the driver is wiring up.
    private enum PillRole {
        /// `connecting` / `refreshing` / `fallingBack` — show spinner.
        case connecting
        /// `ready` (between turns) / `userSpeaking` / `transcribing` —
        /// show "LISTENING" + waveform.
        case listening
        /// `thinking` / `toolCalling` — show "THINKING…" + slow wave.
        case thinking
        /// `modelSpeaking` — show "STIR SPEAKING" + waveform.
        case speaking
    }

    private var pillRole: PillRole {
        guard let state = viewModel.voiceState else { return .connecting }
        switch state {
        case .connecting, .refreshing, .fallingBack:
            return .connecting
        case .ready, .userSpeaking, .transcribing:
            return .listening
        case .thinking, .toolCalling:
            return .thinking
        case .modelSpeaking:
            return .speaking
        case .idle, .closed, .error:
            // Unreachable in practice — `isVoiceActive` filters these
            // before this view renders. Fall back to `.connecting` so
            // an unexpected state doesn't crash on `switch` exhaustion;
            // user sees the spinner, then either the parent's
            // `isVoiceActive` flips false and tap-mode returns or
            // recovery succeeds.
            return .connecting
        }
    }

    private var pillTitle: String {
        switch pillRole {
        case .connecting: return "Connecting"
        case .listening:  return "Listening"
        case .thinking:   return "Thinking"
        case .speaking:   return "Stir speaking"
        }
    }

    private var pillSubtitle: String {
        switch pillRole {
        case .connecting: return "Opening the line…"
        case .listening:
            // Pre-first-turn the affordance is "tap to talk"; mid-
            // session the affordance is "just speak — VAD has it".
            return viewModel.hasBegunFirstTurn ? "Just speak" : "Tap to talk"
        case .thinking:   return "Working on it"
        case .speaking:   return "Tap to interrupt"
        }
    }

    private var pillAccessibilityLabel: String {
        switch pillRole {
        case .connecting: return "Connecting voice session"
        case .listening:  return "Listening for your voice. Just speak."
        case .thinking:   return "Stir is thinking."
        case .speaking:   return "Stir is speaking. Tap to interrupt."
        }
    }

    private var pillAccessibilityHint: String {
        // All voice-active pill roles route through the same close
        // action; the hint is uniform.
        "Double tap to stop voice mode."
    }
}

// MARK: - Voice timer pill

/// Compact active-timer affordance for the voice chrome. Stacks above
/// the listening pill via the bottom safeAreaInset so it's always
/// visible regardless of scroll position. Mirrors tap-mode's pause/
/// resume/cancel parity so the user can manage the timer without
/// abandoning voice mode (the model can also control via tool calls).
///
/// Visual: ember-bordered paper-100 capsule, 52pt min height to match
/// the listening pill above it. Layout left-to-right:
///   - 36pt timer-glyph badge (ember100 background)
///   - "TIMER" eyebrow + monospaced countdown text
///   - Spacer
///   - Pause/Resume button (ember-tinted)
///   - Cancel button (crimson-tinted, destructive affordance)
///
/// Countdown text uses `TimelineView(.periodic(by: 1.0))` while running
/// — same 1 Hz cadence as `TimerCountdownView`. Paused renders a static
/// `fireDate - pauseStartedAt` value (orange) so the digits don't tick
/// down while the timer is held.
private struct VoiceTimerPill: View {
    let timer: CookTimer
    let pauseStartedAt: Date?
    let onPauseResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: CGFloat.Stir.space2Half) {
            Image(systemName: "timer")
                .stirFont(.labelMd).fontWeight(.semibold)
                .foregroundStyle(Color.Stir.ember600)
                .frame(width: 36, height: 36)
                .background(Capsule().fill(Color.Stir.ember100))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Timer")
                    .stirFont(.labelMicroEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
                    // The countdown's a11y label already says "Timer
                    // running/paused, …" so the visible eyebrow is
                    // redundant for VoiceOver.
                    .accessibilityHidden(true)
                countdownLabel
                    .lineLimit(1)
            }

            Spacer(minLength: CGFloat.Stir.space2)

            Button(action: onPauseResume) {
                Image(systemName: timer.typedState == .running ? "pause.fill" : "play.fill")
                    .stirFont(.labelMd).fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ember600)
                    .frame(width: 36, height: 36)
                    .background(Capsule().fill(Color.Stir.ember100))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(timer.typedState == .running ? "Pause timer" : "Resume timer")

            Button(action: onCancel) {
                Image(systemName: "stop.fill")
                    .stirFont(.labelMd).fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.crimson600)
                    .frame(width: 36, height: 36)
                    .background(Capsule().fill(Color.Stir.crimson100))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel timer")
        }
        .padding(.leading, CGFloat.Stir.space2)
        .padding(.trailing, CGFloat.Stir.space2)
        .padding(.vertical, CGFloat.Stir.space2)
        .frame(minWidth: 240, minHeight: 52)
        .background(
            Capsule()
                .fill(Color.Stir.paper100),
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.Stir.ember600.opacity(0.25), lineWidth: 1),
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var countdownLabel: some View {
        switch timer.typedState {
        case .running:
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let secs = max(0, Int((timer.fireDate ?? context.date).timeIntervalSince(context.date).rounded()))
                Text(remainingText(at: context.date))
                    .stirFont(.bodyMd).fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink900)
                    .monospacedDigit()
                    .accessibilityLabel(Self.a11yLabel(seconds: secs, paused: false))
            }
        case .paused:
            // Color shift (orange) is the pause signal — matches
            // TimerCountdownView's pause treatment so the visual
            // language stays consistent between tap- and voice-mode.
            let secs: Int = {
                guard let fire = timer.fireDate else { return 0 }
                let reference = pauseStartedAt ?? Date()
                return max(0, Int(fire.timeIntervalSince(reference).rounded()))
            }()
            Text(pausedText())
                .stirFont(.bodyMd).fontWeight(.semibold)
                .foregroundStyle(.orange)
                .monospacedDigit()
                .accessibilityLabel(Self.a11yLabel(seconds: secs, paused: true))
        case .pending, .completed, .cancelled:
            // Pending shouldn't reach this view — `activeTimerPill`
            // filters to running/paused. Defensive empty so a stale
            // ref doesn't crash on switch exhaustiveness.
            EmptyView()
        }
    }

    private func remainingText(at now: Date) -> String {
        guard let fire = timer.fireDate else { return "0:00" }
        let secs = max(0, Int(fire.timeIntervalSince(now).rounded()))
        if secs <= 0 { return "Done" }
        return Self.mmss(secs)
    }

    private func pausedText() -> String {
        guard let fire = timer.fireDate else { return "0:00" }
        // pauseStartedAt is the wall-clock at which TimerService
        // captured the pause; falling back to `Date()` matches
        // TimerCountdownView's cold-relaunch-while-paused behavior.
        let reference = pauseStartedAt ?? Date()
        let secs = max(0, Int(fire.timeIntervalSince(reference).rounded()))
        return Self.mmss(secs)
    }

    private static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }

    /// Humanized accessibility label for the countdown. VoiceOver reads
    /// "Timer running, 4 minutes 49 seconds remaining" — clearer than
    /// the bare "4:49" the visible Text would otherwise expose. Drives
    /// off `seconds` so the running branch updates on each TimelineView
    /// tick (the Text is re-evaluated, taking this label with it).
    private static func a11yLabel(seconds: Int, paused: Bool) -> String {
        let s = max(0, seconds)
        let m = s / 60
        let sec = s % 60
        let mWord = m == 1 ? "minute" : "minutes"
        let sWord = sec == 1 ? "second" : "seconds"
        let state = paused ? "paused" : "running"
        if m > 0 && sec > 0 {
            return "Timer \(state), \(m) \(mWord) \(sec) \(sWord) remaining"
        } else if m > 0 {
            return "Timer \(state), \(m) \(mWord) remaining"
        } else {
            return "Timer \(state), \(sec) \(sWord) remaining"
        }
    }
}

// MARK: - Mic circle with pulse rings

/// Solid voice-tinted circle holding a white mic glyph. When the
/// session is actively engaged (userSpeaking / modelSpeaking), two
/// outward-radiating border rings pulse to signal "the mic is hot
/// and the system is engaged". Other states keep the circle calm
/// (no rings) so the user can tell at a glance whether voice is
/// passive (between turns) vs active (mid-utterance / mid-reply).
private struct MicCircleView: View {
    let state: VoiceSessionState?

    private var showRings: Bool {
        state == .userSpeaking || state == .modelSpeaking
    }

    var body: some View {
        ZStack {
            if showRings {
                pulseRing(scale: 1.5, delay: 0)
                pulseRing(scale: 1.9, delay: 0.4)
            }
            Circle()
                .fill(Color.Stir.voice600)
                .frame(width: 36, height: 36)
            Image(systemName: "mic.fill")
                .stirFont(.labelMd).fontWeight(.semibold)
                .foregroundStyle(Color.white)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private func pulseRing(scale: CGFloat, delay: Double) -> some View {
        TimelineView(.animation) { context in
            let phase = (context.date.timeIntervalSinceReferenceDate + delay)
                .truncatingRemainder(dividingBy: 1.4) / 1.4
            let progress = CGFloat(phase)
            Circle()
                .strokeBorder(Color.Stir.voice600.opacity(0.5 * (1 - progress)), lineWidth: 2)
                .frame(width: 36, height: 36)
                .scaleEffect(1 + (scale - 1) * progress)
        }
    }
}

// MARK: - Waveform

/// Seven vertical bars whose y-scale oscillates on staggered sine
/// curves AND scales with the live voice audio level read from the
/// VM each TimelineView tick. The sine cycle keeps the bars looking
/// "wavy" even at flat audio (so an empty room doesn't show a flat
/// dead block); the audio level multiplier makes the bars react to
/// actual loudness — louder mic input or louder model speech ⇒
/// taller bars. Two complementary signals, one visual.
///
/// `active=false` parks every bar at .4 scale so the wave settles to
/// a flat baseline whenever the pill role is non-listening / non-
/// speaking. Reactivating animates back into the cycle smoothly.
///
/// Smoothing: raw peaks from the audio thread arrive at ~50 Hz and
/// are jumpy. We track an exponentially-smoothed copy with asymmetric
/// attack/decay (fast rise, slow fall) so the bars feel responsive
/// to speech onset without snapping back to flat in the gaps between
/// syllables. Smoothing state is held in a `@State` `Box` so SwiftUI
/// view-recreation between frames doesn't reset it on every tick.
private struct WaveformView: View {
    /// Read-only access — WaveformView pulls `currentVoiceAudioLevel`
    /// each TimelineView frame but doesn't mutate any VM state, so
    /// `@Bindable` (which is for `$binding` syntax on `@Observable`
    /// properties) is overkill. A plain `let` reference keeps the
    /// dependency surface honest.
    let viewModel: CookModeViewModel
    let active: Bool

    /// Static per-bar phase offsets — match the design mockup's
    /// `${i*0.08}s` stagger so adjacent bars never reach peak at the
    /// same moment. Kept as Doubles (period seconds) so the offset
    /// and the period below share units.
    private let phaseOffsets: [Double] = [0.0, 0.08, 0.16, 0.24, 0.32, 0.40, 0.48]
    /// Animation period (seconds for one full bar cycle).
    private let period: Double = 0.9

    /// Reference-typed wrapper so the audio-level smoothing state
    /// survives across TimelineView frame redraws. SwiftUI rebuilds
    /// the body closure on every tick; storing the smoother in a
    /// class instance held by `@State` keeps the trailing-edge
    /// running across rebuilds. `@unchecked Sendable` because the
    /// only writer is MainActor-bound (the body closure on the UI
    /// thread).
    @State private var smoother = LevelSmoother()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            // Pull and smooth the live level on every frame. The
            // TimelineView is ticking us at 30 Hz, so the smoother
            // sees the mic peak about every ~30 ms — fine-grained
            // enough that the asymmetric attack/decay produces a
            // natural-feeling response curve.
            let rawLevel = viewModel.currentVoiceAudioLevel
            let level = smoother.update(rawLevel)
            // Scale the audio response: typical speech peaks land
            // around 0.2-0.5, not 1.0. Map [0, 0.5] → [0, 1] so the
            // bars actually move at conversational volume. Clamp at
            // 1.0 so loud bursts don't overshoot the visual ceiling.
            let amplified = min(1.0, level * 2.0)

            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<phaseOffsets.count, id: \.self) { i in
                    let phase = ((elapsed + phaseOffsets[i])
                        .truncatingRemainder(dividingBy: period)) / period
                    // Idle floor (0.25) keeps a gentle pulse going so
                    // the pill never looks "frozen" while voice is
                    // technically active but the audio path is silent
                    // (between turns, server thinking). Audio level
                    // tops up the amplitude so loud input pushes bars
                    // to full extension. Sine modulation stays for the
                    // wavy stagger that the screenshot shows.
                    let oscillator = sin(phase * 2 * .pi) * 0.5 + 0.5
                    let scale: CGFloat = active
                        ? CGFloat(0.25 + (0.15 + 0.6 * Double(amplified)) * oscillator)
                        : 0.4
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.Stir.voice600)
                        .frame(width: 2.5, height: 18)
                        .scaleEffect(x: 1, y: scale, anchor: .center)
                }
            }
            .frame(height: 18)
        }
    }
}

/// Asymmetric one-pole low-pass filter for audio-level smoothing.
/// `attack` controls how quickly the smoothed value rises toward a
/// new high (smaller = faster); `decay` controls how slowly it falls
/// toward a new low (larger = slower). The asymmetry matters for
/// speech-like signals: fast attack catches consonant onsets, slow
/// decay keeps the visualization riding through inter-syllable gaps
/// instead of flickering.
@MainActor
private final class LevelSmoother {
    private var smoothed: Float = 0
    /// Smoothing coefficient on rises: smaller = snappier attack.
    /// 0.4 ≈ ~70 ms half-life at 30 Hz tick rate.
    private let attackAlpha: Float = 0.4
    /// Smoothing coefficient on falls: larger = longer tail.
    /// 0.85 ≈ ~430 ms half-life at 30 Hz tick rate.
    private let decayAlpha: Float = 0.85

    func update(_ raw: Float) -> Float {
        let alpha = raw > smoothed ? attackAlpha : decayAlpha
        smoothed = smoothed * alpha + raw * (1 - alpha)
        return smoothed
    }
}
