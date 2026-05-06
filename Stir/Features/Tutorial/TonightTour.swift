// TonightTour
//
// Four-step Tonight Home feature tour. Presented once per install via
// `.tutorial(key:content:shouldPresent:manager:)` after the
// setup-onboarding flow completes. Lifecycle scaffolding (started/
// step/completed/skipped telemetry, `markCompleted`, dismiss) lives
// in `TutorialFlowHost` — see `Stir/DesignSystem/Components/
// TutorialFlowHost.swift`. Steps: intro → solve → saved → settings.

import SwiftUI

struct TonightTour: View {
    enum Step: Int, TutorialStep {
        case intro = 0
        case solve = 1
        case saved = 2
        case settings = 3

        /// Snake_case telemetry token. Inlined here (rather than a
        /// separate `extension … { var telemetryID }`) so adding a
        /// new step gives an exhaustiveness compile error for free.
        var telemetryID: String {
            switch self {
            case .intro:    return "intro"
            case .solve:    return "solve"
            case .saved:    return "saved"
            case .settings: return "settings"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .tonightTour, initialStep: Step.intro) { step, advance, skip in
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
        case .intro:
            TutorialStepView(
                icon: Image.Stir.sparkles,
                headline: "Welcome to Stir",
                message: "Here's a 30-second tour of where everything lives. You can skip any time.",
                primaryAction: advance,
                skipAction: skip,
            )
        case .solve:
            TutorialStepView(
                icon: Image.Stir.scan,
                headline: "Scan, then solve dinner",
                message: "Tap Solve dinner on Tonight Home to scan your kitchen. Stir gives you three dinners ranked by what fits.",
                primaryAction: advance,
                skipAction: skip,
            )
        case .saved:
            TutorialStepView(
                icon: Image.Stir.bookmark,
                headline: "Save the wins",
                message: "Bookmark a meal you liked and it lands in the Saved tab — ready to cook again on a tired night.",
                primaryAction: advance,
                skipAction: skip,
            )
        case .settings:
            TutorialStepView(
                icon: Image.Stir.gear,
                headline: "Tune as you go",
                message: "Update dietary rules, equipment, and your plan in Settings any time.",
                primaryLabel: "Start cooking",
                primaryAction: advance,
            )
        }
    }
}

#Preview("TonightTour") {
    TonightTour()
}
