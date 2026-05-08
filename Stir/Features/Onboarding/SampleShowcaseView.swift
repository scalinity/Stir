// SampleShowcaseView
//
// SCA-67 — the "See a sample" Welcome path lands here. Static
// showcase of 3 pre-baked dinner ideas so new users get a feel for
// the product surface before committing to onboarding. Loads its
// fixture from `Stir/Resources/sample_solve.json` (committed to git;
// no AI call, no network, no Core Data write).
//
// Design:
//   * Stir-DS card stack (mirrors mockup 05's dinner-options layout)
//   * Each card shows rank label, title, time, rationale, a few
//     primary ingredients
//   * Two terminal CTAs: "Try with your real kitchen" (continues to
//     onboarding setup — calls onContinueOnboarding, which OnboardingRoot
//     wires to the existing real-onboarding entry) and "Back to start"
//     (pops back to Welcome)
//   * "Sample" eyebrow on every card so the user always knows this
//     is a demo, not their solve
//
// Spec §7 step 1: "See a sample" was previously a no-op-to-empty-
// Tonight bypass; this view honors the "preview 3 dinner ideas
// before committing" half of the promise.

import SwiftUI

struct SampleShowcaseView: View {
    /// Title of the primary terminal CTA. Defaults to onboarding-context
    /// copy; SCA-69 (camera-denied path) overrides with
    /// "Open Settings to enable camera".
    let primaryCTATitle: String
    let onPrimaryAction: () -> Void
    let onBack: () -> Void

    private let fixture: SampleSolveFixture

    init(
        primaryCTATitle: String = "Try with your real kitchen",
        onPrimaryAction: @escaping () -> Void,
        onBack: @escaping () -> Void,
        fixture: SampleSolveFixture = .bundled,
    ) {
        self.primaryCTATitle = primaryCTATitle
        self.onPrimaryAction = onPrimaryAction
        self.onBack = onBack
        self.fixture = fixture
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                header
                ForEach(fixture.dishes, id: \.rank) { dish in
                    DishRow(dish: dish)
                }
                actionStack
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            .padding(.bottom, CGFloat.Stir.space5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            PostHogClient.shared.capture(.sampleShowcaseViewed, properties: [
                "dish_count": fixture.dishes.count,
            ])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Sample dinner ideas")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
            Text("Here's what Stir gives you after a kitchen scan. Three real options, ranked. Try your own when you're ready.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
        }
    }

    private var actionStack: some View {
        VStack(spacing: CGFloat.Stir.space3) {
            PrimaryButton(title: primaryCTATitle) {
                PostHogClient.shared.capture(.sampleShowcaseExited, properties: [
                    "outcome": "primary_action",
                ])
                onPrimaryAction()
            }
            TextButton(title: "Back to start") {
                PostHogClient.shared.capture(.sampleShowcaseExited, properties: [
                    "outcome": "back",
                ])
                onBack()
            }
        }
        .padding(.top, CGFloat.Stir.space3)
    }
}

private struct DishRow: View {
    let dish: SampleSolveFixture.Dish

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            HStack(spacing: CGFloat.Stir.space2) {
                Text("SAMPLE · \(dish.label.uppercased())")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
                Spacer()
                Text("\(dish.estimatedMinutes) min")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }
            Text(dish.title)
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
            Text(dish.rationale)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
            HStack(spacing: CGFloat.Stir.space1) {
                ForEach(dish.primaryIngredients.prefix(4), id: \.self) { ingredient in
                    Text(ingredient)
                        .stirFont(.bodySm)
                        .padding(.horizontal, CGFloat.Stir.space2)
                        .padding(.vertical, CGFloat.Stir.space1)
                        .background(Color.Stir.sage100)
                        .foregroundStyle(Color.Stir.sage600)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(CGFloat.Stir.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Stir.paper100)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Fixture

/// Decoded shape of `sample_solve.json`. Single source of truth used
/// by both the showcase view and tests.
struct SampleSolveFixture: Codable, Equatable {
    let schemaVersion: Int
    let dishes: [Dish]

    struct Dish: Codable, Equatable {
        let rank: Int
        let title: String
        let label: String
        let rationale: String
        let estimatedMinutes: Int
        let missingIngredients: [String]
        let primaryIngredients: [String]

        enum CodingKeys: String, CodingKey {
            case rank, title, label, rationale
            case estimatedMinutes = "estimated_minutes"
            case missingIngredients = "missing_ingredients"
            case primaryIngredients = "primary_ingredients"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case dishes
    }

    /// Decode the fixture bundled at `sample_solve.json`. Falls back
    /// to a hardcoded 3-dish shape if the bundle copy is missing —
    /// preferable to a crash on an installer-corrupted bundle, and
    /// the showcase still works in offline / first-launch states.
    static var bundled: SampleSolveFixture {
        if let url = Bundle.main.url(forResource: "sample_solve", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(SampleSolveFixture.self, from: data) {
            return decoded
        }
        return .fallback
    }

    /// Hardcoded fallback identical to the JSON shape so the showcase
    /// renders something even if the bundle copy is missing. Mirrors
    /// `sample_solve.json` 1:1 — keep in sync if either changes.
    static let fallback = SampleSolveFixture(
        schemaVersion: 1,
        dishes: [
            Dish(
                rank: 1,
                title: "Pasta with Garlic, Lemon & Parmesan",
                label: "fastest",
                rationale: "20 min start to finish · uses pantry staples",
                estimatedMinutes: 20,
                missingIngredients: [],
                primaryIngredients: ["pasta", "garlic", "lemon", "parmesan", "olive oil"],
            ),
            Dish(
                rank: 2,
                title: "Sheet-Pan Chicken with Roasted Vegetables",
                label: "best fit",
                rationale: "high protein · matches your cookware",
                estimatedMinutes: 35,
                missingIngredients: [],
                primaryIngredients: ["chicken thighs", "potatoes", "carrots", "rosemary", "olive oil"],
            ),
            Dish(
                rank: 3,
                title: "Black Bean & Sweet Potato Tacos",
                label: "least waste",
                rationale: "uses items aging in your fridge",
                estimatedMinutes: 25,
                missingIngredients: [],
                primaryIngredients: ["black beans", "sweet potato", "tortillas", "lime", "cilantro"],
            ),
        ],
    )
}
