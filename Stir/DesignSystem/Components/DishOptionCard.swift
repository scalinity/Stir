// DishOptionCard
//
// The hero component on Dinner Options — this is the "aha moment"
// surface (Specs/Design-System.md §8.3). Three of these arrive as SSE
// events stream in from /v1/ai/dinner-solve. Users tap one to move to
// Dish Preview.
//
// Visual grammar:
//   - radius.lg (16pt) — hero card radius, distinct from the default
//     14pt so the dish cards visibly out-rank the Saved/Import rows
//   - paper.100 fill, 1pt ink.100 border
//   - Rank numeral (1/2/3) in displayMd, ink.300 — sits top-left as a
//     quiet ordinal
//   - displayMd title in ink.900
//   - bodyMd "why it fits" reason below title, ink.700
//   - Metadata row: clock icon + total time, missing-ingredient count
//   - One FitLabel badge (the primary fit reason — §8.4 "only ONE fit
//     label per dish")
//   - Press feedback: 98% scale + ember border ring (via DishCardStyle
//     ButtonStyle below). Reduce Motion honored via .stirAnimation.

import SwiftUI

struct DishOptionCard: View {
    let rank: Int
    let title: String
    let totalTimeMinutes: Int
    let whyItFits: String
    let missingIngredientCount: Int
    let fitKind: FitLabelKind

    var body: some View {
        // No internal Button wrapper — callers wrap the card in the
        // navigation affordance that suits their route type
        // (NavigationLink, Button, etc) and apply
        // `DishOptionCardStyle` via `.buttonStyle(...)`. Doing this
        // internally when the caller is already a NavigationLink
        // produces `Button(NavigationLink(Button(...)))`, which
        // VoiceOver reads as nested buttons and which `.buttonStyle(
        // .plain)` on the outer NavigationLink strips the press
        // feedback off of. Review finding W-H W33 (CR1+FD1).
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            HStack(alignment: .top) {
                Text("\(rank)")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink300)
                    .accessibilityHidden(true) // a11y label includes rank

                Spacer(minLength: CGFloat.Stir.space3)

                FitLabel(kind: fitKind)
            }

            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                Text(title)
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                Text(whyItFits)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink700)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }

            metadataRow
        }
        .padding(CGFloat.Stir.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                .strokeBorder(Color.Stir.divider, lineWidth: 1),
        )
        .contentShape(Rectangle())
        // Collapse the card's inner Text + FitLabel + metadata subtree
        // and substitute the single card-level label. Without `.ignore`,
        // SwiftUI appends the accessibilityLabel to the auto-generated
        // subtree label ("rank, title, fit label, 32 min, …") producing
        // a garbled double-read. Review finding W-H W34 (CR1).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var metadataRow: some View {
        // Clamp defensively — a malformed upstream response with a
        // negative `missingIngredientCount` would render "-2 to grab"
        // otherwise. Review finding W-H W36 (CA1).
        let safeCount = max(0, missingIngredientCount)
        return HStack(spacing: CGFloat.Stir.space4) {
            HStack(spacing: CGFloat.Stir.space1) {
                Image.Stir.clock
                    .font(.system(size: CGFloat.Stir.iconSm))
                    .foregroundStyle(Color.Stir.ink500)
                Text("\(totalTimeMinutes) min")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }

            if safeCount > 0 {
                HStack(spacing: CGFloat.Stir.space1) {
                    Image.Stir.cart
                        .font(.system(size: CGFloat.Stir.iconSm))
                        .foregroundStyle(Color.Stir.ink500)
                    Text(safeCount == 1
                         ? "1 to grab"
                         : "\(safeCount) to grab")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                }
            } else {
                HStack(spacing: CGFloat.Stir.space1) {
                    Image.Stir.check
                        .font(.system(size: CGFloat.Stir.iconSm))
                        .foregroundStyle(Color.Stir.sage600)
                    Text("You have it all")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.sage600)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        // Same clamp as metadataRow — W-H W36.
        let safeCount = max(0, missingIngredientCount)
        var parts = ["Option \(rank): \(title)"]
        parts.append("\(totalTimeMinutes) minutes")
        parts.append(safeCount == 0
                     ? "has every ingredient"
                     : "\(safeCount) ingredients to grab")
        parts.append("why it fits: \(whyItFits)")
        return parts.joined(separator: ", ")
    }
}

// MARK: - ButtonStyle — press feedback

/// 98% scale + ember border ring on press, per Spec §8.3. Reduce Motion
/// collapses the scale animation to instant (border still flips for the
/// press signal). Public so callers (NavigationLink, Button) can apply
/// it with `.buttonStyle(DishOptionCardStyle())`; internal use only —
/// not re-exported beyond the module.
struct DishOptionCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        // `.stirAnimation` handles the Reduce Motion gate internally,
        // so the scale step still fires on press (gated by
        // !reduceMotion) but the transition is instant under RM.
        // Review finding W-C W12 — demonstrates the DS pattern so the
        // tokens in Shared/Motion.swift aren't orphaned.
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .stirAnimation(.Stir.standard, value: configuration.isPressed)
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                    .strokeBorder(
                        configuration.isPressed ? Color.Stir.ember600 : Color.clear,
                        lineWidth: 2,
                    ),
            )
    }
}

// MARK: - Previews

#Preview("DishOptionCard — light") {
    dishOptionGallery
        .preferredColorScheme(.light)
}

#Preview("DishOptionCard — dark") {
    dishOptionGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var dishOptionGallery: some View {
    ScrollView {
        VStack(spacing: CGFloat.Stir.space3) {
            DishOptionCard(
                rank: 1,
                title: "Lemon-garlic shrimp pasta",
                totalTimeMinutes: 22,
                whyItFits: "Uses the shrimp and spinach before they turn. Leans on pantry staples you already have.",
                missingIngredientCount: 0,
                fitKind: .leastWaste,
            )
            DishOptionCard(
                rank: 2,
                title: "One-pan harissa chicken",
                totalTimeMinutes: 32,
                whyItFits: "Higher protein to hit your goal tonight. Skip if you're not up for a hotter dish.",
                missingIngredientCount: 1,
                fitKind: .bestFit,
            )
            DishOptionCard(
                rank: 3,
                title: "Sheet-pan gnocchi",
                totalTimeMinutes: 18,
                whyItFits: "Fastest tonight — 18 minutes including oven preheat.",
                missingIngredientCount: 2,
                fitKind: .fastest,
            )
        }
        .padding(CGFloat.Stir.space4)
    }
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
