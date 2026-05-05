// StepCardView
//
// Single Cook Mode step: large instruction text, step X of Y, optional
// countdown timer + controls, Next / Previous / Ask / Exit. Designed
// for arm's-length readability — `.displayMd` New York Semibold for
// the instruction, Dynamic Type respected, 44pt minimum hit targets
// per spec §6 accessibility baseline.
//
// Step-9 design-review resolution (review finding C2):
//   - Primary navigation (Next/Finish/Previous) uses the Phase 2
//     PrimaryButton/SecondaryButton components for consistent ember
//     chrome across the app.
//   - Other buttons stay custom because each carries state the Phase 2
//     components don't model: the voice row has a 4-role micButtonRole
//     state machine with variable icon/label/tint/progress, the Ask
//     row has an icon-plus-label layout, and the timer controls
//     switch between pause/resume/cancel based on CookTimer.typedState.
//   - All spacing/padding/radius/icon literals moved to `CGFloat.Stir.*`
//     and `Image.Stir.*` tokens. A few literals remain with inline
//     `// justification:` comments — paddings specific to this view's
//     bottom-nav clearance (140pt) and the voice row's 48pt floor
//     (slightly taller than PrimaryButton's 52pt to keep the pressed
//     state reachable with one hand).
//
// Previously a critical drift point (FD1) — 20+ bare literals,
// `Image(systemName:)` raw calls, `.buttonStyle(.bordered*)` chrome,
// `.tint(.red)` — now consolidated with the rest of the migration.

import SwiftUI

struct StepCardView: View {
    @Bindable var viewModel: CookModeViewModel

    var body: some View {
        Group {
            if viewModel.isVoiceActive {
                // Voice-mode chrome: replaces the entire tap-mode body
                // while a Live or Speech-fallback session is running.
                // Shares ALL state with this VM (no parallel state) —
                // the only difference is layout. Reverts to tap-mode
                // automatically when the session terminates and
                // `isVoiceActive` flips false.
                VoiceActiveStepView(viewModel: viewModel)
            } else {
                tapModeBody
            }
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

    /// The original Cook Mode body — full chrome with topBar, instruction
    /// scroll, timer card, and the voice/ask/prev/next bottom rows.
    /// Rendered when no voice session is active. The voice-mode path
    /// uses `VoiceActiveStepView` instead, which has its own simpler
    /// layout per the 2026-04-25 mockup.
    private var tapModeBody: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    stepHeader
                    swapBadgeRow
                    instructionBody
                    timerSection
                }
                .padding(.horizontal, CGFloat.Stir.screenMarginHero)
                .padding(.top, CGFloat.Stir.space5)
                // justification: 140pt bottom clearance reserves room
                // for the safeAreaInset bottom bar (voice row + ask row
                // + prev/next row). One-off screen chrome spacing — not
                // a generic token case.
                .padding(.bottom, 140)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
                // FD1-1 fix: paper50 + 1pt hairline divider matches the
                // app-wide bottom-bar grammar (Settings, Saved, Tonight,
                // RootView's StirCustomTabBar). Replaces `.background(.bar)`
                // translucent material that left Cook Mode visually
                // distinct from every other surface.
                .background(Color.Stir.paper50)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.Stir.divider)
                        .frame(height: 1)
                }
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

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: CGFloat.Stir.space3) {
            Button {
                viewModel.requestExitConfirm()
            } label: {
                Image.Stir.close
                    .stirFont(.bodyMd).fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink900)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Exit Cook Mode")

            Spacer()

            // 2-line wrap + scale-down so titles like "Rosemary Infused
            // Tomato Pasta" no longer truncate. The mockup
            // (06_cook_mode_tap.html:70-85) puts the title in a separate
            // recipe strip below the top bar, not centered inside it —
            // refactor tracked in CLAUDE.md §Deferred. Fixed: 2026-04-28.
            Text(viewModel.recipePlan.title ?? "Cook Mode")
                .stirFont(.labelLg).fontWeight(.semibold)
                .foregroundStyle(Color.Stir.ink900)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)

            Spacer()

            // Balance the x button — transparent ghost so the title stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space2)
    }

    // MARK: - Content

    private var stepHeader: some View {
        HStack {
            Text("Step \(viewModel.currentStepIndex + 1) of \(viewModel.totalSteps)")
                .stirFont(.labelMd).fontWeight(.medium)
                .foregroundStyle(Color.Stir.ink500)
            Spacer()
            if let step = viewModel.currentStep, let title = step.title, !title.isEmpty {
                Text(title)
                    .stirFont(.labelMd).fontWeight(.medium)
                    .foregroundStyle(Color.Stir.ink700)
                    .lineLimit(1)
            }
        }
    }

    /// Compact horizontal row of accepted-substitution badges for the
    /// current cooking session. Rendered between stepHeader and
    /// instructionBody so the user reads the swap context BEFORE the
    /// step prose — instruction text still references the original
    /// ingredient (e.g. "Add the dried pasta") and the badge tells the
    /// user what they're actually using ("rice noodles (was: dried
    /// pasta)"). No-op when the session has no accepted swaps.
    @ViewBuilder
    private var swapBadgeRow: some View {
        let swaps = viewModel.acceptedSwaps
        if !swaps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CGFloat.Stir.space2) {
                    ForEach(Array(swaps.enumerated()), id: \.offset) { _, pair in
                        swapBadge(swap: pair.swap, original: pair.original)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Substitutions in this session: " + swaps
                .map { "\($0.swap) instead of \($0.original)" }
                .joined(separator: ", "))
        }
    }

    private func swapBadge(swap: String, original: String) -> some View {
        HStack(spacing: CGFloat.Stir.space1) {
            Text(swap)
                .stirFont(.labelMd).fontWeight(.semibold)
                .foregroundStyle(Color.Stir.ember600)
            Text("(was: \(original))")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space1 + 2)
        .background(
            Capsule().fill(Color.Stir.ember100),
        )
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

    @ViewBuilder
    private var timerSection: some View {
        if let step = viewModel.currentStep {
            // Register this view as a dependent of `timerStateVersion`
            // so @Observable invalidation fires on every timer mutation.
            // NSManagedObject property changes on CookTimer don't
            // propagate through @Observable on their own. The binding
            // is intentionally unused downstream — the read itself is
            // what Observation tracks.
            let _ = viewModel.timerStateVersion
            // Only treat running / paused / pending timers as "the
            // step's current timer" for UI routing. Cancelled and
            // completed timers stay in `activeTimers` for history
            // + telemetry, but should NOT suppress the Start button
            // (CR1-13 regression: after cancel, the only visible
            // control was another Cancel button with nothing to start).
            let activeTimer = viewModel.activeTimers.first {
                $0.step?.id == step.id
                && ($0.typedState == .running
                    || $0.typedState == .paused
                    || $0.typedState == .pending)
            }
            // Surface the timer section EITHER when this step has a
            // configured base duration OR when there's an active timer
            // for it. The voice path (`startTimerFromVoice`) creates a
            // CookTimer with arbitrary seconds without mutating
            // `step.timerSeconds`, so a step that has no base duration
            // can still own a live voice-created timer — gating the
            // section purely on `step.timerSeconds > 0` left those
            // timers invisible after the user exits voice mode
            // (observed device-side 2026-05-03).
            let hasBaseTimer = step.timerSeconds > 0
            if activeTimer != nil || hasBaseTimer {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
                    Text("Timer")
                        .stirFont(.labelLg).fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink900)
                        .accessibilityAddTraits(.isHeader)
                    if let timer = activeTimer {
                        TimerCountdownView(
                            timer: timer,
                            pauseStartedAt: viewModel.pauseStartedAt(for: timer),
                        )
                        timerControlRow(for: timer)
                    } else if hasBaseTimer {
                        // Start button only available when the step
                        // ships with a base duration; voice-created
                        // timers begin via the voice tool call, not a
                        // tap-mode button, so we don't synthesize one
                        // here for steps that lack a configured
                        // duration.
                        Button {
                            Task { await viewModel.startTimerForCurrentStep() }
                        } label: {
                            HStack(spacing: CGFloat.Stir.space2) {
                                Image.Stir.timer
                                Text("Start \(Int(step.timerSeconds) / 60) min timer")
                                    .stirFont(.labelLg).fontWeight(.semibold)
                            }
                            .foregroundStyle(Color.Stir.paper50)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .frame(minHeight: 44)
                            .background(
                                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                                    .fill(Color.Stir.ember600),
                            )
                        }
                        .accessibilityHint("Schedules a local notification for when the step is done.")
                    }
                }
                .padding(CGFloat.Stir.space4)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(Color.Stir.paper100),
                )
            }
        }
    }

    private func timerControlRow(for timer: CookTimer) -> some View {
        HStack(spacing: CGFloat.Stir.space3) {
            switch timer.typedState {
            case .running:
                timerControlButton(
                    title: "Pause",
                    icon: Image.Stir.pause,
                    style: .neutral,
                    action: { Task { await viewModel.pauseTimer(timer) } },
                )
            case .paused:
                timerControlButton(
                    title: "Resume",
                    icon: Image.Stir.play,
                    style: .emberFilled,
                    action: { Task { await viewModel.resumeTimer(timer) } },
                )
            case .pending, .completed, .cancelled:
                EmptyView()
            }
            timerControlButton(
                title: "Cancel",
                // justification: "stop.fill" has no direct Image.Stir.*
                // token; adding one just for Cook Mode's timer-cancel
                // glyph isn't pattern-wide. Keeping inline keeps the
                // icon catalog focused on the semantic set defined in
                // spec §6.
                icon: Image(systemName: "stop.fill"),
                style: .destructive,
                action: { Task { await viewModel.cancelTimer(timer) } },
            )
        }
    }

    private enum TimerControlStyle { case neutral, emberFilled, destructive }

    private func timerControlButton(
        title: String,
        icon: Image,
        style: TimerControlStyle,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CGFloat.Stir.space2) {
                icon
                Text(title)
                    .stirFont(.labelMd).fontWeight(.medium)
            }
            .foregroundStyle(timerControlForeground(style))
            .frame(maxWidth: .infinity, minHeight: 44)
            .stirCard(
                fill: timerControlBackground(style),
                borderColor: timerControlBorder(style),
                radius: CGFloat.Stir.radiusMd,
            )
            .contentShape(Rectangle())
        }
    }

    private func timerControlForeground(_ style: TimerControlStyle) -> Color {
        switch style {
        case .neutral:      return Color.Stir.ink900
        case .emberFilled:  return Color.Stir.paper50
        case .destructive:  return Color.Stir.crimson600
        }
    }

    private func timerControlBackground(_ style: TimerControlStyle) -> Color {
        switch style {
        case .neutral:      return Color.Stir.paper100
        case .emberFilled:  return Color.Stir.ember600
        case .destructive:  return Color.Stir.paper100
        }
    }

    private func timerControlBorder(_ style: TimerControlStyle) -> Color {
        switch style {
        case .neutral:      return Color.Stir.divider
        case .emberFilled:  return Color.Stir.ember600
        case .destructive:  return Color.Stir.crimson600.opacity(0.4)
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: CGFloat.Stir.space3) {
            voiceRow
            askRow
            navigationRow
        }
        .padding(.horizontal, CGFloat.Stir.space4)
        .padding(.top, CGFloat.Stir.space3 - 2) // 10pt
        .padding(.bottom, CGFloat.Stir.space3 - 2) // 10pt
    }

    private var askRow: some View {
        Button {
            viewModel.requestSubstitution()
        } label: {
            HStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt
                // justification: "questionmark.bubble" is a Cook Mode-
                // specific Ask affordance glyph; no Image.Stir.* token
                // (the Icons catalog uses `.help` = "questionmark.circle"
                // for generic help, which reads differently).
                Image(systemName: "questionmark.bubble")
                Text("Something missing?")
                    .stirFont(.labelMd).fontWeight(.medium)
            }
            .foregroundStyle(Color.Stir.ink900)
            .frame(maxWidth: .infinity, minHeight: 44)
            .stirCard(radius: CGFloat.Stir.radiusMd)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Substitute a missing ingredient")
    }

    private var navigationRow: some View {
        HStack(spacing: CGFloat.Stir.space3) {
            SecondaryButton(
                title: "Previous",
                isDisabled: viewModel.isFirstStep,
                action: { viewModel.previousStep() },
            )
            .accessibilityLabel("Previous step")

            PrimaryButton(
                title: viewModel.isLastStep ? "Finish" : "Next",
                action: {
                    if viewModel.isLastStep {
                        viewModel.finish()
                    } else {
                        viewModel.nextStep()
                    }
                },
            )
            .accessibilityLabel(viewModel.isLastStep ? "Finish cooking" : "Next step")
        }
    }

    // MARK: - Voice row

    /// Mic affordance. Visible on ALL tiers (Daniel's pre-commit);
    /// tap-behavior branches in the VM:
    ///   Free      → paywall trigger
    ///   Premium/Pro → voice turn
    /// Visual state reflects the VM's `micButtonRole` (single source of
    /// truth — never recompute from raw voiceState bits here). Review
    /// fix: unified `.buttonStyle(.bordered)` with tint carrying weight
    /// shift — a conditional `.buttonStyle` between two concrete styles
    /// creates two distinct SwiftUI view types and forces a remount on
    /// state flip, breaking `Button.isPressed` mid-gesture and forcing
    /// accessibility to re-read the whole control.
    ///
    /// State-dependent chrome is too rich for PrimaryButton/SecondaryButton
    /// (4 role × tint × icon × label × optional spinner). Keeping custom.
    private var voiceRow: some View {
        Button {
            Task { await viewModel.handleMicTap() }
        } label: {
            HStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt
                Image(systemName: micIconName)
                    .stirFont(.labelLg).fontWeight(.semibold)
                    .accessibilityHidden(true)
                Text(micLabel)
                    .stirFont(.labelLg).fontWeight(.semibold)
                if viewModel.micButtonRole == .busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(micForeground)
                }
            }
            .foregroundStyle(micForeground)
            .frame(maxWidth: .infinity, minHeight: 48)
            .stirCard(
                fill: micBackground,
                borderColor: micBorder,
                radius: CGFloat.Stir.radiusMd,
            )
            .contentShape(Rectangle())
        }
        // Button stays enabled during `.busy` — hands-free contract
        // says tap = "exit voice mode", and users were getting stuck
        // in a spinning state when the button was `.disabled` with
        // no other escape hatch (observed 2026-04-22). Disable only
        // when there's genuinely nothing the tap can do (no driver
        // yet, still connecting).
        .disabled(micButtonDisabled)
        .accessibilityLabel(micAccessibilityLabel)
        .accessibilityHint(micAccessibilityHint)
    }

    private var micButtonDisabled: Bool {
        // Only disable while we're still bringing the driver up —
        // once ready, every state is user-actionable (start session
        // / end session).
        viewModel.voiceState == .connecting
    }

    private var micIconName: String {
        switch viewModel.micButtonRole {
        // justification: stop.circle.fill / mic.circle.fill are
        // role-specific composite glyphs (icon-in-circle) that don't
        // map to the Image.Stir semantic catalog. Raw SFSymbol is
        // the right abstraction level here — a token would be
        // specific to one call site.
        case .submit, .busy, .listening: return "stop.circle.fill"
        case .askWithVoice:              return "mic.circle.fill"
        }
    }

    private var micLabel: String {
        switch viewModel.micButtonRole {
        case .listening:
            // Session live, VAD hot, between turns. Explicit "go
            // ahead and talk" affordance so users don't think the
            // button needs another tap to resume listening.
            return "Listening — tap to stop"
        case .submit:
            // User mid-utterance. Tap submits turn early.
            return "Stop voice"
        case .busy:
            if viewModel.voiceState == .thinking { return "Thinking…" }
            if viewModel.voiceState == .modelSpeaking { return "Stir speaking…" }
            if viewModel.voiceState == .transcribing { return "Getting that…" }
            return "Working…"
        case .askWithVoice:
            return "Ask with voice"
        }
    }

    private var micForeground: Color {
        switch viewModel.micButtonRole {
        case .submit, .busy, .listening: return Color.Stir.crimson600
        case .askWithVoice:              return Color.Stir.ember600
        }
    }

    private var micBackground: Color {
        switch viewModel.micButtonRole {
        case .submit, .busy, .listening: return Color.Stir.crimson100
        case .askWithVoice:              return Color.Stir.paper100
        }
    }

    private var micBorder: Color {
        switch viewModel.micButtonRole {
        case .submit, .busy, .listening: return Color.Stir.crimson600.opacity(0.4)
        case .askWithVoice:              return Color.Stir.divider
        }
    }

    private var micAccessibilityLabel: String {
        switch viewModel.micButtonRole {
        case .submit, .busy, .listening: return "Stop voice mode"
        case .askWithVoice:              return "Ask with voice"
        }
    }

    private var micAccessibilityHint: String {
        switch viewModel.micButtonRole {
        case .listening:
            return "Voice mode is active. Just speak — Stir is listening. Tap to stop voice mode."
        case .submit:
            return "Taps stop voice mode. Stir hears you automatically when you pause — no tap needed."
        case .busy:
            return "Taps stop voice mode."
        case .askWithVoice:
            return "Opens microphone for hands-free cooking questions. Premium feature."
        }
    }
}
