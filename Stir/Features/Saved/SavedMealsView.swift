// SavedMealsView
//
// Step-4 surface for "Cook Saved". Lists non-deleted RecipePlans for
// the current household, sorted last-cooked-desc (via CookingSession
// end dates), with each row showing title, last rating (when present),
// and a Cook-Again affordance that starts a fresh CookingSession for
// the same plan.
//
// Spec §5 "Saved meals / favorites" lines this up to graduate into
// the full Saved Library in step 7 when favorites + filters land.
//
// Read path goes through CookingSessionRepository.savedMealEntries —
// the view doesn't open NSFetchRequest itself (kept the layering clean
// so step 7's favorites + filters work doesn't have to refactor it out).

import OSLog
import SwiftUI

struct SavedMealsView: View {
    let household: HouseholdProfile
    let aiDispatch: AIDispatch

    @State private var rows: [CookingSessionRepository.SavedMealEntry] = []
    @State private var cookAgainPlan: RecipePlan?
    @State private var errorMessage: String?

    private let repository: CookingSessionRepository

    init(
        household: HouseholdProfile,
        aiDispatch: AIDispatch,
        repository: CookingSessionRepository = CookingSessionRepository(),
    ) {
        self.household = household
        self.aiDispatch = aiDispatch
        self.repository = repository
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Saved meals")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await load()
        }
        .fullScreenCover(item: $cookAgainPlan) { plan in
            CookModeRoot(
                recipePlan: plan,
                household: household,
                aiDispatch: aiDispatch,
                source: .saved,
                onDismiss: {
                    cookAgainPlan = nil
                    Task { await load() }  // refresh rating/last-cooked
                },
            )
        }
    }

    private var list: some View {
        List(rows) { row in
            Button {
                if let plan = row.plan { cookAgainPlan = plan }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.headline)
                        if let lastCooked = row.lastCookedAt {
                            Text(lastCooked, format: .relative(presentation: .named))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ratingLine(rating: row.rating)
                    }
                    Spacer()
                    Image(systemName: "flame")
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Cook this again")
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func ratingLine(rating: Int?) -> some View {
        if let rating, rating > 0 {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { index in
                    Image(systemName: index <= rating ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(index <= rating ? .yellow : .secondary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rated \(rating) out of 5")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No saved meals yet")
                .font(.headline)
            Text("Cook a dish to see it here for one-tap replay.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(40)
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        do {
            self.rows = try repository.savedMealEntries(for: household)
            self.errorMessage = nil
        } catch {
            Logger.coreData.error("SavedMeals load failed: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = "Couldn't load saved meals."
        }
    }
}
