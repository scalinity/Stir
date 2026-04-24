// StarRatingRow
//
// Shared 5-star rating row. Extracted from inline ForEach copies in
// TonightHomeView.ratingStars and SavedMealsView.ratingLine so the
// 5-image build is a single View struct rather than a re-evaluated
// @ViewBuilder func that rebuilds 5 Images on every parent render
// (CA3-flagged in review-ui-migration-findings.md W-E W23).
//
// `rating` is clamped to 0...5. Filled stars render ember.600; empty
// stars render ink.300. The whole row is collapsed into a single
// VoiceOver element with a human-readable "Rated N out of 5" label.

import SwiftUI

struct StarRatingRow: View {
    let rating: Int
    let starSize: StarSize

    /// Star-glyph sizing presets. Add new cases when a design context
    /// needs a bespoke size rather than drifting `font(.system)`
    /// literals across components.
    enum StarSize {
        /// 11pt glyph. TonightHome recent-meal row cluster.
        case micro
        /// .bodySm token. SavedMealsView list row.
        case bodySm
    }

    init(rating: Int, size: StarSize = .bodySm) {
        // Clamp defensively — a nil-or-negative rating should render
        // all-empty, not crash or render partially-filled below zero.
        self.rating = max(0, min(5, rating))
        self.starSize = size
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { idx in
                star(filled: idx <= rating)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rated \(rating) out of 5")
    }

    @ViewBuilder
    private func star(filled: Bool) -> some View {
        let image = Image(systemName: filled ? "star.fill" : "star")
            .foregroundStyle(filled ? Color.Stir.ember600 : Color.Stir.ink300)
            .accessibilityHidden(true)
        switch starSize {
        case .micro:
            image.font(.system(size: 11)) // justification: 11pt micro cluster for tight list rows
        case .bodySm:
            image.stirFont(.bodySm)
        }
    }
}

// MARK: - Previews

#Preview("StarRatingRow — light") {
    starGallery.preferredColorScheme(.light)
}

#Preview("StarRatingRow — dark") {
    starGallery.preferredColorScheme(.dark)
}

@MainActor
private var starGallery: some View {
    VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
        ForEach(0 ... 5, id: \.self) { n in
            HStack(spacing: CGFloat.Stir.space3) {
                Text("\(n)/5")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink500)
                    .frame(width: 40, alignment: .leading)
                StarRatingRow(rating: n, size: .bodySm)
                StarRatingRow(rating: n, size: .micro)
            }
        }
    }
    .padding(CGFloat.Stir.space4)
    .background(Color.Stir.paper50)
}
