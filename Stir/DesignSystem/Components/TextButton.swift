// TextButton
//
// Tertiary action — link-style text only (Specs/Design-System.md §8.1).
// Used for lowest-priority actions that still need to feel interactive:
// "Restore Purchases" on paywalls, "Clear" on search fields, "Skip for
// now" on optional onboarding steps, "See plans" inline hints.
//
// Visual grammar:
//   - ember.600 label (the brand interactive accent)
//   - labelLg medium weight (no semibold override — TextButton is
//     deliberately lighter than PrimaryButton/SecondaryButton)
//   - No fill, no border, no fixed frame — hugs its content
//   - 44×44 min tap target via minHeight + minWidth
//
// Never give a TextButton destructive intent — use a plain Button with
// crimson.600 foreground instead; TextButton is brand-neutral.

import SwiftUI

struct TextButton: View {
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
                .foregroundStyle(
                    isDisabled ? Color.Stir.textDisabled : Color.Stir.ember600,
                )
                .frame(minHeight: 44) // HIG tap-target floor
                .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Previews

#Preview("TextButton — light") {
    textButtonGallery
        .preferredColorScheme(.light)
}

#Preview("TextButton — dark") {
    textButtonGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var textButtonGallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
        Text("Default — stands alone")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        TextButton(title: "Restore Purchases", action: {})

        Text("Inline with body text")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        HStack(spacing: CGFloat.Stir.space2) {
            Text("Already Premium?")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textSecondary)
            TextButton(title: "Restore", action: {})
        }

        Text("Disabled")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
        TextButton(title: "See plans", isDisabled: true, action: {})

        Spacer()
    }
    .padding(CGFloat.Stir.space4)
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
