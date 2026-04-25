// Tap-target accessibility modifier.
//
// Apple HIG requires interactive elements to have ≥44×44pt hit area.
// SwiftUI's `.frame(minWidth:minHeight:)` grows the layout box, not just
// the hit-test region — applying it to a small icon button inside a tight
// HStack will reflow the row to 44pt. The right pattern is:
//
//   1. Constrain the visual size via an inner `.frame(width:height:)`
//      (and any `.background(...)` chrome) BEFORE the tap-target halo
//   2. Apply the 44×44 minimum via this modifier
//   3. Pin hit-test to the rectangle via `.contentShape(Rectangle())`
//
// Or — when the parent layout already has `.frame(minHeight: 44)`, the
// row growth is intentional (Apple HIG-correct) and no inner frame is
// needed.
//
// Step-9 review (CR2-W2 / DB1-B4) flagged this pattern duplicating across
// 6 sites with one site using the wrong shape and reflowing rows. This
// modifier names the correct pattern; the parent-layout 44pt min-height
// guard handles the surprise-growth class of bug.

import SwiftUI

extension View {
    /// Expands the receiver's hit-test region to at least `size × size`
    /// (default 44, Apple HIG minimum) without growing the visual frame
    /// beyond the receiver's existing layout.
    ///
    /// Apply AFTER any inner `.frame(width:height:)` that constrains the
    /// visible size. The modifier still extends the layout box up to
    /// `size` if the receiver is smaller — wrap the parent layout in
    /// `.frame(minHeight: size)` if you need to reserve consistent row
    /// height (search bars, status banners, etc.).
    func minTapTarget(_ size: CGFloat = 44) -> some View {
        self
            .frame(minWidth: size, minHeight: size)
            .contentShape(Rectangle())
    }
}
