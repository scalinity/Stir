// StepCardView
//
// Single Cook Mode step: large instruction text, step X of Y, optional
// countdown timer + controls, Next / Previous / Ask / Exit. Designed
// for arm's-length readability — `.title` font for the instruction,
// Dynamic Type respected, 44pt minimum hit targets per spec §6
// accessibility baseline.

import SwiftUI

struct StepCardView: View {
    @Bindable var viewModel: CookModeViewModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    stepHeader
                    instructionBody
                    timerSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 140)  // leave room for the bottom nav bar
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
                .background(.bar)
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
        HStack(spacing: 12) {
            Button {
                viewModel.requestExitConfirm()
            } label: {
                Image(systemName: "xmark")
                    .stirFont(.bodyMd).fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink900)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Exit Cook Mode")

            Spacer()

            Text(viewModel.recipePlan.title ?? "Cook Mode")
                .stirFont(.labelLg).fontWeight(.semibold)
                .lineLimit(1)

            Spacer()

            // Balance the x button — transparent ghost so the title stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                    .lineLimit(1)
            }
        }
    }

    private var instructionBody: some View {
        Text(viewModel.currentStep?.instructionText ?? "")
            .stirFont(.displayMd)
            .lineSpacing(6)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var timerSection: some View {
        if let step = viewModel.currentStep, step.timerSeconds > 0 {
            VStack(alignment: .leading, spacing: 12) {
                Text("Timer")
                    .stirFont(.labelLg).fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)
                // Only treat running / paused / pending timers as "the
                // step's current timer" for UI routing. Cancelled and
                // completed timers stay in `activeTimers` for history
                // + telemetry, but should NOT suppress the Start button
                // — that was the 2026-04-22 bug where after cancelling
                // the only visible control was another Cancel button
                // with nothing to start.
                //
                // Register this view as a dependent of
                // `timerStateVersion` so @Observable invalidation fires
                // on every timer mutation. NSManagedObject property
                // changes don't propagate through @Observable on their
                // own, so without this dependency the button routing
                // could stick on "running" even after a cancel. The
                // binding is intentionally unused downstream — the
                // read itself is what Observation tracks.
                let _ = viewModel.timerStateVersion
                let matching = viewModel.activeTimers.first {
                    $0.step?.id == step.id
                    && ($0.typedState == .running
                        || $0.typedState == .paused
                        || $0.typedState == .pending)
                }
                if let timer = matching {
                    TimerCountdownView(
                        timer: timer,
                        pauseStartedAt: viewModel.pauseStartedAt(for: timer),
                    )
                    timerControlRow(for: timer)
                } else {
                    Button {
                        Task { await viewModel.startTimerForCurrentStep() }
                    } label: {
                        Label("Start \(Int(step.timerSeconds) / 60) min timer", systemImage: "timer")
                            .stirFont(.labelLg).fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Schedules a local notification for when the step is done.")
                }
            }
            .padding()
            .background(Color.Stir.paper100, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func timerControlRow(for timer: CookTimer) -> some View {
        HStack(spacing: 12) {
            switch timer.typedState {
            case .running:
                Button {
                    Task { await viewModel.pauseTimer(timer) }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
            case .paused:
                Button {
                    Task { await viewModel.resumeTimer(timer) }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
            case .pending, .completed, .cancelled:
                EmptyView()
            }
            Button(role: .destructive) {
                Task { await viewModel.cancelTimer(timer) }
            } label: {
                Label("Cancel", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
        }
        .stirFont(.labelMd).fontWeight(.medium)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            voiceRow
            // Secondary row — "Ask" opens Substitution Sheet.
            Button {
                viewModel.requestSubstitution()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.bubble")
                    Text("Something missing?")
                        .stirFont(.labelMd).fontWeight(.medium)
                }
                .foregroundStyle(Color.Stir.ink900)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Substitute a missing ingredient")

            // Primary row — Prev / Next.
            HStack(spacing: 12) {
                Button {
                    viewModel.previousStep()
                } label: {
                    HStack { Image(systemName: "arrow.left"); Text("Previous") }
                        .stirFont(.labelLg).fontWeight(.semibold)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isFirstStep)
                .accessibilityLabel("Previous step")

                Button {
                    if viewModel.isLastStep {
                        viewModel.finish()
                    } else {
                        viewModel.nextStep()
                    }
                } label: {
                    HStack {
                        Text(viewModel.isLastStep ? "Finish" : "Next")
                        Image(systemName: viewModel.isLastStep ? "checkmark" : "arrow.right")
                    }
                    .stirFont(.labelLg).fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(viewModel.isLastStep ? "Finish cooking" : "Next step")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
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
    private var voiceRow: some View {
        Button {
            Task { await viewModel.handleMicTap() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: micIconName)
                    .stirFont(.labelLg).fontWeight(.semibold)
                    .accessibilityHidden(true)
                Text(micLabel)
                    .stirFont(.labelLg).fontWeight(.semibold)
                if viewModel.micButtonRole == .busy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(micTint)
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

    private var micTint: Color {
        switch viewModel.micButtonRole {
        case .submit, .busy, .listening: return .red
        case .askWithVoice:              return .accentColor
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

