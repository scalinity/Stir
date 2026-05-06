// VoiceModeTutorial
//
// First-run tutorial for hands-free voice cooking. Two steps:
//   1. How  — animated waveform with mic pill
//   2. What — cycling voice-command examples
//
// Mounted on `StepCardView`'s voice-active branch (which wraps
// `VoiceActiveStepView`) via `.tutorial(key: .voiceMode, ...)`.
//
// SCA-41 — the prior third step ("Voice is Premium+", a static
// Free/Premium/Pro cap table) was dropped because the same context
// already lands on the user via the `voiceAffordanceTapped` paywall
// (Free user taps the voice affordance → fullScreenCover with live
// pricing, Premium trial CTA, and an unconditional "Compare plans"
// button that opens the Pro comparison sheet). The tutorial step
// duplicated information without the live pricing or purchase CTA.

import SwiftUI

struct VoiceModeTutorial: View {
    enum Step: Int, TutorialStep {
        case how = 0
        case what = 1

        var telemetryID: String {
            switch self {
            case .how:  return "how"
            case .what: return "what"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .voiceMode, initialStep: Step.how) { step, advance, skip in
            stepContent(step, advance: advance, skip: skip)
        }
    }

    @ViewBuilder
    private func stepContent(
        _ step: Step,
        advance: @escaping () -> Void,
        skip: @escaping () -> Void,
    ) -> some View {
        switch step {
        case .how:
            TutorialStepView(
                icon: Image.Stir.micActive,
                headline: "Hands-free cooking",
                message: "Stir listens while you cook. Hands greasy? Just talk. The pill at the bottom shows whether the mic is live.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                ListeningPillMiniature()
            }
        case .what:
            TutorialStepView(
                icon: Image.Stir.voiceWave,
                headline: "What Stir understands",
                message: "Reference, not invitation — keep cooking. These are the kinds of things Stir picks up.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                VoiceCommandsMiniature()
            }
        }
    }
}

// MARK: - Step miniatures

private struct ListeningPillMiniature: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let bars = 9
    private let cycleSeconds: TimeInterval = 1.6

    var body: some View {
        VStack(spacing: 18) {
            // SCA-28 C3 — drive the bars from a `TimelineView(.animation)`
            // so each frame reads the current time and recomputes
            // heights. The previous `withAnimation(.repeatForever)` +
            // `@State t` approach was visually static because
            // `barHeight` uses `sin(phase + t·2π)`, so SwiftUI snapshot
            // heights at `t=0` and `t=1` (which differ by exactly one
            // sine period — equal values) and interpolated between
            // them. Reduce-motion collapses to a static snapshot.
            TimelineView(.animation(paused: reduceMotion)) { context in
                let phase: Double = reduceMotion
                    ? 0
                    : context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: cycleSeconds)
                        / cycleSeconds
                HStack(spacing: 4) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule()
                            .fill(Color.Stir.ember600)
                            .frame(width: 4, height: barHeight(at: i, phase: phase))
                    }
                }
                .frame(height: 52)
            }

            HStack(spacing: 10) {
                Image.Stir.micActive
                    .foregroundStyle(Color.white)
                    .font(.system(size: 14, weight: .semibold))
                Text("Listening")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.Stir.ember600),
            )
            .tutorialPulsing(scale: 1.04, duration: 1.0)
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .accessibilityHidden(true)
    }

    /// Synthesized waveform — sine-shifted heights per bar so the row
    /// reads as a live audio meter without driving an actual capture
    /// pipeline. `phase` is the [0, 1) cycle position from the
    /// TimelineView; bars are offset by their index.
    private func barHeight(at index: Int, phase: Double) -> CGFloat {
        let perBarOffset = (Double(index) / Double(bars)) * .pi * 2
        let wave = sin(perBarOffset + phase * .pi * 2)
        let normalized = (wave + 1) / 2
        return 14 + CGFloat(normalized) * 32
    }
}

private struct VoiceCommandsMiniature: View {
    @State private var visible = false

    private let commands: [String] = [
        "\u{201C}What's the next step?\u{201D}",
        "\u{201C}Set a timer for 8 minutes.\u{201D}",
        "\u{201C}Repeat that.\u{201D}",
        "\u{201C}Substitute the cilantro.\u{201D}",
        "\u{201C}Pause everything.\u{201D}",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image.Stir.voiceWave
                        .foregroundStyle(Color.Stir.ember600)
                        .font(.system(size: 13, weight: .semibold))
                    Text(command)
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink900)
                    Spacer()
                }
                .staggeredReveal(index: index, isVisible: visible)
            }
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

#Preview("VoiceModeTutorial") {
    VoiceModeTutorial()
}
