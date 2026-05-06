// VoiceModeTutorial
//
// First-run tutorial for hands-free voice cooking. Three steps:
//   1. How  — animated waveform with mic pill
//   2. What — cycling voice-command examples
//   3. When — Premium+ entitlement context
//
// Mounted on `VoiceActiveStepView` via `.tutorial(key: .voiceMode, ...)`.

import OSLog
import SwiftUI

struct VoiceModeTutorial: View {
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
        case how = 0
        case what = 1
        case when = 2

        var telemetryID: String {
            switch self {
            case .how:  return "how"
            case .what: return "what"
            case .when: return "when"
            }
        }
    }

    @State private var isAdvancing = false
    @State private var didFireStarted = false

    var body: some View {
        TutorialFlowContainer(
            initialStep: Step.how,
            onComplete: { resolve(skipped: false) },
            onSkip: { resolve(skipped: true) },
            onStepAdvance: { from, to in
                posthog.capture(.tutorialStepAdvanced, properties: [
                    "tutorial_id": TutorialKey.voiceMode.telemetryID,
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
                "tutorial_id": TutorialKey.voiceMode.telemetryID,
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
                primaryAction: advance,
                skipAction: skip,
            ) {
                VoiceCommandsMiniature()
            }
        case .when:
            TutorialStepView(
                icon: Image.Stir.tierCrown,
                headline: "Voice is Premium+",
                message: "Tap Cook Mode is unlimited and free. Voice sessions live on Premium and Pro — 13/mo and 27/mo.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                EntitlementMiniature()
            }
        }
    }

    @MainActor
    private func resolve(skipped: Bool) {
        guard !isAdvancing else { return }
        isAdvancing = true
        manager.markCompleted(.voiceMode)
        let event: TelemetryEvent = skipped ? .tutorialSkipped : .tutorialCompleted
        posthog.capture(event, properties: [
            "tutorial_id": TutorialKey.voiceMode.telemetryID,
        ])
        Logger.ui.info(
            "voice_mode_tutorial_resolved skipped=\(skipped, privacy: .public)",
        )
        dismiss()
    }
}

// MARK: - Step miniatures

private struct ListeningPillMiniature: View {
    @State private var t: CGFloat = 0

    private let bars = 9

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 4) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(Color.Stir.ember600)
                        .frame(width: 4, height: barHeight(at: i))
                }
            }
            .frame(height: 52)

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
        .frame(maxWidth: 320)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                t = 1
            }
        }
        .accessibilityHidden(true)
    }

    /// Synthesized waveform — sine-shifted heights per bar so the row
    /// reads as a live audio meter without driving an actual capture
    /// pipeline.
    private func barHeight(at index: Int) -> CGFloat {
        let phase = (CGFloat(index) / CGFloat(bars)) * .pi * 2
        let wave = sin(phase + t * .pi * 2)
        let normalized = (wave + 1) / 2
        return 14 + normalized * 32
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
        .frame(maxWidth: 320)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

private struct EntitlementMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                tierBadge(tier: "Free", glyph: nil, accent: Color.Stir.paper200, value: "0", caption: "voice / mo")
                tierBadge(tier: "Premium", glyph: Image.Stir.premium, accent: Color.Stir.ember100, value: "13", caption: "voice / mo")
                tierBadge(tier: "Pro", glyph: Image.Stir.tierCrown, accent: Color.Stir.ember600.opacity(0.18), value: "27", caption: "voice / mo")
            }
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

    private func tierBadge(tier: String, glyph: Image?, accent: Color, value: String, caption: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                if let glyph {
                    glyph
                        .foregroundStyle(Color.Stir.ember600)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(tier)
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ink900)
            }
            Text(value)
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
            Text(caption)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent),
        )
    }
}

#Preview("VoiceModeTutorial") {
    VoiceModeTutorial()
}
