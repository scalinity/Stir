// PantryRow
//
// Single-row component used by PantryListView. Displays the item
// name (medium ink.900), an optional amount text (bodySm ink.500),
// and a memory-state badge (sage.100/sage.600 for Standing,
// amber.100/amber.600 for Today, crimson.100/crimson.600 for
// Expired). Decorative leading source-glyph (camera/pencil/sparkles/
// rectangle.stack) indicates origin; a11y folds it into the
// row-level combined label.
//
// Token notes:
// - The expired-state badge uses `crimson100`/`crimson600`. An
//   earlier draft referenced `rust100` — that token does NOT exist
//   in `Color.Stir`; `rust600` is the only rust shade. crimson is
//   the correct paired-100/600 fill+text token.
// - `Font.system(size:14)` is used solely for the SF Symbol glyph,
//   which is permitted: typography tokens are reserved for body
//   text. Glyph ink follows `ink300` (decorative tertiary).
// - Inner VStack uses `CGFloat.Stir.space1` (4pt) — the title→
//   amount line gap. This is the only token-resolved value below
//   `space2`; there is no `space0Half` / `space1Quarter` and 4pt
//   is the smallest defined Stir spacing increment.

import SwiftUI

struct PantryRow: View {
    @ObservedObject var item: PantryItem

    var body: some View {
        HStack(alignment: .center, spacing: CGFloat.Stir.space3) {
            sourceGlyph
                .frame(width: CGFloat.Stir.space5)

            VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                Text(item.displayName ?? "Unnamed")
                    .stirFont(.bodyMd)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.Stir.ink900)
                    .lineLimit(1)

                if let amount = item.amountText, !amount.isEmpty {
                    Text(amount)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: CGFloat.Stir.space2)

            stateBadge
        }
        .padding(.vertical, CGFloat.Stir.space2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var sourceGlyph: some View {
        let symbol: String = {
            switch item.typedSource {
            case .scan: return "camera"
            case .manual: return "pencil"
            case .staple: return "sparkles"
            case .import: return "rectangle.stack"
            }
        }()
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color.Stir.ink300)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let label = item.memoryStateLabel
        if !label.isEmpty {
            let (fill, fg): (Color, Color) = {
                if item.isExpired { return (Color.Stir.crimson100, Color.Stir.crimson600) }
                switch item.typedMemoryState {
                case .ephemeral: return (Color.Stir.amber100, Color.Stir.amber600)
                case .remembered: return (Color.Stir.sage100, Color.Stir.sage600)
                case .expired: return (Color.Stir.crimson100, Color.Stir.crimson600)
                case .unknown: return (Color.Stir.paper200, Color.Stir.ink500)
                }
            }()
            Text(label.uppercased())
                .stirFont(.labelEyebrow)
                .foregroundStyle(fg)
                .padding(.horizontal, CGFloat.Stir.space2)
                .padding(.vertical, CGFloat.Stir.space1)
                .background(
                    Capsule(style: .continuous).fill(fill),
                )
        }
    }
}
