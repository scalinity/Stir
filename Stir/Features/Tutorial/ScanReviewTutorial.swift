// ScanReviewTutorial
//
// First-run tutorial for the Scan Review screen. Three steps explaining
// how parsed ingredients land, how to fix what Stir got wrong, and the
// path to dinner solve.
//
// Mounted on `ScanReviewView` via `.tutorial(key: .scanReview, ...)`.

import SwiftUI

struct ScanReviewTutorial: View {
    enum Step: Int, TutorialStep {
        case confidence = 0
        case edit = 1
        case solve = 2

        var telemetryID: String {
            switch self {
            case .confidence: return "confidence"
            case .edit:       return "edit"
            case .solve:      return "solve"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .scanReview, initialStep: Step.confidence) { step, advance, skip in
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
        case .confidence:
            TutorialStepView(
                icon: Image.Stir.success,
                headline: "Confirmed vs needs review",
                message: "Stir splits what it found into Confirmed and Needs Review. Confirmed chips are ready; review chips have a question mark.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                ConfidenceMiniature()
            }
        case .edit:
            TutorialStepView(
                icon: Image.Stir.edit,
                headline: "Tap any chip to fix it",
                message: "Tap to edit the name, swipe to remove, or use Add to fill in something Stir missed.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                EditChipMiniature()
            }
        case .solve:
            TutorialStepView(
                icon: Image.Stir.cook,
                headline: "Solve dinner when you're ready",
                message: "When the list looks right, hit Solve. Stir gives you three dinners ranked by what fits.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                SolveCTAMiniature()
            }
        }
    }
}

// MARK: - Step miniatures

private struct ConfidenceMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            chipBucket(
                title: "Confirmed",
                titleIcon: Image.Stir.success,
                titleTint: Color.Stir.ember600,
                chips: [("Onion", true), ("Garlic", true), ("Olive oil", true)],
                startIndex: 0,
            )
            chipBucket(
                title: "Needs review",
                titleIcon: Image.Stir.lowConfidence,
                titleTint: Color.Stir.ink700,
                chips: [("Cilantro?", false), ("Bell pepper?", false)],
                startIndex: 3,
            )
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

    @ViewBuilder
    private func chipBucket(
        title: String,
        titleIcon: Image,
        titleTint: Color,
        chips: [(String, Bool)],
        startIndex: Int,
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                titleIcon
                    .foregroundStyle(titleTint)
                Text(title)
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ink700)
            }
            HStack(spacing: 6) {
                ForEach(Array(chips.enumerated()), id: \.element.0) { idx, chip in
                    Text(chip.0)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink900)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                chip.1 ? Color.Stir.ember100 : Color.Stir.paper200,
                            ),
                        )
                        .staggeredReveal(index: startIndex + idx, isVisible: visible)
                }
            }
        }
    }
}

private struct EditChipMiniature: View {
    @State private var tapped = false

    var body: some View {
        VStack(spacing: 18) {
            Text("Tap to try it")
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ink700)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                    tapped.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image.Stir.edit
                        .font(.system(size: 14, weight: .semibold))
                    Text("Cilantro")
                        .stirFont(.bodyMd)
                }
                .foregroundStyle(Color.Stir.ink900)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(tapped ? Color.Stir.ember600.opacity(0.25) : Color.Stir.ember100),
                )
                .overlay(
                    Capsule().stroke(
                        tapped ? Color.Stir.ember600 : Color.clear,
                        lineWidth: 2,
                    ),
                )
                .scaleEffect(tapped ? 1.08 : 1.0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Demo: tap to edit a chip")

            if tapped {
                HStack(spacing: 12) {
                    actionPill(icon: Image.Stir.edit, label: "Edit")
                    actionPill(icon: Image.Stir.delete, label: "Remove")
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth, minHeight: 140)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
    }

    private func actionPill(icon: Image, label: String) -> some View {
        HStack(spacing: 6) {
            icon.font(.system(size: 13, weight: .semibold))
            Text(label).stirFont(.bodySm)
        }
        .foregroundStyle(Color.Stir.ink900)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.Stir.paper200))
    }
}

private struct SolveCTAMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 16) {
            Text("8 ingredients ready")
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ink700)

            HStack(spacing: 12) {
                Image.Stir.cook
                    .font(.system(size: 18, weight: .semibold))
                Text("Solve dinner")
                    .stirFont(.bodyLg)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(Color.Stir.ember600),
            )
            .tutorialPulsing(scale: 1.05, duration: 1.0)
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .tutorialFadeIn(isVisible: visible)
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

#Preview("ScanReviewTutorial") {
    ScanReviewTutorial()
}
