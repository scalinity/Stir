// PantryInListPopulatedTutorial
//
// First-run tutorial for the in-list Pantry walkthrough WHEN the
// pantry has rows. Three steps:
//   1. Welcome — search-cycle demo (search bar mocks typing "spin")
//   2. States  — memory-state row reveals (Stocked / Used / Expired)
//   3. Impact  — stat blocks + pantry-friendly dinner badge
//
// Mounted on `PantryListView` via `.tutorial(key: .pantryInListTour, ...)`
// gated on `pantryHasItems`. The empty-pantry variant lives in a
// sibling file (`PantryInListEmptyTutorial`) under a separate
// `TutorialKey` so each surface owns its own UserDefaults flag and
// completing one does NOT silently consume the other (SCA-17 C4).

import SwiftUI

struct PantryInListPopulatedTutorial: View {
    enum Step: Int, TutorialStep {
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

    var body: some View {
        TutorialFlowHost(key: .pantryInListTour, initialStep: Step.welcome) { step, advance, skip in
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
}

// MARK: - Step miniatures

private struct PantrySearchMiniature: View {
    @State private var visible = false
    @State private var query = ""
    @State private var queryIndex = 0

    private let queries = ["s", "sp", "spi", "spin"]

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
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .tutorialFadeIn(isVisible: visible)
        .onAppear { visible = true }
        // SCA-28 C1 — `.task` modifier is auto-cancelled on view
        // disappear and on `.id(currentStep)` remount, replacing the
        // earlier unstructured `Task { @MainActor in while … }` that
        // accumulated leaked sleeping tasks across replay cycles.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                queryIndex = (queryIndex + 1) % (queries.count + 1)
                query = queryIndex < queries.count ? queries[queryIndex] : ""
            }
        }
        .accessibilityHidden(true)
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
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
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

#Preview("PantryInListPopulatedTutorial") {
    PantryInListPopulatedTutorial()
}
