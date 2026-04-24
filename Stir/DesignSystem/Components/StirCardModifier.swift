// StirCardModifier
//
// Tokenized card container. Collapses the two-step
//   .background(RoundedRectangle(cornerRadius: R, style: .continuous)
//       .fill(F))
//   .overlay(RoundedRectangle(cornerRadius: R, style: .continuous)
//       .strokeBorder(B, lineWidth: W))
// pattern into a single `.stirCard(...)` call. Pre-W15 there were
// 25+ open-coded instances; each re-stated the same rounded-rect
// shape twice, and drift between the background and overlay radii
// was a live class of visual bug.
//
// Review finding W-C W15 (CR2). The modifier is the DS-level primitive;
// migration of existing call sites happens opportunistically — blind
// mass-migration risks visual regressions across features we can't
// easily spot-check.
//
// Defaults: paper.100 fill, 1pt divider border, radius.card (14pt).
// Pass `borderColor: nil` to omit the outline entirely.

import SwiftUI

extension View {
    /// Apply the shared tokenized card container. Rounded-rect fill
    /// plus an optional hairline border — drop-in replacement for the
    /// background+overlay RoundedRectangle pair.
    ///
    /// Parameters:
    ///   - fill: Card background fill. Defaults to `Color.Stir.paper100`.
    ///   - borderColor: Stroke color. Pass `nil` to render without a
    ///     border. Defaults to `Color.Stir.divider`.
    ///   - borderWidth: Stroke width. Defaults to 1pt.
    ///   - radius: Corner radius. Defaults to `CGFloat.Stir.radiusCard`
    ///     (14pt). Pass `.radiusLg` / `.radiusMd` / `.radiusSm` for the
    ///     other tokenized radii.
    func stirCard(
        fill: Color = Color.Stir.paper100,
        borderColor: Color? = Color.Stir.divider,
        borderWidth: CGFloat = 1,
        radius: CGFloat = CGFloat.Stir.radiusCard,
    ) -> some View {
        modifier(StirCardModifier(
            fill: fill,
            borderColor: borderColor,
            borderWidth: borderWidth,
            radius: radius,
        ))
    }
}

private struct StirCardModifier: ViewModifier {
    let fill: Color
    let borderColor: Color?
    let borderWidth: CGFloat
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill),
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(borderColor ?? .clear, lineWidth: borderColor == nil ? 0 : borderWidth),
            )
    }
}

// MARK: - Previews

#Preview("StirCard — light") {
    cardGallery.preferredColorScheme(.light)
}

#Preview("StirCard — dark") {
    cardGallery.preferredColorScheme(.dark)
}

@MainActor
private var cardGallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
        Text("Default — paper.100 + divider + radius.card")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.ink500)
        Text("Card content")
            .stirFont(.bodyMd)
            .foregroundStyle(Color.Stir.ink900)
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard()

        Text("amber.100 fill + amber.600 border — soft warning")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.ink500)
        Text("Option 2 didn't pass your rules.")
            .stirFont(.bodyMd)
            .foregroundStyle(Color.Stir.ink900)
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard(
                fill: Color.Stir.amber100,
                borderColor: Color.Stir.amber600.opacity(0.3),
            )

        Text("No border — flat tile")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.ink500)
        Text("Unbordered")
            .stirFont(.bodyMd)
            .foregroundStyle(Color.Stir.ink900)
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard(fill: Color.Stir.paper200, borderColor: nil)

        Text("Hero radius.lg")
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.ink500)
        Text("Dish card")
            .stirFont(.bodyMd)
            .foregroundStyle(Color.Stir.ink900)
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard(radius: CGFloat.Stir.radiusLg)
    }
    .padding(CGFloat.Stir.space4)
    .background(Color.Stir.paper50)
}
