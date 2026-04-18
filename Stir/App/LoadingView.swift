// LoadingView
//
// Launch skeleton shown while RootCoordinator.bootstrap() runs.
// Not a blank screen per step-2 prompt's "loading state during launch
// with a skeleton, not a blank screen" requirement.

import SwiftUI

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "fork.knife")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, options: .repeating)

            Text("Stir")
                .font(.largeTitle.weight(.semibold))

            ProgressView()
                .controlSize(.regular)
                .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    LoadingView()
}
