// ScanCaptureTutorial
//
// First-run tutorial for Scan capture. Three steps with animated
// miniatures of the camera workflow:
//   1. Aim     — viewfinder reticle pulsing inward
//   2. Snap    — fake shutter button pulse
//   3. Wait    — ingredient chips popping in staggered
//
// Mounted on `ScanCaptureView` via `.tutorial(key: .scanCapture, ...)`.

import SwiftUI

struct ScanCaptureTutorial: View {
    enum Step: Int, TutorialStep {
        case aim = 0
        case snap = 1
        case wait = 2

        var telemetryID: String {
            switch self {
            case .aim:  return "aim"
            case .snap: return "snap"
            case .wait: return "wait"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .scanCapture, initialStep: Step.aim) { step, advance, skip in
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
        case .aim:
            TutorialStepView(
                icon: Image.Stir.scan,
                headline: "Frame your counter",
                message: "Aim the camera at your ingredients — counter, fridge shelf, pantry door. Stir reads what's in frame.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                ViewfinderMiniature()
            }
        case .snap:
            TutorialStepView(
                icon: Image.Stir.camera,
                headline: "Tap the shutter",
                message: "Hit the shutter button to capture. You can scan multiple shots before solving.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                ShutterMiniature()
            }
        case .wait:
            TutorialStepView(
                icon: Image.Stir.success,
                headline: "Stir reads it in seconds",
                message: "Ingredients land as chips you can confirm, edit, or remove before we solve dinner.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                IngredientChipsMiniature()
            }
        }
    }
}

// MARK: - Step miniatures

private struct ViewfinderMiniature: View {
    @State private var visible = false

    var body: some View {
        ZStack {
            // Phone-frame backdrop — paper200 disc that anchors the
            // viewfinder visually inside a "device".
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.Stir.paper200)
                .frame(width: 220, height: 160)

            // Corner-bracket viewfinder reticle. Pulses to call
            // attention to the framing affordance.
            ViewfinderReticle()
                .stroke(Color.Stir.ember600, lineWidth: 2.5)
                .frame(width: 160, height: 110)
                .tutorialPulsing(scale: 1.04, duration: 1.4)

            // Center crosshair dot.
            Circle()
                .fill(Color.Stir.ember600)
                .frame(width: 6, height: 6)
        }
        .frame(maxWidth: .infinity)
        .tutorialFadeIn(isVisible: visible)
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

/// Four L-shaped corner brackets — the universal "framing" affordance.
private struct ViewfinderReticle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let armLength: CGFloat = 18
        let r = rect

        // Top-left
        path.move(to: CGPoint(x: r.minX, y: r.minY + armLength))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.minX + armLength, y: r.minY))
        // Top-right
        path.move(to: CGPoint(x: r.maxX - armLength, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + armLength))
        // Bottom-right
        path.move(to: CGPoint(x: r.maxX, y: r.maxY - armLength))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - armLength, y: r.maxY))
        // Bottom-left
        path.move(to: CGPoint(x: r.minX + armLength, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - armLength))

        return path
    }
}

private struct ShutterMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 24) {
            // Mini camera-preview band — paper200 rectangle hinting at
            // a live preview above the shutter.
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper200)
                .frame(width: 220, height: 90)
                .overlay {
                    HStack(spacing: 6) {
                        Image.Stir.leaf.foregroundStyle(Color.Stir.ember600.opacity(0.6))
                        Image.Stir.heat.foregroundStyle(Color.Stir.ember600.opacity(0.4))
                        Image.Stir.cook.foregroundStyle(Color.Stir.ember600.opacity(0.3))
                    }
                    .font(.system(size: 28, weight: .semibold))
                }

            // Shutter button — concentric rings, inner disc pulses to
            // mimic the affordance the user is being told to tap.
            ZStack {
                Circle()
                    .stroke(Color.Stir.ink900.opacity(0.15), lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Color.Stir.ember600)
                    .frame(width: 56, height: 56)
                    .tutorialPulsing(scale: 1.10, duration: 0.95)
                Image.Stir.camera
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
        }
        .tutorialFadeIn(isVisible: visible)
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

private struct IngredientChipsMiniature: View {
    @State private var visible = false

    private let chips: [(icon: Image, label: String)] = [
        (Image.Stir.leaf, "Spinach"),
        (Image.Stir.cook, "Garlic"),
        (Image.Stir.heat, "Olive oil"),
        (Image.Stir.leaf, "Lemon"),
        (Image.Stir.pantry, "Eggs"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image.Stir.success
                    .foregroundStyle(Color.Stir.ember600)
                Text("Confirmed")
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ink700)
            }

            ChipFlowLayout(spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.element.label) { index, chip in
                    HStack(spacing: 6) {
                        chip.icon
                            .font(.system(size: 13, weight: .semibold))
                        Text(chip.label)
                            .stirFont(.bodySm)
                    }
                    .foregroundStyle(Color.Stir.ink900)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.Stir.ember100),
                    )
                    .staggeredReveal(index: index, isVisible: visible)
                }
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

#Preview("ScanCaptureTutorial") {
    ScanCaptureTutorial()
}
