// StirCircleIconButton
//
// 36pt circular icon button on a `paper.200` fill — the round-icon
// grammar used in Cook Mode's top bar and (post-SCA-436) anywhere a
// screen needs an icon-only action button. Replaces the system-default
// toolbar icon buttons that iOS 26 paints with Liquid Glass; the glass
// pill reads as off-theme against the warm-paper Stir surface.
//
// Visual grammar:
//   - 36pt visible circle (`paper.200` fill by default; pass a custom
//     `background` token for emphasis variants)
//   - `ink.700` icon (override via `foreground` for state-tinted icons,
//     e.g. ember.600 for an active favorite)
//   - 44pt hit area via `.contentShape(Rectangle())` so the smaller
//     visual footprint still passes the HIG tap-target floor
//   - Icon font size scaled to `labelMd` semibold so the glyph stays
//     legible across Dynamic Type without overflowing the circle
//
// Why a dedicated component (vs `Button { Image(...) }` in a toolbar):
//   - iOS 26 toolbar Buttons get the Liquid Glass material applied
//     automatically. There is no SwiftUI knob to opt-out cleanly from a
//     `.toolbar { ToolbarItem { ... } }` block — the material is
//     applied at the toolbar layer. The only reliable escape is to
//     render the button outside the system toolbar (e.g. inside a
//     `.safeAreaInset(.top)` custom header) which is why screens that
//     adopt this button typically also adopt a custom top-bar layout.
//   - `.buttonStyle(.plain)` does suppress the glass IF the button
//     lives inside `.topBarLeading` / `.topBarTrailing`, but it also
//     strips the press-feedback ring entirely. For inside-the-toolbar
//     use, this component still works (the surrounding Button keeps
//     its press feedback) — just pair with `.buttonStyle(.plain)` at
//     the call site to suppress the iOS 26 glass.
//
// Originally lived as a private `roundIconButton(...)` helper on
// `StepCardView`. Promoted to a shared DS component per SCA-436 so the
// same circle renders identically in Cook Mode's top bar, DishPreview's
// custom header, and PantryList's "+" toolbar action.

import SwiftUI

struct StirCircleIconButton: View {
    let icon: Image
    let accessibilityLabel: String
    let foreground: Color
    let background: Color
    let action: () -> Void

    init(
        icon: Image,
        accessibilityLabel: String,
        foreground: Color = Color.Stir.ink700,
        background: Color = Color.Stir.paper200,
        action: @escaping () -> Void,
    ) {
        self.icon = icon
        self.accessibilityLabel = accessibilityLabel
        self.foreground = foreground
        self.background = background
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon
                .stirFont(.labelMd).fontWeight(.semibold)
                .foregroundStyle(foreground)
                .frame(width: 36, height: 36)
                .background(Circle().fill(background))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Previews

#Preview("StirCircleIconButton — light") {
    iconButtonGallery
        .preferredColorScheme(.light)
}

#Preview("StirCircleIconButton — dark") {
    iconButtonGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var iconButtonGallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
        label("Default — paper.200 + ink.700")
        HStack(spacing: CGFloat.Stir.space3) {
            StirCircleIconButton(
                icon: Image.Stir.close,
                accessibilityLabel: "Close",
                action: {},
            )
            StirCircleIconButton(
                icon: Image.Stir.cart,
                accessibilityLabel: "Cart",
                action: {},
            )
            StirCircleIconButton(
                icon: Image(systemName: "chevron.left"),
                accessibilityLabel: "Back",
                action: {},
            )
        }

        label("Active state — ember-tinted icon")
        StirCircleIconButton(
            icon: Image(systemName: "star.fill"),
            accessibilityLabel: "Favorited",
            foreground: Color.Stir.ember600,
            action: {},
        )

        Spacer()
    }
    .padding(CGFloat.Stir.space4)
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}

@MainActor
private func label(_ text: String) -> some View {
    Text(text)
        .stirFont(.labelEyebrow)
        .foregroundStyle(Color.Stir.textTertiary)
}
