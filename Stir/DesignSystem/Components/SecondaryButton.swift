// SecondaryButton
//
// Important-but-not-hero action (Specs/Design-System.md §8.1). Used
// anywhere two actions compete for attention and one belongs to a step
// below the PrimaryButton — "Previous" in Cook Mode, "Cancel" on sheets,
// "Use Sample Photo" on scan permission deny, "Compare plans" on Paywall.
//
// Visual grammar:
//   - paper.100 fill (same tone as card surface — reads as "interactive
//     but restrained")
//   - ink.900 label in `.labelLg` + semibold override
//   - 1pt ink.100 hairline border (matches card elevation pattern §5.5)
//   - 52pt fixed height matching PrimaryButton — stacks evenly when two
//     buttons appear side-by-side
//   - radius.md (12pt) per §5.4
//
// Never stack two PrimaryButtons; this is the second-button answer.

import SwiftUI

struct SecondaryButton: View {
    let title: String
    let isDisabled: Bool
    let action: () -> Void

    init(
        title: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void,
    ) {
        self.title = title
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .stirFont(.labelLg)
                .fontWeight(.semibold)
                .foregroundStyle(
                    isDisabled ? Color.Stir.textDisabled : Color.Stir.ink900,
                )
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(Color.Stir.paper100),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .strokeBorder(Color.Stir.divider, lineWidth: 1),
                )
                .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Previews

#Preview("SecondaryButton — light") {
    gallery
        .preferredColorScheme(.light)
}

#Preview("SecondaryButton — dark") {
    gallery
        .preferredColorScheme(.dark)
}

@MainActor
private var gallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
        Text("Default")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        SecondaryButton(title: "Compare plans", action: {})

        Text("Side-by-side with PrimaryButton")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        HStack(spacing: CGFloat.Stir.space3) {
            SecondaryButton(title: "Cancel", action: {})
            PrimaryButton(title: "Import", action: {})
        }

        Text("Disabled")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        SecondaryButton(title: "Retry", isDisabled: true, action: {})

        Spacer()
    }
    .padding(CGFloat.Stir.space4)
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
