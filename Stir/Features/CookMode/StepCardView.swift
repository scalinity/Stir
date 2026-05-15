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
                    // SCA-19 — full-screen tap Cook Mode tutorial.
                    .tutorial(key: .cookModeTap) { CookModeTapTutorial() }
            }
        }
        // SCA-19 / SCA-28 W9 — full-screen voice-mode tutorial mounted
        // on the OUTER Group rather than inside the `if isVoiceActive`
        // branch. Mounting on the inner branch tore down the modifier
        // (and its `isPresenting` state) when `isVoiceActive` flipped
        // false mid-tutorial — model error / mic permission revoked /
        // refresh failure. The cover would dismiss WITHOUT
        // `markCompleted(.voiceMode)`, the next voice session would
        // re-fire the tour, and PostHog would see two
        // `tutorial_started` events for one resolution. Mounting on
        // the parent Group lets the modifier survive the branch flip;
        // the cover stays presented while the inner tap-mode body
        // renders silently behind it (cover is full-screen).
        .tutorial(
            key: .voiceMode,
            content: { VoiceModeTutorial() },
            shouldPresent: viewModel.isVoiceActive,
        )
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
            recipeStrip
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    stepHeader
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

    /// Cook Mode top bar — three-column layout per
    /// `stir-app-design/project/DesignMockups/06_cook_mode_tap.html:70-77`.
    /// LEFT: 36pt rounded close button. CENTER: stacked column with
    /// uppercase "Cook mode · Tap" eyebrow over `StepDots`. RIGHT: 36pt
    /// rounded eye button (recipe-detail peek — semantics deferred,
    /// see SCA-93 ticket; currently a visible affordance with no-op
    /// action so the layout matches mockup pixel-for-pixel without
    /// committing to a destination).
    ///
    /// SCA-422: eyebrow visually pushed right of center because the
    /// eye button is hidden under `if false`. Two equal-flex Spacers
    /// only center the middle column when both flanking elements have
    /// equal width — with `[44pt][Spacer][center][Spacer][0pt]` the
    /// center sits offset by half the close-button width. Switching
    /// to ZStack-overlay centering anchors the eyebrow against the
    /// full bar width regardless of what flanks it. When the eye
    /// button returns the same ZStack accommodates it without
    /// reintroducing the centering bug.
    private var topBar: some View {
        ZStack {
            VStack(spacing: 4) {
                Text("Cook mode · Tap")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink500)
                StepDots(
                    step: viewModel.currentStepIndex + 1,
                    total: max(viewModel.totalSteps, 1),
                )
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: CGFloat.Stir.space3) {
                roundIconButton(
                    icon: Image.Stir.close,
                    accessibilityLabel: "Exit Cook Mode",
                    action: { viewModel.requestExitConfirm() },
                )

                Spacer()

                // Eye-button affordance — the mockup's recipe-detail peek
                // surface. Wiring the destination (modal sheet of the full
                // recipe) is out of scope for SCA-93 per ticket: "Semantics
                // TBD — recommend recipe-detail peek (modal sheet) since
                // that's a pattern users will want anyway. Confirm with
                // Daniel before wiring."
                //
                // SCA-311 S4: hidden under `if false` until the peek-sheet
                // design lands. A `.disabled(true)` no-op reads as broken
                // to beta testers; the affordance is suppressed entirely
                // rather than dimmed. Re-enable by flipping `if false` to
                // `if true` (or gating on a feature flag) when wiring the
                // destination.
                if false {
                    roundIconButton(
                        icon: Image(systemName: "eye"),
                        accessibilityLabel: "Recipe overview",
                        action: {},
                    )
                    .disabled(true)
                }
            }
        }
        .padding(.horizontal, CGFloat.Stir.space4)
        .padding(.vertical, CGFloat.Stir.space2)
    }

    /// Recipe strip — sits between the top bar and the scrollable
    /// instruction body. Two-line layout:
    ///
    ///     <recipe title (semibold, up to 2 lines)>
    ///     Step N of M · ~T min left
    ///
    /// SCA-422: previously a single-line HStack forced
    /// `.lineLimit(1).truncationMode(.tail)` on the title, so anything
    /// longer than ~22 chars ("Grilled Italian Flatbread") rendered as
    /// "Grilled Italian F...". Splitting title onto its own row gives
    /// it the full screen width and up to two lines before truncation,
    /// while the meta line below keeps the step counter and remaining-
    /// time estimate in the same visual region. Mockup
    /// `stir-app-design/project/DesignMockups/06_cook_mode_tap.html:79-85`
    /// is single-line because the sample title fits; the two-line
    /// pattern is a strict superset and only adds vertical space when
    /// the title is long enough to wrap.
    ///
    /// Remaining-time estimate uses
    /// `RecipePlan.remainingDurationMinutes(fromStepIndex:)`. Rendered
    /// only when there's a meaningful estimate — a recipe with no
    /// `timerSeconds` AND no `estimatedMinutes` would otherwise show
    /// "~0 min left" which reads as broken.
    private var recipeStrip: some View {
        let title = viewModel.recipePlan.title ?? "Cook Mode"
        let remainingMin = viewModel.recipePlan.remainingDurationMinutes(
            fromStepIndex: viewModel.currentStepIndex,
        )
        let stepLabel = "Step \(viewModel.currentStepIndex + 1) of \(viewModel.totalSteps)"

        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .stirFont(.labelLg).fontWeight(.semibold)
                .foregroundStyle(Color.Stir.ink900)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: CGFloat.Stir.space1) {
                Text(stepLabel)
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ink500)
                    .lineLimit(1)

                if remainingMin > 0 {
                    Text("· ~\(remainingMin) min left")
                        .stirFont(.labelMd)
                        .foregroundStyle(Color.Stir.ink500)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, CGFloat.Stir.space4)
        .padding(.bottom, CGFloat.Stir.space1)
        .accessibilityElement(children: .combine)
    }

    /// 36pt rounded icon button with `paper200` fill. Mirrors the
    /// mockup's circular top-bar action style (`width:36, height:36,
    /// borderRadius:999, background:c.paper200`). Hit area kept at
    /// 44pt via `contentShape` so the button stays accessibility-
    /// compliant despite the smaller visual footprint.
    private func roundIconButton(
        icon: Image,
        accessibilityLabel: String,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            icon
                .stirFont(.labelMd).fontWeight(.semibold)
                .foregroundStyle(Color.Stir.ink700)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(Color.Stir.paper200),
                )
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Content

    @ViewBuilder
    private var stepHeader: some View {
        if let step = viewModel.currentStep, let title = step.title, !title.isEmpty {
            // Optional per-step title (e.g. "Searing"). The "Step N of
            // M" counter previously also lived here — moved into the
            // recipeStrip above the scroll body to match the mockup,
            // so this header is title-only now and degrades to nothing
            // when the step has no title.
            Text(title)
                .stirFont(.labelMd).fontWeight(.medium)
                .foregroundStyle(Color.Stir.ink700)
                .lineLimit(1)
        }
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
