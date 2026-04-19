// SavedMealsView
//
// Lists non-deleted RecipePlans for the current household, sorted
// last-cooked-desc (via CookingSession end dates), with each row showing
// title, last rating (when present), and a Cook-Again affordance that
// starts a fresh CookingSession for the same plan.
//
// Step 5 additions:
//   - Per-row favorite toggle (star). Free tier → paywall via
//     `PaywallTrigger.savedFavoritesGate`. Premium+ persists via
//     SolveRepository.setFavorite.
//   - Premium users see a "Favorites only" segmented control filter at
//     the top. Free users see the filter but its "Favorites" side is
//     gated with a paywall tap.
//
// Read path goes through CookingSessionRepository.savedMealEntries —
// the view doesn't open NSFetchRequest itself (kept layering clean so
// step 7's full favorites + filters work doesn't have to refactor).

import OSLog
import SwiftUI

struct SavedMealsView: View {
    let household: HouseholdProfile
    let aiDispatch: AIDispatch

    @Environment(EntitlementService.self) private var entitlements
    @Environment(RootCoordinator.self) private var coordinator

    @State private var rows: [CookingSessionRepository.SavedMealEntry] = []
    @State private var cookAgainPlan: RecipePlan?
    @State private var errorMessage: String?
    @State private var showFavoritesOnly = false

    private let repository: CookingSessionRepository
    private let solveRepository: SolveRepository

    init(
        household: HouseholdProfile,
        aiDispatch: AIDispatch,
        repository: CookingSessionRepository = CookingSessionRepository(),
        solveRepository: SolveRepository = SolveRepository(),
    ) {
        self.household = household
        self.aiDispatch = aiDispatch
        self.repository = repository
        self.solveRepository = solveRepository
    }

    var body: some View {
        Group {
            if filteredRows.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("Saved meals")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .top) {
            filterBar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
        }
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

    // MARK: - Filter bar

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: Binding(
                get: { showFavoritesOnly },
                set: { newValue in
                    // Free tier can't view favorites-only; tap → paywall.
                    if newValue, case .blockedByTier = entitlements.canAccess(.savedFavorites) {
                        coordinator.presentPaywall(.savedFavoritesGate)
                        return
                    }
                    showFavoritesOnly = newValue
                },
            )) {
                Text("All").tag(false)
                Text("Favorites").tag(true)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - List

    private var filteredRows: [CookingSessionRepository.SavedMealEntry] {
        guard showFavoritesOnly else { return rows }
        return rows.filter { $0.plan?.isFavorite == true }
    }

    private var list: some View {
        List(filteredRows) { row in
            HStack(alignment: .top, spacing: 14) {
                Button {
                    if let plan = row.plan { cookAgainPlan = plan }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title).font(.headline)
                        if let lastCooked = row.lastCookedAt {
                            Text(lastCooked, format: .relative(presentation: .named))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ratingLine(rating: row.rating)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Cook this again")

                favoriteButton(for: row)
            }
            .padding(.vertical, 4)
        }
        .listStyle(.plain)
    }

    // MARK: - Favorite toggle (per row)

    private func favoriteButton(for row: CookingSessionRepository.SavedMealEntry) -> some View {
        let isFavorite = row.plan?.isFavorite ?? false
        return Button {
            handleFavoriteTap(row: row)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? .yellow : .secondary)
                .padding(.top, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Save to favorites")
    }

    private func handleFavoriteTap(row: CookingSessionRepository.SavedMealEntry) {
        switch entitlements.canAccess(.savedFavorites) {
        case .allowed:
            guard let plan = row.plan else { return }
            let newValue = !plan.isFavorite
            _ = solveRepository.setFavorite(newValue, on: plan)
            if newValue {
                PostHogClient.shared.capture(
                    .favoriteSaved,
                    properties: BillingTelemetryProperties.favoriteSaved(
                        recipeOrigin: plan.typedOrigin.rawValue,
                    ),
                )
            }
            // Refresh rows so the UI picks up the new isFavorite.
            Task { await load() }
        case .blockedByTier, .blockedByQuota, .blockedByBilling:
            coordinator.presentPaywall(.savedFavoritesGate)
        }
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

    // MARK: - Empty / loading

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: showFavoritesOnly ? "star" : "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(showFavoritesOnly ? "No favorites yet" : "No saved meals yet")
                .font(.headline)
            Text(showFavoritesOnly
                 ? "Tap the star on a recipe to save a favorite."
                 : "Cook a dish to see it here for one-tap replay.")
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
