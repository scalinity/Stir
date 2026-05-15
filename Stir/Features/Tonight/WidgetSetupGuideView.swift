// WidgetSetupGuideView
//
// SCA-250 (W2 from /review-5): extracted from TonightHomeView.swift.
// See `UseSoonCard.swift` for the broader extraction rationale.
//
// Sheet-shaped (SCA-251 / W3) instructional surface mounted via
// `.sheet(isPresented:)` on TonightHomeView's body — three numbered
// steps for adding a Stir widget to the iOS Home Screen.

import SwiftUI

struct WidgetSetupGuideView: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                    Image.Stir.widgetFill
                        .font(.system(size: CGFloat.Stir.iconHero, weight: .regular))
                        .foregroundStyle(Color.Stir.ember600)
                        .frame(maxWidth: .infinity)
                        .padding(.top, CGFloat.Stir.space5)

                    VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                        Text("Add Stir as a widget")
                            .stirFont(.displayMd)
                            .foregroundStyle(Color.Stir.ink900)
                        Text("Keep tonight's ideas one tap away from your Home Screen.")
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink500)
                    }

                    guideStep("1", "Touch and hold your Home Screen until the apps jiggle.")
                    guideStep("2", "Tap the plus button and search for Stir.")
                    guideStep("3", "Choose a widget size, then tap Add Widget.")

                    PrimaryButton(title: "Done", action: onDone)
                        .padding(.top, CGFloat.Stir.space2)
                }
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.bottom, CGFloat.Stir.space7)
            }
            .background(Color.Stir.paper50)
            .navigationTitle("Widget setup")
            .navigationBarTitleDisplayMode(.inline)
            // SCA-457: custom top bar escapes iOS 26 Liquid Glass.
            .stirTopBar(
                trailing: {
                    StirTopBarTextButton("Done", action: onDone)
                },
            )
        }
    }

    private func guideStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            Text(number)
                .stirFont(.labelMd)
                .fontWeight(.bold)
                .foregroundStyle(Color.Stir.paper50)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.Stir.ember600))
            Text(text)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink900)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(CGFloat.Stir.space4)
        .stirCard()
    }
}

// MARK: - Previews

#Preview("WidgetSetupGuideView") {
    WidgetSetupGuideView(onDone: {})
}
