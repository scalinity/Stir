// WelcomeView
//
// First screen new users see. Two CTAs:
//   - "Try it now" → proceeds into Setup 1 (preferences).
//   - "See a sample" → bypasses onboarding with a sample Tonight Home.
//     Step 2 stubs the sample path (lands in step 3).

import SwiftUI

struct WelcomeView: View {
    let onTryIt: () -> Void
    let onSeeSample: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer(minLength: 40)

            VStack(spacing: 16) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tint)

                Text("Stir")
                    .font(.system(size: 44, weight: .semibold))

                Text("Dinner from what's already in your kitchen.")
                    .font(.title3.weight(.regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: onTryIt) {
                    Text("Try it now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onSeeSample) {
                    Text("See a sample")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground))
    }
}

#Preview {
    WelcomeView(onTryIt: {}, onSeeSample: {})
}
