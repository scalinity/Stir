// StepCard
//
// Cook Mode's core execution surface — full-screen card that a tired
// home cook glances at from across the counter (Specs/Design-System.md
// §8.9 + mockups 06 / 07). Composes several primitives:
//
//   - Step N of M progress row at top
//   - Optional displayMd step title
//   - bodyLg step instruction (the one place body text goes large —
//     §4.1 "Cook Mode step instruction is the one place body text goes
//     large")
//   - Optional timer chip with play/pause
//   - PrimaryButton Next Step at the bottom
//   - Secondary row: Previous / Ask / Exit
//   - Mic affordance top-right ONLY when voiceEnabled (Premium+ gate)
//
// NOT wired into CookModeRoot / CookModeViewModel in Phase 2 per
// step-9 plan Q9 — voice concurrent-agent is editing those files
// actively. Phase 3 mockup-06/07 turn handles integration.
//
// Dark-mode shadow: spec §5.5 sanctions ONE shadow in dark mode, and
// it's this card. Use StirShadow.cookStepCard(for: colorScheme) at
// render time.
//
// `timerState` is optional and opaque — caller passes a snapshot tuple
// so StepCard stays stateless. TimerService / CookTimerRepository
// drives timer values at the view-model level.

import SwiftUI

/// Minimal timer snapshot passed to StepCard. Keeps the component
/// stateless — it doesn't tick its own clock, it renders whatever the
/// caller hands it.
struct StepCardTimer: Equatable {
    /// Pre-formatted "MM:SS" string. Caller handles formatting so the
    /// card doesn't own the format.
    let display: String
    /// `true` if ticking, `false` if paused.
    let isRunning: Bool
    let onToggle: () -> Void

    static func == (lhs: StepCardTimer, rhs: StepCardTimer) -> Bool {
        lhs.display == rhs.display && lhs.isRunning == rhs.isRunning
    }
}

struct StepCard: View {
    let stepNumber: Int
    let stepCount: Int
    let title: String?
    let instruction: String
    let timer: StepCardTimer?
    let voiceEnabled: Bool
    let isMicActive: Bool
    let onNext: () -> Void
    let onPrevious: (() -> Void)?
    let onAsk: () -> Void
    let onExit: () -> Void
    let onMicToggle: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    init(
        stepNumber: Int,
        stepCount: Int,
        title: String? = nil,
        instruction: String,
        timer: StepCardTimer? = nil,
        voiceEnabled: Bool = false,
        isMicActive: Bool = false,
        onNext: @escaping () -> Void,
        onPrevious: (() -> Void)? = nil,
        onAsk: @escaping () -> Void,
        onExit: @escaping () -> Void,
        onMicToggle: (() -> Void)? = nil,
    ) {
        self.stepNumber = stepNumber
        self.stepCount = stepCount
        self.title = title
        self.instruction = instruction
        self.timer = timer
        self.voiceEnabled = voiceEnabled
        self.isMicActive = isMicActive
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onAsk = onAsk
        self.onExit = onExit
        self.onMicToggle = onMicToggle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
            progressRow
            instructionBlock
            if let timer {
                timerChip(timer)
            }
            Spacer(minLength: CGFloat.Stir.space4)
            actionStack
        }
        .padding(CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stirCard(radius: CGFloat.Stir.radiusLg)
        .stirShadow(StirShadow.cookStepCard(for: colorScheme))
    }

    // MARK: - Sections

    private var progressRow: some View {
        HStack(alignment: .center) {
            Text("Step \(stepNumber) of \(stepCount)")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)

            Spacer()

            if voiceEnabled, let onMicToggle {
                Button(action: onMicToggle) {
                    (isMicActive ? Image.Stir.micActive : Image.Stir.micIdle)
                        .font(.system(size: CGFloat.Stir.iconMd, weight: .semibold))
                        .foregroundStyle(isMicActive ? Color.Stir.voice600 : Color.Stir.ink700)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(isMicActive ? Color.Stir.voice100 : Color.Stir.paper200),
                        )
                }
                .accessibilityLabel(isMicActive ? "Stop listening" : "Start voice assistant")
            }
        }
    }

    private var instructionBlock: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            if let title {
                Text(title)
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
            }
            Text(instruction)
                .stirFont(.bodyLg)
                .foregroundStyle(Color.Stir.ink900)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timerChip(_ timer: StepCardTimer) -> some View {
        Button(action: timer.onToggle) {
            HStack(spacing: CGFloat.Stir.space2) {
                (timer.isRunning ? Image.Stir.pause : Image.Stir.play)
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ember600)

                Text(timer.display)
                    .stirFont(.monoMd)
                    .foregroundStyle(Color.Stir.ink900)
                    .monospacedDigit()
            }
            .padding(.horizontal, CGFloat.Stir.space3)
            .padding(.vertical, CGFloat.Stir.space2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.Stir.ember100),
            )
        }
        .accessibilityLabel(timer.isRunning
                            ? "Timer running, \(timer.display) remaining, tap to pause"
                            : "Timer paused at \(timer.display), tap to resume")
    }

    private var actionStack: some View {
        VStack(spacing: CGFloat.Stir.space3) {
            PrimaryButton(title: "Next Step", action: onNext)

            HStack(spacing: CGFloat.Stir.space3) {
                if let onPrevious {
                    SecondaryButton(title: "Previous", action: onPrevious)
                }
                SecondaryButton(title: "Ask", action: onAsk)
                SecondaryButton(title: "Exit", action: onExit)
            }
        }
    }
}

// MARK: - Previews

#Preview("StepCard — light") {
    stepCardGallery
        .preferredColorScheme(.light)
}

#Preview("StepCard — dark") {
    stepCardGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var stepCardGallery: some View {
    VStack(spacing: CGFloat.Stir.space4) {
        StepCard(
            stepNumber: 3,
            stepCount: 7,
            title: "Sear the chicken",
            instruction: "Heat 1 tbsp olive oil in a wide pan over medium-high. Add the harissa-rubbed chicken thighs skin-side down. Don't crowd the pan — work in batches if needed.",
            timer: StepCardTimer(display: "04:23", isRunning: true, onToggle: {}),
            voiceEnabled: true,
            isMicActive: false,
            onNext: {},
            onPrevious: {},
            onAsk: {},
            onExit: {},
            onMicToggle: {},
        )
    }
    .padding(CGFloat.Stir.space4)
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
