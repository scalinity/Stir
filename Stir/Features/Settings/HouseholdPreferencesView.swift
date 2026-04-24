// HouseholdPreferencesView
//
// Settings → Household preferences. Edits the same three sections as
// onboarding (allergens/diets/goals + equipment + servings/units). Backed
// by a fresh OnboardingViewModel instance so writes share the repository
// layer's idempotency + uniqueness guards.

import SwiftUI

struct HouseholdPreferencesView: View {
    @Environment(CurrentHouseholdStore.self) private var householdStore
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: OnboardingViewModel?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let viewModel {
                Form {
                    preferencesSection(viewModel: viewModel)
                    equipmentSection(viewModel: viewModel)
                    servingsSection(viewModel: viewModel)
                }
                .navigationTitle("Household preferences")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            Task {
                                do {
                                    try viewModel.savePreferences()
                                    try viewModel.saveKitchen()
                                    dismiss()
                                } catch {
                                    errorMessage = ErrorPresenter.present(.sync01).message
                                }
                            }
                        }
                        .fontWeight(.semibold)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task {
            guard viewModel == nil, let profile = householdStore.profile else { return }
            viewModel = OnboardingViewModel(profile: profile)
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } },
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func preferencesSection(viewModel: OnboardingViewModel) -> some View {
        @Bindable var bindable = viewModel
        Section("Dietary") {
            dietaryRow(options: AllergenOption.allCases, selection: $bindable.selectedAllergens, label: "Allergies", valueLabel: { $0.displayName })
            dietaryRow(options: DietOption.allCases, selection: $bindable.selectedDiets, label: "Diet", valueLabel: { $0.displayName })
            dietaryRow(options: GoalOption.allCases, selection: $bindable.selectedGoals, label: "Goals", valueLabel: { $0.displayName })
        }
    }

    private func dietaryRow<Value: Hashable>(
        options: [Value],
        selection: Binding<Set<Value>>,
        label: String,
        valueLabel: @escaping (Value) -> String,
    ) -> some View {
        NavigationLink {
            List(options, id: \.self) { option in
                Button {
                    if selection.wrappedValue.contains(option) {
                        selection.wrappedValue.remove(option)
                    } else {
                        selection.wrappedValue.insert(option)
                    }
                } label: {
                    HStack {
                        Text(valueLabel(option))
                        Spacer()
                        if selection.wrappedValue.contains(option) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.Stir.ember600)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(label)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(label) {
                Text(selection.wrappedValue.isEmpty ? "None" : "\(selection.wrappedValue.count) selected")
                    .foregroundStyle(Color.Stir.ink500)
            }
        }
    }

    @ViewBuilder
    private func equipmentSection(viewModel: OnboardingViewModel) -> some View {
        @Bindable var bindable = viewModel
        Section("Equipment") {
            NavigationLink {
                List(KitchenEquipment.CommonCode.allCases, id: \.self) { code in
                    Button {
                        if bindable.selectedEquipment.contains(code) {
                            bindable.selectedEquipment.remove(code)
                        } else {
                            bindable.selectedEquipment.insert(code)
                        }
                    } label: {
                        HStack {
                            Text(code.displayName)
                            Spacer()
                            if bindable.selectedEquipment.contains(code) {
                                Image(systemName: "checkmark").foregroundStyle(Color.Stir.ember600)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle("Equipment")
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                LabeledContent("Equipment") {
                    Text(bindable.selectedEquipment.isEmpty
                         ? "None"
                         : "\(bindable.selectedEquipment.count) selected")
                        .foregroundStyle(Color.Stir.ink500)
                }
            }
        }
    }

    @ViewBuilder
    private func servingsSection(viewModel: OnboardingViewModel) -> some View {
        @Bindable var bindable = viewModel
        Section("Serving") {
            Stepper(
                "\(bindable.servingsDefault) \(bindable.servingsDefault == 1 ? "person" : "people")",
                value: $bindable.servingsDefault,
                in: 1...12,
            )
            Picker("Preferred units", selection: $bindable.preferredUnits) {
                Text("Imperial").tag(HouseholdProfile.PreferredUnits.imperial)
                Text("Metric").tag(HouseholdProfile.PreferredUnits.metric)
            }
            .pickerStyle(.segmented)
        }
    }
}
