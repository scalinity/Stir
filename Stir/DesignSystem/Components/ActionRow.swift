// ActionRow
//
// Primary-action row: ember-tinted icon tile + title + subtitle +
// trailing disclosure, all wrapped in an outlined rounded card. The
// "Start from" section on Tonight Home is built from three of these
// (Scan Kitchen, Import Recipe, Cook Saved); each Saved-meal cook-
// again path follows the same grammar.
//
// Extracted from `TonightHomeView.actionRow(...)` during the step-7
// review W-Group-C / W14 pass (CR1). The enabled / disabled variant
// handles the "kitchen scan temporarily unavailable" case — tile
// flips to paper-200 + ink-500 glyph, subtitle softens.
//
// Not parameterized for typeItInRow (text glyph, no fill) or
// recentMealRow (40pt tile, metadata row instead of subtitle). Those
// sites are sufficiently different that forcing them through a
// single generic would balloon the API surface for no real win —
// they stay inline in TonightHomeView.

import SwiftUI

struct ActionRow: View {
    let icon: Image
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let action: () -> Void

    init(
        icon: Image,
        title: String,
        subtitle: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: CGFloat.Stir.space3Half) { // 14pt
                iconTile
                textStack
                Spacer(minLength: CGFloat.Stir.space2)
                trailingChevron
            }
            .padding(CGFloat.Stir.space3Half) // 14pt
            .stirCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                .fill(isEnabled ? Color.Stir.ember100 : Color.Stir.paper200)
            icon
                .font(.system(size: CGFloat.Stir.iconMd + 4, weight: .semibold)) // justification: 24pt action-row icon — slightly larger than icon.md (20pt) so the primary-action tile reads at arm's length
                .foregroundStyle(isEnabled ? Color.Stir.ember600 : Color.Stir.ink500)
        }
        .frame(width: 44, height: 44)
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
            Text(title)
                .stirFont(.labelLg)
                .fontWeight(.semibold)
                .foregroundStyle(isEnabled ? Color.Stir.ink900 : Color.Stir.ink500)
            Text(subtitle)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.leading)
        }
    }

    private var trailingChevron: some View {
        Image.Stir.disclosure
            .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
            .foregroundStyle(Color.Stir.ink300)
    }
}

// MARK: - Previews

#Preview("ActionRow — light") {
    actionRowGallery.preferredColorScheme(.light)
}

#Preview("ActionRow — dark") {
    actionRowGallery.preferredColorScheme(.dark)
}

@MainActor
private var actionRowGallery: some View {
    VStack(spacing: CGFloat.Stir.space3) {
        ActionRow(
            icon: Image.Stir.scan,
            title: "Scan Kitchen",
            subtitle: "Point at ingredients to get three dinner options.",
            action: {},
        )
        ActionRow(
            icon: Image.Stir.imported,
            title: "Import Recipe",
            subtitle: "Paste a URL, pick a screenshot, or paste recipe text.",
            action: {},
        )
        ActionRow(
            icon: Image.Stir.bookmark,
            title: "Cook Saved",
            subtitle: "One-tap replay for your favorites.",
            action: {},
        )
        ActionRow(
            icon: Image.Stir.scan,
            title: "Kitchen scan temporarily unavailable",
            subtitle: "We've paused scans while we investigate an issue.",
            isEnabled: false,
            action: {},
        )
    }
    .padding(CGFloat.Stir.space4)
    .background(Color.Stir.paper50)
}
