// PantryInListEmptyTutorial
//
// First-run tutorial for the in-list Pantry walkthrough WHEN the
// pantry has zero rows. Two steps:
//   1. Welcome — empty-pantry illustration with pulsing icon
//   2. Add     — pulsing "+" CTA mock pointing at the toolbar control
//
// Mounted on `PantryListView` via `.tutorial(key: .pantryInListTourEmpty, ...)`
// gated on `!pantryHasItems`. Distinct TutorialKey from the populated
// variant so each owns its own UserDefaults flag — completing the
// empty walkthrough on first install does NOT silently burn the
// populated-walkthrough bit (SCA-17 C4).

import SwiftUI

struct PantryInListEmptyTutorial: View {
    enum Step: Int, TutorialStep {
        case welcome = 0
        case add = 1

        var telemetryID: String {
            switch self {
            case .welcome: return "empty_welcome"
            case .add:     return "empty_add"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .pantryInListTourEmpty, initialStep: Step.welcome) { step, advance, skip in
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
        case .welcome:
            TutorialStepView(
                icon: Image.Stir.pantry,
                headline: "Your pantry is empty",
                message: "Once you scan the kitchen or add ingredients here, Stir remembers them — even after you cook.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                EmptyPantryMiniature()
            }
        case .add:
            TutorialStepView(
                icon: Image.Stir.plus,
                headline: "Add your first item",
                message: "Tap the + in the toolbar to add ingredients manually, or scan the kitchen from Tonight to populate the pantry in seconds.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                AddCTAMiniature()
            }
        }
    }
}

// MARK: - Step miniatures

private struct EmptyPantryMiniature: View {
    var body: some View {
        VStack(spacing: 12) {
            Image.Stir.pantry
                .foregroundStyle(Color.Stir.ember600.opacity(0.5))
                .font(.system(size: 56, weight: .semibold))
                .tutorialPulsing(scale: 1.05, duration: 1.4)
            Text("Empty for now")
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ink700)
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth, minHeight: 140)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .accessibilityHidden(true)
    }
}

private struct AddCTAMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.Stir.ember600)
                    .frame(width: 64, height: 64)
                    .tutorialPulsing(scale: 1.10, duration: 0.95)
                Image.Stir.plus
                    .foregroundStyle(Color.white)
                    .font(.system(size: 28, weight: .bold))
            }
            Text("Add ingredient")
                .stirFont(.labelMd)
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

#Preview("PantryInListEmptyTutorial") {
    PantryInListEmptyTutorial()
}
