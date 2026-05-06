// DishPreviewTutorial
//
// First-run tutorial for the Dish Preview screen. Two steps:
//   1. Read — meta row + ingredients staggered in
//   2. Cook — Start Cooking CTA pulse
//
// Mounted on `DishPreviewView` via `.tutorial(key: .dishPreview, ...)`.

import SwiftUI

struct DishPreviewTutorial: View {
    enum Step: Int, TutorialStep {
        case read = 0
        case cook = 1

        var telemetryID: String {
            switch self {
            case .read: return "read"
            case .cook: return "cook"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .dishPreview, initialStep: Step.read) { step, advance, skip in
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
        case .read:
            TutorialStepView(
                icon: Image.Stir.cookbook,
                headline: "Read before you cook",
                message: "Skim ingredients, time, and pan. Heat means stove burners; servings tells you how big to make it.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                DishMetaMiniature()
            }
        case .cook:
            TutorialStepView(
                icon: Image.Stir.cook,
                headline: "Hit Start Cooking",
                message: "When you're ready, Start Cooking opens step-by-step Cook Mode with timers and (Premium+) voice.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                StartCookingMiniature()
            }
        }
    }
}

// MARK: - Step miniatures

private struct DishMetaMiniature: View {
    @State private var visible = false

    private let metas: [(icon: Image, label: String, value: String)] = [
        (Image.Stir.clock, "Time",     "25 min"),
        (Image.Stir.cook,  "Servings", "2"),
        (Image.Stir.heat,  "Heat",     "1 burner"),
    ]

    private let ingredients: [String] = [
        "1 lb spaghetti",
        "4 cloves garlic",
        "1 lemon, zested",
        "Olive oil, salt, parmesan",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                ForEach(Array(metas.enumerated()), id: \.element.label) { idx, meta in
                    VStack(spacing: 4) {
                        meta.icon
                            .foregroundStyle(Color.Stir.ember600)
                            .font(.system(size: 16, weight: .semibold))
                        Text(meta.value)
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                        Text(meta.label)
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink700)
                    }
                    .frame(maxWidth: .infinity)
                    .staggeredReveal(index: idx, isVisible: visible)
                }
            }
            .padding(.vertical, 4)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Ingredients")
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ink700)
                ForEach(Array(ingredients.enumerated()), id: \.element) { idx, ingredient in
                    HStack(spacing: 8) {
                        Image.Stir.check
                            .foregroundStyle(Color.Stir.ember600)
                            .font(.system(size: 12, weight: .semibold))
                        Text(ingredient)
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink900)
                        Spacer()
                    }
                    .staggeredReveal(index: idx + 3, isVisible: visible)
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

private struct StartCookingMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Lemon garlic pasta")
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ink700)

            HStack(spacing: 12) {
                Image.Stir.cook
                    .font(.system(size: 18, weight: .semibold))
                Text("Start cooking")
                    .stirFont(.bodyLg)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 30)
            .padding(.vertical, 14)
            .background(
                Capsule().fill(Color.Stir.ember600),
            )
            .tutorialPulsing(scale: 1.05, duration: 1.0)

            Text("Step-by-step · timers · voice (Premium+)")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
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

#Preview("DishPreviewTutorial") {
    DishPreviewTutorial()
}
