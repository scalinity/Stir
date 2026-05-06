// CookModeTapTutorial
//
// First-run tutorial for tap Cook Mode. Three steps:
//   1. Step    — fake step card with current instruction
//   2. Advance — tap Next → fake step card slides in
//   3. Timer   — animated timer with flame pulse
//
// Mounted on `StepCardView` via `.tutorial(key: .cookModeTap, ...)`.

import OSLog
import SwiftUI

struct CookModeTapTutorial: View {
    @Environment(\.dismiss) private var dismiss

    private let manager: TutorialManager
    private let posthog: PostHogClient

    init(
        manager: TutorialManager = .shared,
        posthog: PostHogClient = .shared,
    ) {
        self.manager = manager
        self.posthog = posthog
    }

    enum Step: Int, TutorialStep {
        case step = 0
        case advance = 1
        case timer = 2

        var telemetryID: String {
            switch self {
            case .step:    return "step"
            case .advance: return "advance"
            case .timer:   return "timer"
            }
        }
    }

    @State private var isAdvancing = false
    @State private var didFireStarted = false

    var body: some View {
        TutorialFlowContainer(
            initialStep: Step.step,
            onComplete: { resolve(skipped: false) },
            onSkip: { resolve(skipped: true) },
            onStepAdvance: { from, to in
                posthog.capture(.tutorialStepAdvanced, properties: [
                    "tutorial_id": TutorialKey.cookModeTap.telemetryID,
                    "from_step": from.telemetryID,
                    "to_step": to.telemetryID,
                ])
            },
        ) { step, advance, skip in
            stepContent(step, advance: advance, skip: skip)
        }
        .onAppear {
            guard !didFireStarted else { return }
            didFireStarted = true
            posthog.capture(.tutorialStarted, properties: [
                "tutorial_id": TutorialKey.cookModeTap.telemetryID,
            ])
        }
    }

    @ViewBuilder
    private func stepContent(
        _ step: Step,
        advance: @escaping () -> Void,
        skip: @escaping () -> Void,
    ) -> some View {
        switch step {
        case .step:
            TutorialStepView(
                icon: Image.Stir.cookbook,
                headline: "One step at a time",
                message: "Cook Mode shows the current step in big type so you can read it from the stove.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                StepCardMiniature()
            }
        case .advance:
            TutorialStepView(
                icon: Image.Stir.arrowRight,
                headline: "Tap Next to advance",
                message: "Hit Next when you're done. Tap Back if you missed something.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                AdvanceMiniature()
            }
        case .timer:
            TutorialStepView(
                icon: Image.Stir.timer,
                headline: "Timers run inline",
                message: "Step asking for 8 min? Tap the timer chip — it counts down right where you're cooking.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                TimerMiniature()
            }
        }
    }

    @MainActor
    private func resolve(skipped: Bool) {
        guard !isAdvancing else { return }
        isAdvancing = true
        manager.markCompleted(.cookModeTap)
        let event: TelemetryEvent = skipped ? .tutorialSkipped : .tutorialCompleted
        posthog.capture(event, properties: [
            "tutorial_id": TutorialKey.cookModeTap.telemetryID,
        ])
        Logger.ui.info(
            "cook_mode_tap_tutorial_resolved skipped=\(skipped, privacy: .public)",
        )
        dismiss()
    }
}

// MARK: - Step miniatures

private struct StepCardMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STEP 2 OF 6")
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ember600)
                .staggeredReveal(index: 0, isVisible: visible)
            Text("Sauté garlic in olive oil until fragrant, about 90 seconds.")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.leading)
                .staggeredReveal(index: 1, isVisible: visible)
            HStack(spacing: 8) {
                Image.Stir.heat
                    .foregroundStyle(Color.Stir.ember600)
                Text("Medium heat")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink700)
            }
            .staggeredReveal(index: 2, isVisible: visible)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

private struct AdvanceMiniature: View {
    @State private var stepIndex = 1
    private let total = 4

    var body: some View {
        VStack(spacing: 14) {
            Text("STEP \(stepIndex + 1) OF \(total)")
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ember600)
            Text(currentInstruction)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.center)
                .frame(minHeight: 56)
                .id(stepIndex)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity),
                    ),
                )

            HStack(spacing: 10) {
                pillButton("Back") {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        stepIndex = max(0, stepIndex - 1)
                    }
                }
                .opacity(stepIndex == 0 ? 0.4 : 1)
                .disabled(stepIndex == 0)

                pillButton("Next", filled: true) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        stepIndex = min(total - 1, stepIndex + 1)
                    }
                }
                .tutorialPulsing(scale: 1.04, duration: 1.0)
            }
        }
        .frame(maxWidth: 320)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .animation(.easeInOut(duration: 0.25), value: stepIndex)
    }

    private var currentInstruction: String {
        [
            "Boil 4 quarts of salted water.",
            "Sauté garlic in olive oil 90 sec.",
            "Add pasta, cook to al dente.",
            "Toss with lemon zest. Plate hot.",
        ][stepIndex]
    }

    private func pillButton(_ label: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .stirFont(.bodyMd)
                .foregroundStyle(filled ? Color.white : Color.Stir.ink900)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(filled ? Color.Stir.ember600 : Color.Stir.paper200),
                )
        }
        .buttonStyle(.plain)
    }
}

private struct TimerMiniature: View {
    @State private var visible = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.Stir.ember600.opacity(0.25), lineWidth: 4)
                    .frame(width: 56, height: 56)
                Circle()
                    .trim(from: 0, to: 0.65)
                    .stroke(Color.Stir.ember600, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 56, height: 56)
                Image.Stir.heat
                    .foregroundStyle(Color.Stir.ember600)
                    .font(.system(size: 18, weight: .semibold))
                    .tutorialPulsing(scale: 1.10, duration: 0.85)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Simmer until reduced")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink900)
                Text("3:12 remaining")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ember600)
            }
            Spacer()
        }
        .frame(maxWidth: 320)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .opacity(visible ? 1 : 0)
        .onAppear { visible = true }
        .animation(.easeOut(duration: 0.4), value: visible)
        .accessibilityHidden(true)
    }
}

#Preview("CookModeTapTutorial") {
    CookModeTapTutorial()
}
