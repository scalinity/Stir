// WidgetNudgeCard
//
// SCA-250 (W2 from /review-5): extracted from TonightHomeView.swift.
// See `UseSoonCard.swift` for the broader rationale around the
// extraction (SCA-86/87 inlined three view types as `private struct`s
// inside the same file SCA-94 had just refactored to clear the
// SwiftUI typecheck ceiling).
//
// Visual: ember-tinted card prompting the user to add a Stir widget
// to their Home Screen. Two-button row: "Show me how" routes to
// WidgetSetupGuideView (Premium+) or the widgets paywall gate (Free);
// "Not now" defers the prompt via WidgetNudgeService.recordDeferred().

import SwiftUI

struct WidgetNudgeCard: View {
    let onGuide: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
                Image.Stir.widget
                    .font(.system(size: CGFloat.Stir.iconLg, weight: .semibold))
                    .foregroundStyle(Color.Stir.ember600)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                            .fill(Color.Stir.ember100),
                    )

                VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                    Text("Put Stir on your Home Screen")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink900)
                    Text("Jump back to tonight's dinner ideas from a widget.")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: CGFloat.Stir.space2) {
                Button(action: onGuide) {
                    Label("Show me how", systemImage: "square.grid.2x2")
                        .stirFont(.labelMd)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.Stir.ember600)

                Button("Not now", action: onDismiss)
                    .stirFont(.labelMd)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink700)
                    .frame(minWidth: 86)
                    .buttonStyle(.plain)
                    .padding(.vertical, CGFloat.Stir.space2)
            }
        }
        .padding(CGFloat.Stir.space4)
        .stirCard(
            fill: Color.Stir.paper100,
            borderColor: Color.Stir.ember600.opacity(0.25),
        )
    }
}

// MARK: - Previews

#Preview("WidgetNudgeCard") {
    WidgetNudgeCard(onGuide: {}, onDismiss: {})
        .padding()
        .background(Color.Stir.paper50)
}
