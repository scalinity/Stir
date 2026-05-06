// SavedMealsTutorial
//
// First-run tutorial for the Saved tab. Three steps:
//   1. Save        — how meals end up saved (favorite-star demo on a
//                    fake post-cook row)
//   2. Find        — interactive search + sort + Favorites filter
//   3. Cook again  — pulsing Cook Again CTA on a saved-meal row
//
// Mounted on `SavedMealsView` via `.tutorial(key: .savedMeals, ...)`.

import SwiftUI

struct SavedMealsTutorial: View {
    enum Step: Int, TutorialStep {
        case save = 0
        case find = 1
        case cookAgain = 2

        var telemetryID: String {
            switch self {
            case .save:      return "save"
            case .find:      return "find"
            case .cookAgain: return "cook_again"
            }
        }
    }

    var body: some View {
        TutorialFlowHost(key: .savedMeals, initialStep: Step.save) { step, advance, skip in
            stepContent(step, advance: advance, skip: skip)
        }
    }

    @ViewBuilder
    private func stepContent(
        _ step: Step,
        advance: @escaping () -> Void,
        skip: @escaping () -> Void,
    ) -> some View {
        switch step {
        case .save:
            TutorialStepView(
                icon: Image.Stir.favoriteFill,
                headline: "Save the wins",
                message: "Tap the star on any dinner you'd cook again. It lands here, ready to pull up on a tired night.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                FavoriteStarMiniature()
            }
        case .find:
            TutorialStepView(
                icon: Image.Stir.search,
                headline: "Find it fast",
                message: "Search by ingredient or name, filter to favorites, and sort by recently cooked, top rated, or A–Z.",
                primaryAction: advance,
                skipAction: skip,
            ) {
                SavedFilterMiniature()
            }
        case .cookAgain:
            TutorialStepView(
                icon: Image.Stir.cook,
                headline: "Cook it again",
                message: "Tap any saved meal to jump straight into Cook Mode — same recipe, fresh session, no re-solve required.",
                primaryLabel: "Got it",
                primaryAction: advance,
            ) {
                CookAgainMiniature()
            }
        }
    }
}

// MARK: - Step miniatures

private struct FavoriteStarMiniature: View {
    @State private var isFavorite = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Tap the star")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink700)

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                    isFavorite.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.Stir.ember100)
                        .frame(width: 48, height: 48)
                        .overlay(
                            Image.Stir.cook
                                .foregroundStyle(Color.Stir.ember600)
                                .font(.system(size: 22, weight: .semibold)),
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lemon garlic pasta")
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                        Text("Just cooked · 4★")
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink700)
                    }
                    Spacer()
                    ZStack {
                        Image.Stir.favoriteOutline
                            .foregroundStyle(Color.Stir.ink700)
                            .opacity(isFavorite ? 0 : 1)
                        Image.Stir.favoriteFill
                            .foregroundStyle(Color.Stir.ember600)
                            .scaleEffect(isFavorite ? 1.0 : 0.6)
                            .opacity(isFavorite ? 1 : 0)
                    }
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32, height: 32)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.Stir.paper100),
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Demo: tap the star to favorite the meal")
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
    }
}

private struct SavedFilterMiniature: View {
    @State private var visible = false
    @State private var sort: Sort = .recent
    @State private var favoritesOnly = false

    enum Sort: String, CaseIterable {
        case recent = "Recently"
        case rating = "Top rated"
        case alpha = "A–Z"
    }

    private let meals: [(title: String, fav: Bool, when: String)] = [
        ("Lemon garlic pasta",  true,  "2 days ago"),
        ("Sheet-pan chicken",   false, "Last week"),
        ("Veggie stir-fry",     true,  "3 weeks ago"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image.Stir.search
                    .foregroundStyle(Color.Stir.ink700)
                Text("Search saved")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink700)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                Capsule().fill(Color.Stir.paper200),
            )

            HStack(spacing: 8) {
                ForEach(Sort.allCases, id: \.self) { option in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { sort = option }
                    } label: {
                        Text(option.rawValue)
                            .stirFont(.bodySm)
                            .foregroundStyle(sort == option ? Color.white : Color.Stir.ink700)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(sort == option ? Color.Stir.ember600 : Color.Stir.paper200),
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { favoritesOnly.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        (favoritesOnly ? Image.Stir.favoriteFill : Image.Stir.favoriteOutline)
                            .font(.system(size: 12, weight: .semibold))
                        Text("Favorites")
                            .stirFont(.bodySm)
                    }
                    .foregroundStyle(favoritesOnly ? Color.Stir.ember600 : Color.Stir.ink700)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(
                            favoritesOnly ? Color.Stir.ember100 : Color.Stir.paper200,
                        ),
                    )
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 6) {
                ForEach(Array(filteredMeals.enumerated()), id: \.element.title) { idx, meal in
                    HStack(spacing: 8) {
                        Image.Stir.cook
                            .foregroundStyle(Color.Stir.ember600)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 20)
                        Text(meal.title)
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                        Spacer()
                        if meal.fav {
                            Image.Stir.favoriteFill
                                .foregroundStyle(Color.Stir.ember600)
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.Stir.paper200.opacity(0.5)),
                    )
                    .staggeredReveal(index: idx, isVisible: visible)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: favoritesOnly)
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }

    private var filteredMeals: [(title: String, fav: Bool, when: String)] {
        favoritesOnly ? meals.filter { $0.fav } : meals
    }
}

private struct CookAgainMiniature: View {
    @State private var visible = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.Stir.ember100)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image.Stir.cook
                            .foregroundStyle(Color.Stir.ember600)
                            .font(.system(size: 24, weight: .semibold)),
                    )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Lemon garlic pasta")
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                        Image.Stir.favoriteFill
                            .foregroundStyle(Color.Stir.ember600)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    HStack(spacing: 6) {
                        Text("4★")
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ember600)
                        Text("·")
                            .foregroundStyle(Color.Stir.ink700)
                        Text("Last cooked 2 days ago")
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.ink700)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.Stir.paper100),
            )

            HStack(spacing: 8) {
                Image.Stir.cook
                    .font(.system(size: 16, weight: .semibold))
                Text("Cook again")
                    .stirFont(.bodyMd)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(
                Capsule().fill(Color.Stir.ember600),
            )
            .tutorialPulsing(scale: 1.05, duration: 1.0)
        }
        .frame(maxWidth: CGFloat.Stir.tutorialMiniatureMaxWidth)
        .tutorialFadeIn(isVisible: visible)
        .onAppear { visible = true }
        .accessibilityHidden(true)
    }
}

#Preview("SavedMealsTutorial") {
    SavedMealsTutorial()
}
