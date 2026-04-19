// SubstitutionSheetView — commit-6 stub.
//
// Commit 7 replaces this with the real picker + AI-dispatched
// substitution UI. For commit 6 the stub exists so CookModeRoot can
// reference it without a compile error; it displays a placeholder and
// dismisses cleanly so the Cook Mode flow can be verified end-to-end.

import SwiftUI

struct SubstitutionSheetView: View {
    let recipePlan: RecipePlan
    let household: HouseholdProfile
    let session: CookingSession
    let currentStep: RecipeStep?
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Substitution sheet lands next commit")
                    .font(.headline)
                Text("Commit 7 wires AIDispatch.substitution into this sheet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Close", action: onDismiss)
                    .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .navigationTitle("Substitute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                }
            }
        }
    }
}
