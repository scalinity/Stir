// StirRowDivider
//
// 1pt hairline separator between rows inside a `.stirCard()` group.
// Lifted from four feature-local copies (SCA-95) so the divider colour
// + height stay locked across Settings, Notifications, Household,
// OutcomeFeedback, TutorialReplay, and any future grouped-list surface.
//
// `insetMatchingTile` parameterises the leading inset: rows that carry
// a 32×32 leading icon tile (mockup 14 settings rows) need the divider
// to start at the title baseline so the hairline doesn't underrun the
// glyph; rows without a tile (Household / Notifications / detail pages)
// use the row's horizontal padding alone.
//
//   - `false` — `space3Half` leading inset (default). Detail-page rows.
//   - `true`  — `space3Half + iconTileSize + space3` leading inset.
//               Settings tile-fronted rows. `iconTileSize = 32` matches
//               the constant `SettingsRootView.iconTileSize`; it lives
//               here because the divider is its only DS-level consumer
//               and parameterising it lets Settings keep its private
//               `iconTileSize` constant for tile + sync-dot framing
//               without exporting it to the design system surface.

import SwiftUI

struct StirRowDivider: View {
    /// 32pt — width of the leading icon tile in Settings-style rows
    /// (matches `SettingsRootView.iconTileSize`). Hoisted alongside the
    /// divider since the divider is the only DS-level consumer.
    static let iconTileSize: CGFloat = 32

    let insetMatchingTile: Bool

    init(insetMatchingTile: Bool = false) {
        self.insetMatchingTile = insetMatchingTile
    }

    var body: some View {
        Rectangle()
            .fill(Color.Stir.divider)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }

    private var leadingInset: CGFloat {
        if insetMatchingTile {
            return CGFloat.Stir.space3Half + Self.iconTileSize + CGFloat.Stir.space3
        }
        return CGFloat.Stir.space3Half
    }
}

#if DEBUG
#Preview("StirRowDivider") {
    VStack(spacing: CGFloat.Stir.space4) {
        VStack(spacing: 0) {
            Text("Row 1").frame(maxWidth: .infinity, alignment: .leading).padding()
            StirRowDivider()
            Text("Row 2").frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .stirCard()
        VStack(spacing: 0) {
            Text("Row 1 (tile-inset)").frame(maxWidth: .infinity, alignment: .leading).padding()
            StirRowDivider(insetMatchingTile: true)
            Text("Row 2 (tile-inset)").frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .stirCard()
    }
    .padding()
    .background(Color.Stir.paper50)
}
#endif
