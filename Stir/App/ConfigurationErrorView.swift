// ConfigurationErrorView
//
// Shown when AppConfig.load() throws or bootstrap returns a fatal error
// (VAL-01, Core Data corruption, etc.). Retry button invokes coordinator
// .retry(). Copy per spec §6 VAL-01 row (developer-safe generic).
//
// Turn 13 token migration: mockup 17 "Errors / permissions" visual
// grammar — rust.600 soft-error glyph (§3.1 soft recoverable) +
// displayLg title + bodyMd body + PrimaryButton retry + TextButton
// support link.

import SwiftUI

struct ConfigurationErrorView: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(spacing: CGFloat.Stir.space5) {
            Spacer()

            Image.Stir.softError
                .font(.system(size: 56, weight: .regular)) // justification: hero error glyph — one-off per §4.1
                .foregroundStyle(Color.Stir.rust600)

            VStack(spacing: CGFloat.Stir.space3) {
                Text("Something went wrong")
                    .stirFont(.displayLg)
                    .foregroundStyle(Color.Stir.ink900)

                Text(message)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink500)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, CGFloat.Stir.space6)
            }

            Spacer()

            if let onRetry {
                PrimaryButton(title: "Retry", action: onRetry)
                    .padding(.horizontal, CGFloat.Stir.space5)
            }

            Link(
                destination: URL(string: "mailto:scalinity.ai@gmail.com?subject=Stir%20Startup%20Issue")!,
            ) {
                Text("Contact support")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ember600)
            }
            .padding(.bottom, CGFloat.Stir.space6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
    }
}

#Preview("Configuration error — light") {
    ConfigurationErrorView(
        message: "Please try again or contact support.",
        onRetry: {},
    )
    .frame(width: 390, height: 844)
    .preferredColorScheme(.light)
}

#Preview("Configuration error — dark") {
    ConfigurationErrorView(
        message: "Please try again or contact support.",
        onRetry: {},
    )
    .frame(width: 390, height: 844)
    .preferredColorScheme(.dark)
}
