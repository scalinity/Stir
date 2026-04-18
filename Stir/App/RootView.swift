// RootView
//
// Placeholder top-level view. Replaced with the RootCoordinator in commit 9
// once identity resolution, bootstrap, and entitlement hydration are wired.
// Until then this exists so the app compiles and launches cleanly.

import SwiftUI

struct RootView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "fork.knife")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("Stir")
                .font(.largeTitle.weight(.semibold))
            Text("Step-2 scaffold — Root coordinator lands in commit 9.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    RootView()
}
