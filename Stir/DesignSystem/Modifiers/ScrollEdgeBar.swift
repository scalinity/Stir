// ScrollEdgeBar
//
// Pins a custom bar (e.g. a bottom action bar) to an edge of a screen as
// part of the system chrome layer. Avoid the top edge under a large title:
// the extended scroll edge effect blurs the title.
//
// iOS 26+: `safeAreaBar` — the content insets the safe area like
// `safeAreaInset`, and scroll views underneath extend their scroll edge
// effect beneath it, so the bar reads like the system navigation and tab
// bars (Liquid Glass) without a fill or hairline of its own.
//
// iOS 17–25: `safeAreaInset` over the system `.bar` material, the
// standard pre-Liquid-Glass bar treatment.
//
// See docs/decisions/0037-system-liquid-glass-chrome.md.

import SwiftUI

extension View {
    /// Places `content` as a system-styled bar along `edge`, insetting the
    /// safe area so scrolling content never sits underneath it.
    func scrollEdgeBar<Bar: View>(
        edge: VerticalEdge,
        @ViewBuilder content: () -> Bar,
    ) -> some View {
        modifier(ScrollEdgeBarModifier(edge: edge, bar: content()))
    }
}

private struct ScrollEdgeBarModifier<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: edge, spacing: 0) { bar }
        } else {
            content.safeAreaInset(edge: edge, spacing: 0) {
                bar.background(.bar)
            }
        }
    }
}
