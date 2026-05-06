// ChipFlowLayout
//
// Lightweight flowing layout for chips — wraps onto new lines as
// horizontal space runs out. Originally introduced for onboarding
// (Step-2 OnboardingOptions.swift used a bespoke `FlowLayout`); shared
// across:
//
//   • `Stir/Features/Onboarding/SetupPreferencesView.swift` — diet/
//     dislike/equipment chip rows
//   • `Stir/Features/Scan/ScanReviewView.swift` — confirmed / needs-
//     review / add-chip rows
//   • `Stir/Features/Tutorial/ScanCaptureTutorial.swift` — the
//     ingredient-chips miniature on the "Wait" step
//
// Promoted to DS in SCA-28 (the SCA-19 review surfaced a private
// `FlowLayout` re-defined inside `ScanCaptureTutorial`; the existing
// `ChipFlowLayout`'s own doc-block had named the trigger condition —
// "pull this out the next time we touch the project file" — and SCA-19
// did exactly that).

import SwiftUI

struct ChipFlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 8) { self.spacing = spacing }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout (),
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width, currentX > 0 {
                currentY += lineHeight + spacing
                currentX = 0
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }
        return CGSize(
            width: width == .infinity ? currentX : width,
            height: totalHeight,
        )
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout (),
    ) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += lineHeight + spacing
                currentX = bounds.minX
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                proposal: ProposedViewSize(size),
            )
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
