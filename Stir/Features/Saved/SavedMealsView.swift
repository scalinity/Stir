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

import CoreData
import OSLog
import SwiftUI

struct SavedMealsView: View {
    let household: HouseholdProfile
    let aiDispatch: AIDispatch

    @State private var rows: [SavedMealRow] = []
    @State private var cookAgainPlan: RecipePlan?
    @State private var errorMessage: String?

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
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
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
                }
            }
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
            let results = try fetchRecipePlansWithLastCook(for: household)
            self.rows = results
            self.errorMessage = nil
        } catch {
            Logger.coreData.error("SavedMeals load failed: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = "Couldn't load saved meals."
        }
    }

    private func fetchRecipePlansWithLastCook(for household: HouseholdProfile) throws -> [SavedMealRow] {
        let context = PersistenceController.shared.viewContext

        let request = NSFetchRequest<RecipePlan>(entityName: "RecipePlan")
        request.predicate = NSPredicate(
            format: "household == %@ AND deletedAt == nil",
            household,
        )
        // Fetch all, then sort in memory by most-recent cook end.
        request.relationshipKeyPathsForPrefetching = ["cookingSessions", "cookingSessions.outcomeFeedback"]

        let plans: [RecipePlan]
        do {
            plans = try context.fetch(request)
        } catch {
            throw StirError.coreData(underlying: error)
        }

        return plans.compactMap { plan in
            let completedSessions = (plan.cookingSessions as? Set<CookingSession> ?? [])
                .filter { $0.typedStatus == .completed }
            let lastCompletedAt = completedSessions.compactMap { $0.endedAt }.max()
            let lastRating: Int? = completedSessions
                .compactMap { session -> (Date, Int)? in
                    guard let ended = session.endedAt,
                          let rating = session.outcomeFeedback?.rating,
                          rating > 0 else { return nil }
                    return (ended, Int(rating))
                }
                .max(by: { $0.0 < $1.0 })?
                .1

            return SavedMealRow(
                id: plan.id ?? UUID(),
                title: plan.title ?? "Untitled recipe",
                plan: plan,
                lastCookedAt: lastCompletedAt,
                rating: lastRating,
            )
        }
        .sorted { (a, b) in
            // last-cooked-desc; un-cooked go last.
            switch (a.lastCookedAt, b.lastCookedAt) {
            case let (.some(l), .some(r)): return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.title < b.title
            }
        }
    }
}

private struct SavedMealRow: Identifiable {
    let id: UUID
    let title: String
    let plan: RecipePlan?
    let lastCookedAt: Date?
    let rating: Int?
}
