// DinnerOptionsTutorial
//
// First-run tutorial for the Dinner Options screen. Two steps:
//   1. Choose — three dish cards staggered in
//   2. Why    — tap a card → reveals "fits your pantry" reasons
//
// Mounted on `DinnerOptionsView` via `.tutorial(key: .dinnerOptions, ...)`.

import OSLog
import SwiftUI

struct DinnerOptionsTutorial: View {
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
        case choose = 0
        case why = 1

        var telemetryID: String {
            switch self {
            case .choose: return "choose"
            case .why:    return "why"
            }
        }
    }

    @State private var isAdvancing = false
    @State private var didFireStarted = false

    var body: some View {
        TutorialFlowContainer(
            initialStep: Step.choose,
            onComplete: { resolve(skipped: false) },
            onSkip: { resolve(skipped: true) },
            onStepAdvance: { from, to in
                posthog.capture(.tutorialStepAdvanced, properties: [
                    "tutorial_id": TutorialKey.dinnerOptions.telemetryID,
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
                "tutorial_id": TutorialKey.dinnerOptions.telemetryID,
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
        case .choose:
            TutorialStepView(
                icon: Image.Stir.cook,
                headline: "Three ranked dinners",
                message: "Stir gives you three options sorted by what fits your pantry, time, and mood.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                DishCardsMiniature()
            }
        case .why:
            TutorialStepView(
                icon: Image.Stir.info,
                headline: "Tap a card to see why it fits",
                message: "Each dinner shows a fit label — Pantry-friendly, Quick, or Comfort — plus the reasons it ranked here.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                WhyItFitsMiniature()
            }
        }
    }

    @MainActor
    private func resolve(skipped: Bool) {
        guard !isAdvancing else { return }
        isAdvancing = true
        manager.markCompleted(.dinnerOptions)
        let event: TelemetryEvent = skipped ? .tutorialSkipped : .tutorialCompleted
        posthog.capture(event, properties: [
            "tutorial_id": TutorialKey.dinnerOptions.telemetryID,
        ])
        Logger.ui.info(
            "dinner_options_tutorial_resolved skipped=\(skipped, privacy: .public)",
        )
        dismiss()
    }
}

// MARK: - Step miniatures

private struct DishCardsMiniature: View {
    @State private var visible = false

    private let dishes: [(title: String, fit: String, time: String)] = [
        ("Lemon garlic pasta", "Pantry-friendly", "20 min"),
        ("Sheet-pan chicken",  "Quick",            "25 min"),
        ("Veggie stir-fry",    "Healthy",          "15 min"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(dishes.enumerated()), id: \.element.title) { index, dish in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Stir.ember100)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image.Stir.cook
                                .foregroundStyle(Color.Stir.ember600)
                                .font(.system(size: 22, weight: .semibold)),
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dish.title)
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                        HStack(spacing: 6) {
                            Text(dish.fit)
                                .stirFont(.bodySm)
                                .foregroundStyle(Color.Stir.ember600)
                            Text("·")
                                .foregroundStyle(Color.Stir.ink700)
                            Text(dish.time)
                                .stirFont(.bodySm)
                                .foregroundStyle(Color.Stir.ink700)
                        }
                    }
                    Spacer()
                    Image.Stir.disclosure
                        .foregroundStyle(Color.Stir.ink700)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.Stir.paper100),
                )
                .staggeredReveal(index: index, isVisible: visible)
            }
        }
        .frame(maxWidth: 320)
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

private struct WhyItFitsMiniature: View {
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    expanded.toggle()
                }
            } label: {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.Stir.ember100)
                            .frame(width: 48, height: 48)
                            .overlay(
                                Image.Stir.cook
                                    .foregroundStyle(Color.Stir.ember600)
                                    .font(.system(size: 22, weight: .semibold)),
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Lemon garlic pasta")
                                .stirFont(.bodyMd)
                                .foregroundStyle(Color.Stir.ink900)
                            Text("Pantry-friendly · 20 min")
                                .stirFont(.bodySm)
                                .foregroundStyle(Color.Stir.ink700)
                        }
                        Spacer()
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(Color.Stir.ink700)
                    }
                    if expanded {
                        VStack(alignment: .leading, spacing: 6) {
                            reasonRow(icon: Image.Stir.success, text: "Uses 7 of 8 pantry items")
                            reasonRow(icon: Image.Stir.heat,    text: "One pan, one boil")
                            reasonRow(icon: Image.Stir.quick,   text: "Under 25 min")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.Stir.paper100),
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Demo: tap to expand the dish details")

            if !expanded {
                Text("Tap the card to expand")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink700)
            }
        }
        .frame(maxWidth: 320)
    }

    private func reasonRow(icon: Image, text: String) -> some View {
        HStack(spacing: 8) {
            icon
                .foregroundStyle(Color.Stir.ember600)
                .font(.system(size: 14, weight: .semibold))
            Text(text)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink900)
        }
    }
}

#Preview("DinnerOptionsTutorial") {
    DinnerOptionsTutorial()
}
