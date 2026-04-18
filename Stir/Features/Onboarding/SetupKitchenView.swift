// SetupKitchenView
//
// Step 2 of onboarding: kitchen equipment + default servings + preferred
// units. Final "Continue" triggers `completeOnboarding()` which marks the
// HouseholdProfile onboardingCompleted flag.

import SwiftUI

struct SetupKitchenView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onComplete: () -> Void

    var body: some View {
        Form {
            Section {
                Text("Tap the gear you have. Stir won't suggest a recipe you can't cook.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section("Equipment") {
                ForEach(KitchenEquipment.CommonCode.allCases, id: \.self) { code in
                    Button {
                        if viewModel.selectedEquipment.contains(code) {
                            viewModel.selectedEquipment.remove(code)
                        } else {
                            viewModel.selectedEquipment.insert(code)
                        }
                    } label: {
                        HStack {
                            Text(code.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if viewModel.selectedEquipment.contains(code) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }

            Section("Cooking for") {
                Stepper(
                    "\(viewModel.servingsDefault) \(viewModel.servingsDefault == 1 ? "person" : "people")",
                    value: $viewModel.servingsDefault,
                    in: 1...12,
                )
            }

            Section("Measurements") {
                Picker("Preferred units", selection: $viewModel.preferredUnits) {
                    Text("Imperial (cups, °F)").tag(HouseholdProfile.PreferredUnits.imperial)
                    Text("Metric (grams, °C)").tag(HouseholdProfile.PreferredUnits.metric)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Your kitchen")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(action: onComplete) {
                Text("Finish setup")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canCompleteKitchenStep)
            .padding()
            .background(.thinMaterial)
        }
    }
}
