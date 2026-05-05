// TonightTour
//
// Four-step Tonight Home feature tour. Presented once per install via
// `TutorialPresenterModifier` (see DesignSystem/Components/TutorialPresenter)
// after the setup-onboarding flow completes.
//
// Steps: intro → solve → saved → settings. Skip + Done both terminate
// via `manager.markCompleted(.tonightTour)` and `dismiss()` — never
// silently abandon a presented tour.
//
// Resolution latch (`isAdvancing`) follows the OnboardingRoot precedent
// for double-tap defense. Started-event latch (`didFireStarted`) keeps
// telemetry in sync across `onAppear` retries within a single
// presentation.

import OSLog
import SwiftUI

struct TonightTour: View {
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

    @State private var isAdvancing = false
    @State private var didFireStarted = false

    var body: some View {
        TutorialFlowContainer(
            initialStep: Step.intro,
            onComplete: { resolve(skipped: false) },
            onSkip: { resolve(skipped: true) },
            onStepAdvance: { from, to in
                posthog.capture(.tutorialStepAdvanced, properties: [
                    "tutorial_id": TutorialKey.tonightTour.telemetryID,
                    "from_step": from.telemetryID,
                    "to_step": to.telemetryID,
                ])
            },
        ) { step, advance, skip in
            stepContent(step, advance: advance, skip: skip)
        }
        .onAppear {
            // `onAppear` may fire multiple times for the same view
            // instance (system overlays, re-attachment); we want
            // exactly one `tutorial_started` per presentation. The
            // cover content is torn down + rebuilt across each
            // present cycle, so this `@State` resets correctly when
            // the user replays from Settings.
            guard !didFireStarted else { return }
            didFireStarted = true
            posthog.capture(.tutorialStarted, properties: [
                "tutorial_id": TutorialKey.tonightTour.telemetryID,
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

    @MainActor
    private func resolve(skipped: Bool) {
        guard !isAdvancing else { return }
        isAdvancing = true
        manager.markCompleted(.tonightTour)
        let event: TelemetryEvent = skipped ? .tutorialSkipped : .tutorialCompleted
        posthog.capture(event, properties: [
            "tutorial_id": TutorialKey.tonightTour.telemetryID,
        ])
        Logger.ui.info(
            "tonight_tour_resolved skipped=\(skipped, privacy: .public)",
        )
        dismiss()
    }
}

// MARK: - Previews

#Preview("TonightTour") {
    TonightTour()
}
