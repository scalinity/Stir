// ConfigurationErrorView
//
// Shown when AppConfig.load() throws or bootstrap returns a fatal error
// (VAL-01, Core Data corruption, etc.). Retry button invokes coordinator
// .retry(). Copy per spec §6 VAL-01 row (developer-safe generic).

import SwiftUI

struct ConfigurationErrorView: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.orange)

            VStack(spacing: 12) {
                Text("Something went wrong")
                    .font(.title.weight(.semibold))

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            if let onRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
            }

            Link("Contact support", destination: URL(string: "mailto:scalinity.ai@gmail.com?subject=Stir%20Startup%20Issue")!)
                .font(.footnote)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    ConfigurationErrorView(
        message: "Please try again or contact support.",
        onRetry: {},
    )
}
