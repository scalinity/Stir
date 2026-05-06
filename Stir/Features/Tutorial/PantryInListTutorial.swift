// PantryInListTutorial
//
// First-run tutorial for the in-list Pantry walkthrough. Variant-aware:
//   • populated — search → states → solve impact (3 steps)
//   • empty     — welcome → why → first-add prompt (2 steps)
//
// Mounted on `PantryListView` via `.tutorial(key: pantryHasItems ? .pantryInListTour : .pantryInListTourEmpty)`.
//
// Both tutorial keys map to this single view; `variant` selects the
// step set. Variant-prefixed telemetry IDs (`populated_*`, `empty_*`)
// keep PostHog cohorts split so dashboards don't conflate the two
// surfaces — same convention SCA-14 introduced.

import OSLog
import SwiftUI

struct PantryInListTutorial: View {
    @Environment(\.dismiss) private var dismiss

    enum Variant {
        case populated, empty

        var key: TutorialKey {
            switch self {
            case .populated: return .pantryInListTour
            case .empty:     return .pantryInListTourEmpty
            }
        }
    }

    let variant: Variant
    private let manager: TutorialManager
    private let posthog: PostHogClient

    init(
        variant: Variant,
        manager: TutorialManager = .shared,
        posthog: PostHogClient = .shared,
    ) {
        self.variant = variant
        self.manager = manager
        self.posthog = posthog
    }

    @State private var isAdvancing = false
    @State private var didFireStarted = false

    var body: some View {
        Group {
            switch variant {
            case .populated:
                populatedFlow
            case .empty:
                emptyFlow
            }
        }
        .onAppear {
            guard !didFireStarted else { return }
            didFireStarted = true
            posthog.capture(.tutorialStarted, properties: [
                "tutorial_id": variant.key.telemetryID,
            ])
        }
    }

    // MARK: - Populated flow (3 steps)

    private var populatedFlow: some View {
        TutorialFlowContainer(
            initialStep: PopulatedStep.welcome,
            onComplete: { resolve(skipped: false) },
            onSkip: { resolve(skipped: true) },
            onStepAdvance: { from, to in
                posthog.capture(.tutorialStepAdvanced, properties: [
                    "tutorial_id": variant.key.telemetryID,
                    "from_step": from.telemetryID,
                    "to_step": to.telemetryID,
                ])
            },
        ) { step, advance, skip in
            populatedStepContent(step, advance: advance, skip: skip)
        }
    }

    enum PopulatedStep: Int, TutorialStep {
        case welcome = 0
        case states = 1
        case impact = 2

        var telemetryID: String {
            switch self {
            case .welcome: return "populated_welcome"
            case .states:  return "populated_states"
            case .impact:  return "populated_impact"
            }
        }
    }

    @ViewBuilder
    private func populatedStepContent(
        _ step: PopulatedStep,
        advance: @escaping () -> Void,
        skip: @escaping () -> Void,
    ) -> some View {
        switch step {
        case .welcome:
            TutorialStepView(
                icon: Image.Stir.pantry,
                headline: "Your pantry, organized",
                message: "Search to find anything fast, sort by recency or name, and tap an item to edit details.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                PantrySearchMiniature()
            }
        case .states:
            TutorialStepView(
                icon: Image.Stir.success,
                headline: "Stocked, used, expired",
                message: "Each item carries a memory state. Stir uses it to suggest dinners — used items don't show up in solves.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                MemoryStateMiniature()
            }
        case .impact:
            TutorialStepView(
                icon: Image.Stir.cook,
                headline: "Better pantry, better dinners",
                message: "Keep the list current and Stir gets smarter at suggesting what you can actually make tonight.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                ImpactMiniature()
            }
        }
    }

    // MARK: - Empty flow (2 steps)

    private var emptyFlow: some View {
        TutorialFlowContainer(
            initialStep: EmptyStep.welcome,
            onComplete: { resolve(skipped: false) },
            onSkip: { resolve(skipped: true) },
            onStepAdvance: { from, to in
                posthog.capture(.tutorialStepAdvanced, properties: [
                    "tutorial_id": variant.key.telemetryID,
                    "from_step": from.telemetryID,
                    "to_step": to.telemetryID,
                ])
            },
        ) { step, advance, skip in
            emptyStepContent(step, advance: advance, skip: skip)
        }
    }

    enum EmptyStep: Int, TutorialStep {
        case welcome = 0
        case add = 1

        var telemetryID: String {
            switch self {
            case .welcome: return "empty_welcome"
            case .add:     return "empty_add"
            }
        }
    }

    @ViewBuilder
    private func emptyStepContent(
        _ step: EmptyStep,
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

    // MARK: - Resolution

    @MainActor
    private func resolve(skipped: Bool) {
        guard !isAdvancing else { return }
        isAdvancing = true
        manager.markCompleted(variant.key)
        let event: TelemetryEvent = skipped ? .tutorialSkipped : .tutorialCompleted
        posthog.capture(event, properties: [
            "tutorial_id": variant.key.telemetryID,
        ])
        Logger.ui.info(
            "pantry_in_list_tutorial_resolved variant=\(String(describing: variant), privacy: .public) skipped=\(skipped, privacy: .public)",
        )
        dismiss()
    }
}

// MARK: - Step miniatures

private struct PantrySearchMiniature: View {
    @State private var visible = false
    @State private var query = ""
    private let queries = ["s", "sp", "spi", "spin"]
    @State private var queryIndex = 0

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image.Stir.search
                    .foregroundStyle(Color.Stir.ink700)
                Text(query.isEmpty ? "Search pantry" : query)
                    .stirFont(.bodyMd)
                    .foregroundStyle(query.isEmpty ? Color.Stir.ink700 : Color.Stir.ink900)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.Stir.paper200),
            )

            VStack(spacing: 6) {
                searchResultRow(name: "Spinach", icon: Image.Stir.leaf)
                    .opacity(query.lowercased().contains("sp") ? 1 : 0.3)
                searchResultRow(name: "Spaghetti", icon: Image.Stir.cook)
                    .opacity(query.lowercased().contains("sp") ? 1 : 0.3)
                searchResultRow(name: "Garlic", icon: Image.Stir.cook)
                    .opacity(query.isEmpty ? 1 : 0.15)
            }
            .animation(.easeInOut(duration: 0.25), value: query)
        }
        .frame(maxWidth: 320)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .opacity(visible ? 1 : 0)
        .onAppear {
            visible = true
            cycleQuery()
        }
        .animation(.easeOut(duration: 0.4), value: visible)
        .accessibilityHidden(true)
    }

    private func cycleQuery() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                queryIndex = (queryIndex + 1) % (queries.count + 1)
                query = queryIndex < queries.count ? queries[queryIndex] : ""
            }
        }
    }

    private func searchResultRow(name: String, icon: Image) -> some View {
        HStack(spacing: 10) {
            icon
                .foregroundStyle(Color.Stir.ember600)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20)
            Text(name)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink900)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.Stir.paper200.opacity(0.5)),
        )
    }
}

private struct MemoryStateMiniature: View {
    @State private var visible = false

    private let items: [(name: String, state: String, tint: Color)] = [
        ("Spinach", "Stocked", Color.Stir.ember600),
        ("Pasta",   "Stocked", Color.Stir.ember600),
        ("Eggs",    "Used",    Color.Stir.ink700),
        ("Yogurt",  "Expired", .red),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.name) { idx, item in
                HStack(spacing: 10) {
                    Circle()
                        .fill(item.tint)
                        .frame(width: 8, height: 8)
                    Text(item.name)
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink900)
                    Spacer()
                    Text(item.state)
                        .stirFont(.bodySm)
                        .foregroundStyle(item.tint)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Stir.paper200.opacity(0.5)),
                )
                .staggeredReveal(index: idx, isVisible: visible)
            }
        }
        .frame(maxWidth: 320)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

private struct ImpactMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 24) {
                statBlock(value: "12", caption: "items stocked")
                statBlock(value: "3", caption: "dinners ready")
            }
            HStack(spacing: 10) {
                Image.Stir.cook
                    .foregroundStyle(Color.Stir.ember600)
                Text("Pantry-friendly · 25 min")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink900)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.Stir.ember100),
            )
        }
        .frame(maxWidth: 320)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .opacity(visible ? 1 : 0)
        .onAppear { visible = true }
        .animation(.easeOut(duration: 0.4), value: visible)
        .accessibilityHidden(true)
    }

    private func statBlock(value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ember600)
            Text(caption)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)
        }
    }
}

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
        .frame(maxWidth: 320, minHeight: 140)
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
        .frame(maxWidth: 320)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .opacity(visible ? 1 : 0)
        .onAppear { visible = true }
        .animation(.easeOut(duration: 0.4), value: visible)
        .accessibilityHidden(true)
    }
}

#Preview("PantryInListTutorial — populated") {
    PantryInListTutorial(variant: .populated)
}

#Preview("PantryInListTutorial — empty") {
    PantryInListTutorial(variant: .empty)
}
