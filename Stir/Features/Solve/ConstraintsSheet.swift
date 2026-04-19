// ConstraintsSheet
//
// Quick-set constraints before solving: time budget, cuisine lean, goal.
// "Use first" and "Avoid equipment" are advanced knobs; step 3 exposes
// them via free-text chip input. Step 4's Saved Meals surfaces more
// presets for common goals ("weeknight fast", "date night").

import SwiftUI

struct ConstraintsSheet: View {
    @Bindable var viewModel: SolveViewModel
    @Environment(\.dismiss) private var dismiss
    let onSolve: () -> Void

    @State private var maxTimeIndex: Int = 2  // 30 min default
    @State private var cuisine: String = ""
    @State private var goalDraft: String = ""

    private let maxTimeOptions: [Int?] = [nil, 15, 30, 45, 60]

    var body: some View {
        NavigationStack {
            Form {
                Section("Time budget") {
                    Picker("Max cook time", selection: $maxTimeIndex) {
                        ForEach(0..<maxTimeOptions.count, id: \.self) { idx in
                            Text(label(for: maxTimeOptions[idx])).tag(idx)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Cuisine lean") {
                    TextField("e.g. Italian, quick Thai, comfort", text: $cuisine)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Tonight's goal") {
                    TextField("optional — e.g. \"use up the salmon\"", text: $goalDraft)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    Button {
                        commit()
                        onSolve()
                        dismiss()
                    } label: {
                        Text("Find dinners")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.ingredientsForSolve.isEmpty)
                }
            }
            .navigationTitle("Tonight's constraints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

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
