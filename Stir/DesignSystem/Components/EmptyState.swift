// EmptyState
//
// Centered "nothing here yet" surface (Specs/Design-System.md §8.8).
// Used on: Saved Library (no meals yet), Leftovers (nothing queued),
// Grocery (nothing missing), first-use Tonight Home, fallback when a
// filter narrows to zero results.
//
// Visual grammar:
//   - SF Symbol at icon.xl (44pt) in ink.300 (deliberately muted —
//     §3 "muted surface accent, not a billboard")
//   - displayMd heading
//   - bodyMd body copy
//   - Optional PrimaryButton CTA below the body
//
// Centered vertically inside its container. Horizontal padding leaves
// 32pt margins to avoid the "emptystate fills the screen" anti-pattern.
//
// The optional `action` is always a PrimaryButton — EmptyState is a
// dead end with one clear exit, not a branching decision point. If a
// screen needs multiple escape paths, the surrounding layout composes
// them; EmptyState exposes one.

import SwiftUI

struct EmptyState: View {
    let icon: Image
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: Image,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: CGFloat.Stir.space4) {
            icon
                .font(.system(size: CGFloat.Stir.iconXl, weight: .regular))
                .foregroundStyle(Color.Stir.ink300)
                .accessibilityHidden(true) // title carries the semantic

            Text(title)
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.center)

            Text(message)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textSecondary)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                PrimaryButton(title: actionTitle, action: action)
                    .padding(.top, CGFloat.Stir.space2)
            }
        }
        .padding(.horizontal, CGFloat.Stir.space6) // 32pt — leaves breathing room
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // NOTE: no `.combine` — when the optional PrimaryButton CTA
        // is present, `.combine` flattens the Button into the composed
        // static label and VoiceOver users can't activate it. Letting
        // SwiftUI emit separate a11y elements keeps the CTA reachable.
        // Review finding C3 (FD1).
    }
}

// MARK: - Previews

#Preview("EmptyState — light") {
    emptyStateGallery
        .preferredColorScheme(.light)
}

#Preview("EmptyState — dark") {
    emptyStateGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var emptyStateGallery: some View {
    EmptyState(
        icon: Image.Stir.bookmark,
        title: "No saved meals yet",
        message: "Recipes you cook and like will show up here. Try starting with tonight's dinner solve.",
        actionTitle: "Scan your kitchen",
        action: {},
    )
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
