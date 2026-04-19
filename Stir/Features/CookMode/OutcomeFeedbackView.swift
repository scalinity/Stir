// OutcomeFeedbackView — commit-6 stub.
//
// Commit 8 replaces this with the real 5-star rating + structured
// taxonomy UI that writes to OutcomeFeedbackRepository. For commit 6
// the stub exists so CookModeRoot can reference it; it dismisses
// cleanly so the flow can be verified end-to-end.

import SwiftUI

struct OutcomeFeedbackView: View {
    let session: CookingSession
    let onSubmitted: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "fork.knife.circle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Nice work!")
                    .font(.title2.weight(.semibold))
                Text("Feedback sheet lands in commit 8 — for now, tap Done to return.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done", action: onSubmitted)
                    .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .navigationTitle("Rate This Meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onSubmitted)
                }
            }
        }
    }
}
