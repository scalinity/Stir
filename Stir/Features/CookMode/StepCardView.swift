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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Exit Cook Mode")

            Spacer()

            Text(viewModel.recipePlan.title ?? "Cook Mode")
                .font(.subheadline.weight(.semibold))
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
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let step = viewModel.currentStep, let title = step.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
        }
    }

    private var instructionBody: some View {
        Text(viewModel.currentStep?.instructionText ?? "")
            .font(.title2)
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
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                let matching = viewModel.activeTimers.first { $0.step?.id == step.id }
                if let timer = matching {
                    TimerCountdownView(timer: timer)
                    timerControlRow(for: timer)
                } else {
                    Button {
                        Task { await viewModel.startTimerForCurrentStep() }
                    } label: {
                        Label("Start \(Int(step.timerSeconds) / 60) min timer", systemImage: "timer")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Schedules a local notification for when the step is done.")
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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
        .font(.subheadline.weight(.medium))
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            // Secondary row — "Ask" opens Substitution Sheet.
            Button {
                viewModel.requestSubstitution()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.bubble")
                    Text("Something missing?")
                        .font(.subheadline.weight(.medium))
                }
                .foregroundStyle(.primary)
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
                        .font(.headline)
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
                    .font(.headline)
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
}
