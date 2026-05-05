// PantryRow
//
// Single-row component used by PantryListView. Displays the item
// name (medium ink.900), an optional amount text (bodySm ink.500),
// and a memory-state badge (sage.100/sage.600 for Standing,
// amber.100/amber.600 for Today, crimson.100/crimson.600 for
// Expired). Decorative leading source-glyph (camera/pencil/star/
// rectangle.stack) indicates origin via `Image.Stir.camera`,
// `.pantryManualEntry`, `.pantryStaple`, `.pantryImported`; a11y
// folds it into the row-level combined label.
//
// Token notes:
// - The expired-state badge uses `crimson100`/`crimson600`. An
//   earlier draft referenced `rust100` — that token does NOT exist
//   in `Color.Stir`; `rust600` is the only rust shade. crimson is
//   the correct paired-100/600 fill+text token.
// - Source-glyph routing goes through the icon-scale tokens, not
//   spacing tokens: frame width is `CGFloat.Stir.iconLg` (28pt) so
//   the glyph container reads as a row decoration balanced against
//   the trailing badge; SF Symbol size is `CGFloat.Stir.iconSm`
//   (16pt), matching sibling SF Symbols in `ActionRow` /
//   `SavedMealCard`. Typography tokens are reserved for body text;
//   icon scale governs symbols.
// - Inner VStack uses an inline 2pt — the title→amount baseline gap.
//   This is below `space1` (4pt). Per `Shared/Spacing.swift`
//   doc-comments, sub-token values use inline arithmetic with a
//   justification comment; we are NOT inventing a new token for a
//   single call site.
// - Badge vertical padding is `space1Half` (6pt) to match the
//   capsule chip-grammar used by `FitLabel`. Horizontal padding is
//   `space2` (8pt). The `.unknown` arm of the badge color switch is
//   gated unreachable by the outer `if !label.isEmpty`; we keep it
//   defensive and exhaustive so adding a future enum case breaks
//   the build instead of silently falling through.

import SwiftUI

struct PantryRow: View {
    @ObservedObject var item: PantryItem

    var body: some View {
        HStack(alignment: .center, spacing: CGFloat.Stir.space3) {
            sourceGlyph
                .frame(width: CGFloat.Stir.iconLg)

            VStack(alignment: .leading, spacing: 2) {  // justification: tight 2pt name→amount baseline gap, sub-token (Spacing.swift escape hatch)
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
        // VoiceOver: replace `.combine` (which folds in the visible
        // text but drops the decorative source glyph's semantics) with
        // an explicit label that includes source attribution. Source
        // is meaningful info — "scanned" vs "manually entered" vs
        // "imported from a recipe" tells the user where the row came
        // from when they're auditing pantry contents (review W13).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(combinedAccessibilityLabel)
    }

    /// Combined VoiceOver label: "{name}, {amount?}, {state}, source:
    /// {source}". Empty fields are skipped so the label doesn't read
    /// dead commas. Mirrors the visible row order so cursor-by-row
    /// review feels like reading the visible UI, with source appended
    /// at the end.
    private var combinedAccessibilityLabel: String {
        var parts: [String] = []
        parts.append(item.displayName ?? "Unnamed")
        if let amount = item.amountText, !amount.isEmpty {
            parts.append(amount)
        }
        let state = item.memoryStateLabel
        if !state.isEmpty {
            parts.append(state)
        }
        parts.append("source: \(sourceAccessibilityLabel)")
        return parts.joined(separator: ", ")
    }

    private var sourceAccessibilityLabel: String {
        switch item.typedSource {
        case .scan:    return "scanned"
        case .manual:  return "manually entered"
        case .staple:  return "staple"
        case .import:  return "imported from a recipe"
        }
    }

    private var sourceGlyph: some View {
        let glyph: Image = {
            switch item.typedSource {
            case .scan: return Image.Stir.camera
            case .manual: return Image.Stir.pantryManualEntry
            case .staple: return Image.Stir.pantryStaple
            case .import: return Image.Stir.pantryImported
            }
        }()
        return glyph
            .font(.system(size: CGFloat.Stir.iconSm, weight: .regular))
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
                case .unknown: return (Color.Stir.paper200, Color.Stir.ink500)  // defensive: gated by label.isEmpty above (.unknown returns "")
                }
            }()
            Text(label.uppercased())
                .stirFont(.labelEyebrow)
                .foregroundStyle(fg)
                .padding(.horizontal, CGFloat.Stir.space2)
                .padding(.vertical, CGFloat.Stir.space1Half)
                .background(
                    Capsule(style: .continuous).fill(fill)
                )
        }
    }
}
