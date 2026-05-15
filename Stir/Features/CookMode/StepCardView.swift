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
        .stirDialog(
            isPresented: $viewModel.exitConfirmRequested,
            title: "Leave Cook Mode?",
            message: "Your progress is saved. You can resume from Tonight Home.",
            buttons: [
                .secondary("Pause and resume later") {
                    Task { await viewModel.exit(markAbandoned: false) }
                },
                .destructive("Abandon session") {
                    Task { await viewModel.exit(markAbandoned: true) }
                },
                .cancel("Keep cooking"),
            ],
        )
    }

    /// The original Cook Mode body — full chrome with topBar, instruction
    /// scroll, timer card, and the voice/ask/prev/next bottom rows.
    /// Rendered when no voice session is active. The voice-mode path
    /// uses `VoiceActiveStepView` instead, which has its own simpler
    /// layout per the 2026-04-25 mockup.
    private var tapModeBody: some View {
        VStack(spacing: 0) {
            topBar
            // SCA-433: step rail replaces the in-topBar `StepDots`. The
            // dots gave a progress signal but no journey context — the
            // rail keeps the at-a-glance progress read AND lets the
            // user peek at upcoming steps + jump back to a step they
            // want to re-check. Sits between the topBar and recipeStrip
            // so it shares the top-chrome region rather than competing
            // with the instruction body.
            railRow
            recipeStrip
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    stepHeader
                    cautionRow
                    instructionBody
                    timerSection
                }
                .padding(.horizontal, CGFloat.Stir.screenMarginHero)
                .padding(.top, CGFloat.Stir.space5)
                // justification: 140pt bottom clearance was the
                // original safe-area reserve for the voice/ask/nav
                // stack; bumped to 220pt to clear the SCA-433 up-next
                // card that now sits above the voice row.
                .padding(.bottom, 220)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // SCA-433: up-next preview sits above the voice / ask /
                // nav stack. Last step swaps the preview for a celebration
                // line so the dead zone fills with positive momentum at
                // the moment users most need it. paper50 background
                // matches the bottom bar so the card and the nav stack
                // share a single surface visually.
                upNextCard
                    .padding(.horizontal, CGFloat.Stir.space4)
                    .padding(.top, CGFloat.Stir.space3 - 2) // 10pt
                bottomBar
            }
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
        // SCA-428: exit-confirm `.stirDialog` lives on `body`'s outer
        // Group, not here. Two modifiers sharing
        // `$viewModel.exitConfirmRequested` raced each other.
    }

    // MARK: - Top bar

    /// Cook Mode top bar — three-column layout per
    /// `stir-app-design/project/DesignMockups/06_cook_mode_tap.html:70-77`.
    /// LEFT: 36pt rounded close button. CENTER: uppercase "Cook mode ·
    /// Tap" eyebrow. RIGHT: 36pt rounded eye button (recipe-detail
    /// peek — semantics deferred, see SCA-93 ticket).
    ///
    /// SCA-422: ZStack-overlay centering anchors the eyebrow against
    /// the full bar width regardless of what flanks it, so the hidden
    /// eye button doesn't shift the centerline.
    ///
    /// SCA-433: `StepDots` no longer lives here — the new `StepRail`
    /// (rendered between topBar and recipeStrip) carries the progress
    /// signal and adds journey context the dots couldn't.
    private var topBar: some View {
        ZStack {
            Text("Cook mode · Tap")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
                .accessibilityElement(children: .combine)

            HStack(spacing: CGFloat.Stir.space3) {
                StirCircleIconButton(
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
                    StirCircleIconButton(
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

    /// SCA-433: step rail. Replaces `StepDots` as the progress
    /// indicator and adds journey context — tap any chip to jump.
    /// The rail's titles come from per-step `title` (e.g. "Searing"),
    /// not `instructionText`. Steps without a title render a numbered
    /// chip with no caption rather than truncating instruction prose
    /// — keeps the rail visually tight on recipes whose AI output
    /// didn't include step titles.
    private var railRow: some View {
        StepRail(
            currentIndex: viewModel.currentStepIndex,
            totalSteps: viewModel.totalSteps,
            stepTitles: viewModel.recipePlan.stepArray.map { $0.title },
            onJump: { idx in viewModel.jumpToStep(idx, advancedBy: "rail") },
        )
        .padding(.bottom, CGFloat.Stir.space2)
    }

    /// SCA-433: amber caution chips for the active step. Surfaces
    /// `RecipeStep.cautionTagsCSV` (a comma-separated string the
    /// backend prompt populates with values like "hot_surface",
    /// "sharp_knife"). Well-known tokens map to SF Symbols; unknown
    /// tokens render as text-only chips so a future prompt addition
    /// doesn't silently disappear from the UI. No-op when the CSV
    /// is empty / nil / all-whitespace.
    @ViewBuilder
    private var cautionRow: some View {
        let raw = viewModel.currentStep?.cautionTagsCSV ?? ""
        let tags: [String] = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CGFloat.Stir.space2) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                        cautionChip(tag)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "Caution: " + tags.map { humanCautionLabel($0) }.joined(separator: ", "),
            )
        }
    }

    private func cautionChip(_ tag: String) -> some View {
        HStack(spacing: CGFloat.Stir.space1) {
            if let symbol = cautionSymbol(for: tag) {
                Image(systemName: symbol)
                    .stirFont(.bodySm).fontWeight(.semibold)
                    .accessibilityHidden(true)
            }
            Text(humanCautionLabel(tag))
                .stirFont(.labelMd).fontWeight(.medium)
        }
        .foregroundStyle(Color.Stir.amber600)
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space1 + 2)
        .background(
            Capsule().fill(Color.Stir.amber100),
        )
    }

    private func cautionSymbol(for tag: String) -> String? {
        // Token alphabet kept narrow on purpose — the AI prompt picks
        // from a known list, so an unknown tag is a prompt-version
        // drift signal. Fall back to text-only chip in that case so
        // the UI still surfaces the warning instead of silently
        // hiding it.
        switch tag {
        case "hot_surface", "hot", "fire":          return "flame.fill"
        case "sharp_knife", "sharp", "knife":       return "scissors"
        case "splatter", "oil_splatter":            return "drop.fill"
        case "allergen", "allergens":               return "exclamationmark.shield.fill"
        case "raw_meat", "raw":                     return "fork.knife"
        case "steam":                               return "cloud.fill"
        default:                                    return nil
        }
    }

    private func humanCautionLabel(_ tag: String) -> String {
        // Convert snake_case backend tokens to Title Case for display.
        // No-op when the token already reads naturally.
        let words = tag
            .split(separator: "_")
            .map { String($0).capitalized }
        return words.isEmpty ? tag : words.joined(separator: " ")
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

    // MARK: - Up-next card (SCA-433)

    /// Small preview card sitting between the scrollable instruction
    /// body and the bottom bar. Fills the empty mid-screen dead zone
    /// with the next step's title (or trimmed `instructionText` if no
    /// title was set by the AI). On the last step the preview is
    /// swapped for a celebration line so the user reads "you're almost
    /// done" exactly when their motivation is wavering. Hidden when
    /// `totalSteps == 0` (defensive — Cook Mode shouldn't open on an
    /// empty recipe but the safe-area inset still renders).
    @ViewBuilder
    private var upNextCard: some View {
        let total = viewModel.totalSteps
        let current = viewModel.currentStepIndex
        let isFinal = current >= total - 1

        if total > 0 {
            HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
                if isFinal {
                    Image(systemName: "sparkles")
                        .stirFont(.labelLg).fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ember600)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LAST STEP")
                            .stirFont(.labelEyebrow)
                            .foregroundStyle(Color.Stir.ember600)
                        Text("You're almost done.")
                            .stirFont(.labelMd).fontWeight(.medium)
                            .foregroundStyle(Color.Stir.ink900)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("UP NEXT")
                            .stirFont(.labelEyebrow)
                            .foregroundStyle(Color.Stir.ink500)
                        Text(nextStepPreview())
                            .stirFont(.labelMd).fontWeight(.medium)
                            .foregroundStyle(Color.Stir.ink900)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(CGFloat.Stir.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                    .strokeBorder(Color.Stir.divider, lineWidth: 1),
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                isFinal ? "Last step. You're almost done." : "Up next: \(nextStepPreview())",
            )
        }
    }

    /// Title-or-first-sentence preview of the step immediately after
    /// the current one. Falls back to a generic "Coming up." if both
    /// the title and instruction text are empty so the card never
    /// renders an empty line. Trimmed to ~120 chars before the 2-line
    /// tail truncation does its own visual cap.
    private func nextStepPreview() -> String {
        let steps = viewModel.recipePlan.stepArray
        let nextIndex = viewModel.currentStepIndex + 1
        guard nextIndex >= 0, nextIndex < steps.count else { return "Coming up." }
        let nextStep = steps[nextIndex]

        if let title = nextStep.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty
        {
            return title
        }
        let raw = (nextStep.instructionText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Coming up." }
        // Trim to first sentence (`.` `!` `?` boundary) so a long
        // multi-sentence step doesn't fill the card with prose. The
        // 120-char hard cap is a belt-and-suspenders guard for the
        // case where the model wrote no terminal punctuation at all.
        let firstSentence: String = {
            if let endIdx = raw.firstIndex(where: { ".!?".contains($0) }) {
                return String(raw[raw.startIndex ... endIdx])
            }
            return raw
        }()
        if firstSentence.count > 120 {
            let cut = firstSentence.prefix(117)
            return cut + "…"
        }
        return firstSentence
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
