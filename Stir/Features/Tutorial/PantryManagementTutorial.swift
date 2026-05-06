// PantryManagementTutorial
//
// First-run tutorial for the Settings → Manage pantry entry. Two steps:
//   1. Why — pantry items appearing staggered (basket fills up)
//   2. How — edit/remove gesture demo with pencil & trash
//
// Mounted on `SettingsRootView` via `.tutorial(key: .pantryManagement, ...)`.

import SwiftUI

struct PantryManagementTutorial: View {
    enum Step: Int, TutorialStep {
        case why = 0
        case how = 1

        var telemetryID: String {
            switch self {
            case .why: return "why"
            case .how: return "how"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .pantryManagement, initialStep: Step.why) { step, advance, skip in
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
        case .why:
            TutorialStepView(
                icon: Image.Stir.pantry,
                headline: "Your kitchen, remembered",
                message: "Stir keeps a pantry of what you've scanned and added. We use it to suggest dinners you can actually make.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                PantryFillingMiniature()
            }
        case .how:
            TutorialStepView(
                icon: Image.Stir.edit,
                headline: "Edit, remove, or mark used",
                message: "Open Manage pantry to fix what Stir got wrong, mark items as used so they stop showing up in suggestions, or remove anything you no longer have.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                PantryRowEditMiniature()
            }
        }
    }
}

// MARK: - Step miniatures

private struct PantryFillingMiniature: View {
    @State private var visible = false

    // SCA-32 — capped at 4 items so total miniature height fits on
    // iPhone-class screens without compressing the TutorialFlowContainer
    // layout. 6 items pushed the progress dots up under the status-bar
    // dynamic island. Four items still conveys "Stir keeps a pantry."
    private let items: [(icon: Image, name: String)] = [
        (Image.Stir.leaf,   "Spinach"),
        (Image.Stir.cook,   "Garlic"),
        (Image.Stir.heat,   "Olive oil"),
        (Image.Stir.pantry, "Eggs"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image.Stir.pantry
                    .foregroundStyle(Color.Stir.ember600)
                Text("My pantry")
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ink700)
                Spacer()
                Text("\(items.count) items")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink700)
            }

            VStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.name) { index, item in
                    HStack(spacing: 10) {
                        item.icon
                            .foregroundStyle(Color.Stir.ember600)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 22)
                        Text(item.name)
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                        Spacer()
                        Image.Stir.success
                            .foregroundStyle(Color.Stir.ember600.opacity(0.6))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.Stir.paper200.opacity(0.5)),
                    )
                    .staggeredReveal(index: index, isVisible: visible, perItemDelay: 0.06)
                }
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

private struct PantryRowEditMiniature: View {
    @State private var swiped = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Drag to try it")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)

            ZStack(alignment: .trailing) {
                HStack(spacing: 10) {
                    actionDisc(icon: Image.Stir.edit, tint: Color.Stir.ember600)
                    actionDisc(icon: Image.Stir.delete, tint: .red)
                }
                .padding(.trailing, 8)

                HStack(spacing: 10) {
                    Image.Stir.leaf
                        .foregroundStyle(Color.Stir.ember600)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 26)
                    Text("Cilantro")
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink900)
                    Spacer()
                    Text("Stocked")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ember600)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.Stir.paper200),
                )
                .offset(x: swiped ? -110 : 0)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                                swiped = value.translation.width < -30
                            }
                        },
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        swiped.toggle()
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
    }

    private func actionDisc(icon: Image, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 36, height: 36)
            icon
                .foregroundStyle(tint)
                .font(.system(size: 14, weight: .semibold))
        }
    }
}

#Preview("PantryManagementTutorial") {
    PantryManagementTutorial()
}
