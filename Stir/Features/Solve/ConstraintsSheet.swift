// ConstraintsSheet
//
// Quick-set constraints before solving: time budget, cuisine lean, goal.
// "Use first" and "Avoid equipment" are advanced knobs; step 3 exposes
// them via free-text chip input. Step 4's Saved Meals surfaces more
// presets for common goals ("weeknight fast", "date night").
//
// Previously rendered as a stock SwiftUI `Form` with default grouping,
// default row chrome, and a Menu picker. Rebuilt in step-7 review (W30 /
// FD1) as a tokenized VStack + InputField + SelectableChip pattern so
// the sheet inherits the app's card/pill grammar instead of reading as
// a Settings-style form.

import SwiftUI

struct ConstraintsSheet: View {
    @Bindable var viewModel: SolveViewModel
    @Environment(\.dismiss) private var dismiss
    let onSolve: () -> Void

    @State private var maxTimeIndex: Int = 2 // 30 min default
    @State private var cuisine: String = ""
    @State private var goalDraft: String = ""

    /// 5 time-budget preset pills. The first preset is "Any" (nil
    /// maxTimeMinutes); the rest are bounded caps. Index into the
    /// parallel `maxTimeOptions` array; keeping the two aligned lets
    /// the ForEach iterate indices without a separate preset struct.
    private let maxTimeOptions: [Int?] = [nil, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    timeBudgetSection
                    cuisineSection
                    goalSection
                    Spacer(minLength: CGFloat.Stir.space3)
                    solveButton
                }
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.top, CGFloat.Stir.space4)
                .padding(.bottom, CGFloat.Stir.space5)
            }
            .background(Color.Stir.paper50)
            // Keep `navigationTitle` for the back-chevron label +
            // VoiceOver; the visible title comes from the .principal
            // toolbar item below in the Stir display serif. Default
            // chrome would render in SF Pro Bold and break the
            // cross-screen rhythm (matches Settings / Saved / Pantry).
            .navigationTitle("Tonight's constraints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text("Tonight's constraints")
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.textPrimary)
                }
            }
            .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Sections

    private var timeBudgetSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Time budget")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            // Horizontal flow; wraps to two rows on smaller widths
            // because the pills collectively exceed the viewport at
            // Dynamic Type XL+ (spec §6 requires XXXL support).
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CGFloat.Stir.space2) {
                    ForEach(0 ..< maxTimeOptions.count, id: \.self) { idx in
                        SelectableChip(
                            label: label(for: maxTimeOptions[idx]),
                            tone: .accent,
                            isSelected: maxTimeIndex == idx,
                            action: { maxTimeIndex = idx },
                        )
                    }
                }
            }
        }
    }

    private var cuisineSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Cuisine lean")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            InputField(
                placeholder: "e.g. Italian, quick Thai, comfort",
                text: $cuisine,
                autocapitalization: .sentences,
            )
        }
    }

    private var goalSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Tonight's goal")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            InputField(
                placeholder: "optional — e.g. \"use up the salmon\"",
                text: $goalDraft,
                autocapitalization: .sentences,
            )
        }
    }

    private var solveButton: some View {
        PrimaryButton(
            title: "Find me dinner",
            isDisabled: viewModel.ingredientsForSolve.isEmpty,
            action: {
                commit()
                onSolve()
                dismiss()
            },
        )
    }

    // MARK: - Helpers

    private func label(for minutes: Int?) -> String {
        guard let m = minutes else { return "Any" }
        return "\(m)m"
    }

    private func commit() {
        viewModel.constraints.maxTimeMinutes = maxTimeOptions[maxTimeIndex]
        viewModel.constraints.cuisineLeaning = cuisine.isEmpty ? nil : cuisine
        viewModel.constraints.goal = goalDraft.isEmpty ? nil : goalDraft
        PostHogClient.shared.capture(.constraintsSet, properties: [
            "has_max_time": viewModel.constraints.maxTimeMinutes != nil,
            "has_cuisine": viewModel.constraints.cuisineLeaning != nil,
            "has_goal": viewModel.constraints.goal != nil,
            "use_first_count": viewModel.constraints.useFirst.count,
            "avoid_equipment_count": viewModel.constraints.avoidEquipment.count,
        ])
    }
}
