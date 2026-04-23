// SavedMealCard
//
// List-row card for Saved Library (Specs/Design-System.md §8.3 +
// mockup 10). Smaller and flatter than DishOptionCard — this is the
// "browse your favorites" surface, not the "aha moment" surface. Uses
// the default card radius (14pt) rather than the hero 16pt.
//
// Visual grammar:
//   - radius.card (14pt) — default card radius
//   - paper.100 fill, 1pt ink.100 border (hairline elevation — §5.5)
//   - displaySm title in ink.900
//   - bodySm metadata in ink.500 (total time, 5-star rating)
//   - ember.600 heart when favorited; ink.300 when not
//   - 100% tappable via outer Button
//
// Free-tier locked variant:
//   - When isFreeLocked is true, tap surfaces the paywall instead of
//     opening the recipe. The lock icon replaces the heart at the
//     top-right. Caller is responsible for the paywall routing; this
//     component just signals the state visually.

import SwiftUI

struct SavedMealCard: View {
    let title: String
    let totalTimeMinutes: Int
    let rating: Int?
    let isFavorite: Bool
    let isFreeLocked: Bool
    let onTap: () -> Void
    let onToggleFavorite: (() -> Void)?

    init(
        title: String,
        totalTimeMinutes: Int,
        rating: Int? = nil,
        isFavorite: Bool = false,
        isFreeLocked: Bool = false,
        onTap: @escaping () -> Void,
        onToggleFavorite: (() -> Void)? = nil,
    ) {
        self.title = title
        self.totalTimeMinutes = totalTimeMinutes
        self.rating = rating
        self.isFavorite = isFavorite
        self.isFreeLocked = isFreeLocked
        self.onTap = onTap
        self.onToggleFavorite = onToggleFavorite
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                    Text(title)
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.ink900)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    HStack(spacing: CGFloat.Stir.space3) {
                        HStack(spacing: CGFloat.Stir.space1) {
                            Image.Stir.clock
                                .font(.system(size: CGFloat.Stir.iconSm))
                                .foregroundStyle(Color.Stir.ink500)
                            Text("\(totalTimeMinutes) min")
                                .stirFont(.bodySm)
                                .foregroundStyle(Color.Stir.ink500)
                        }

                        if let rating {
                            ratingView(rating)
                        }
                    }
                }

                Spacer(minLength: CGFloat.Stir.space3)

                trailingIcon
            }
            .padding(CGFloat.Stir.space4)
            .background(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard, style: .continuous)
                    .strokeBorder(Color.Stir.divider, lineWidth: 1),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var trailingIcon: some View {
        if isFreeLocked {
            Image.Stir.locked
                .font(.system(size: CGFloat.Stir.iconMd))
                .foregroundStyle(Color.Stir.ink300)
                .accessibilityHidden(true)
        } else if let onToggleFavorite {
            // Inner button for the heart — tapping shouldn't bubble
            // to the outer card tap. 44×44 tap target.
            Button(action: onToggleFavorite) {
                (isFavorite ? Image.Stir.heartFill : Image.Stir.heart)
                    .font(.system(size: CGFloat.Stir.iconMd))
                    .foregroundStyle(isFavorite ? Color.Stir.ember600 : Color.Stir.ink300)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Unfavorite \(title)" : "Favorite \(title)")
        } else {
            // No favorite affordance (e.g., imported recipe without
            // favorite state) — render a static heart state for
            // visual balance, or nothing at all if not favorite.
            if isFavorite {
                Image.Stir.heartFill
                    .font(.system(size: CGFloat.Stir.iconMd))
                    .foregroundStyle(Color.Stir.ember600)
                    .accessibilityHidden(true)
            }
        }
    }

    private func ratingView(_ stars: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { index in
                Image(systemName: index <= stars ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(index <= stars ? Color.Stir.ember600 : Color.Stir.ink300)
            }
        }
        .accessibilityLabel("\(stars) out of 5 stars")
    }

    private var accessibilityLabel: String {
        var parts = ["\(title), \(totalTimeMinutes) minutes"]
        if let rating { parts.append("\(rating) of 5 stars") }
        if isFavorite { parts.append("favorited") }
        if isFreeLocked { parts.append("locked — Premium feature") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#Preview("SavedMealCard — light") {
    savedMealGallery
        .preferredColorScheme(.light)
}

#Preview("SavedMealCard — dark") {
    savedMealGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var savedMealGallery: some View {
    ScrollView {
        VStack(spacing: CGFloat.Stir.space3) {
            SavedMealCard(
                title: "One-pan harissa chicken with chickpeas",
                totalTimeMinutes: 32,
                rating: 5,
                isFavorite: true,
                onTap: {},
                onToggleFavorite: {},
            )
            SavedMealCard(
                title: "Miso-butter udon",
                totalTimeMinutes: 18,
                rating: 4,
                isFavorite: false,
                onTap: {},
                onToggleFavorite: {},
            )
            SavedMealCard(
                title: "Lemon-garlic shrimp pasta",
                totalTimeMinutes: 22,
                rating: nil,
                isFavorite: false,
                onTap: {},
                onToggleFavorite: {},
            )
            SavedMealCard(
                title: "Crispy tofu rice bowl",
                totalTimeMinutes: 28,
                rating: 4,
                isFavorite: false,
                isFreeLocked: true,
                onTap: {},
            )
        }
        .padding(CGFloat.Stir.space4)
    }
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
