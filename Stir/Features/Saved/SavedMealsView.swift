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
    @State private var searchQuery: String = ""
    @State private var debouncedSearchQuery: String = ""
    @State private var sortOption: SortOption = .lastCooked
    /// Lowercased "title + every ingredient displayName" blob per row id.
    /// Populated at load(); consulted instead of re-lowercasing title +
    /// walking the ingredients relationship on every keystroke (CA3-7).
    @State private var searchBlobs: [UUID: String] = [:]
    /// Memoized output of the filter+sort pipeline. SwiftUI doesn't
    /// memoize computed properties, so every body re-eval pre-fix
    /// re-walked rows × ingredients. Rebuilt via .onChange on its
    /// inputs (rows / debouncedSearchQuery / sortOption / favorites).
    @State private var filteredRows: [CookingSessionRepository.SavedMealEntry] = []

    /// Filter + sort pipeline. Consults pre-computed searchBlobs so each
    /// keystroke is a dictionary lookup + substring match — no per-row
    /// title-lowercase, no ingredients relationship walk.
    private func rebuildFilteredRows() {
        var filtered = rows
        // 1. Favorites filter
        if showFavoritesOnly {
            filtered = filtered.filter { $0.plan?.isFavorite == true }
        }
        // 2. Search — matches title OR any ingredient displayName,
        //    case-insensitive. Whitespace-only query is a no-op.
        let trimmedQuery = debouncedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            let needle = trimmedQuery.lowercased()
            filtered = filtered.filter { row in
                searchBlobs[row.id]?.contains(needle) ?? false
            }
        }
        // 3. Sort
        switch sortOption {
        case .lastCooked:
            filtered.sort(by: CookingSessionRepository.sortByLastCooked)
        case .rating:
            filtered.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .alphabetical:
            filtered.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        self.filteredRows = filtered
    }

    /// Sort orderings for the Saved list. Mirrors the mockup 10 picker
    /// (last cooked desc is default; rating desc surfaces best hits;
    /// alphabetical is the "I know what I'm looking for" fallback).
    enum SortOption: String, Hashable, CaseIterable, Sendable {
        case lastCooked = "Recently cooked"
        case rating = "Top rated"
        case alphabetical = "A–Z"
    }

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
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.vertical, CGFloat.Stir.space2)
                .background(Color.Stir.backgroundCard)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.Stir.divider)
                        .frame(height: 1)
                }
        }
        .task {
            await load()
        }
        // Debounce searchQuery → debouncedSearchQuery. 150ms matches
        // keystroke cadence without feeling laggy. Each keystroke
        // restarts the Task; cancellation drops stale work.
        .task(id: searchQuery) {
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                debouncedSearchQuery = searchQuery
            } catch {
                // Task cancelled by next keystroke — intended.
            }
        }
        // rows changes come from load() which already calls
        // rebuildFilteredRows() inline — no .onChange observer needed
        // (SavedMealEntry isn't Equatable because RecipePlan isn't).
        .onChange(of: debouncedSearchQuery) { rebuildFilteredRows() }
        .onChange(of: sortOption) { rebuildFilteredRows() }
        .onChange(of: showFavoritesOnly) { rebuildFilteredRows() }
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
        VStack(spacing: CGFloat.Stir.space2) {
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

                Menu {
                    Picker("Sort", selection: $sortOption) {
                        ForEach(SortOption.allCases, id: \.self) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(minWidth: 32, minHeight: 32)
                        .foregroundStyle(Color.Stir.ink700)
                }
                .accessibilityLabel("Sort — \(sortOption.rawValue)")
            }

            HStack(spacing: CGFloat.Stir.space2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.Stir.ink500)
                TextField("Search by title or ingredient", text: $searchQuery)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .foregroundStyle(Color.Stir.ink900)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.Stir.ink300)
                    }
                }
            }
            .padding(.horizontal, CGFloat.Stir.space3)
            .padding(.vertical, CGFloat.Stir.space2)
            .background(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                    .strokeBorder(Color.Stir.ink100, lineWidth: 1),
            )
        }
    }

    // MARK: - List

    private var list: some View {
        List(filteredRows) { row in
            HStack(alignment: .top, spacing: CGFloat.Stir.space3 + 2) { // 14pt — tight but legible
                Button {
                    if let plan = row.plan { cookAgainPlan = plan }
                } label: {
                    VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                        Text(row.title)
                            .stirFont(.displaySm)
                            .foregroundStyle(Color.Stir.textPrimary)
                        if let lastCooked = row.lastCookedAt {
                            Text(lastCooked, format: .relative(presentation: .named))
                                .stirFont(.bodySm)
                                .foregroundStyle(Color.Stir.textTertiary)
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
            .padding(.vertical, CGFloat.Stir.space1)
        }
        .listStyle(.plain)
    }

    // MARK: - Favorite toggle (per row)

    private func favoriteButton(for row: CookingSessionRepository.SavedMealEntry) -> some View {
        // Favorite tint uses `ember600` on active and `ink300` (disabled-
        // ink) on inactive. The mockup's star affordance is ember — not
        // the iOS-default yellow — to stay on-brand in the warm palette.
        let isFavorite = row.plan?.isFavorite ?? false
        return Button {
            handleFavoriteTap(row: row)
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.Stir.ember600 : Color.Stir.ink300)
                // HIG-minimum 44×44 hit target — previous inline padding
                // left the effective tap region ~28pt wide, easy to miss
                // next to the larger Cook-Again button.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
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
            HStack(spacing: CGFloat.Stir.space1 / 2) { // 2pt — tight 5-star cluster
                ForEach(1...5, id: \.self) { index in
                    Image(systemName: index <= rating ? "star.fill" : "star")
                        .stirFont(.bodySm)
                        .foregroundStyle(index <= rating ? Color.Stir.ember600 : Color.Stir.ink300)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rated \(rating) out of 5")
        }
    }

    // MARK: - Empty / loading

    private var emptyState: some View {
        VStack(spacing: CGFloat.Stir.space3 + 2) { // 14pt — airy but not lonely
            Image(systemName: showFavoritesOnly ? "star" : "tray")
                .font(.system(size: CGFloat.Stir.iconXl))
                .foregroundStyle(Color.Stir.textTertiary)
                .accessibilityHidden(true)
            Text(showFavoritesOnly ? "No favorites yet" : "No saved meals yet")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
            Text(showFavoritesOnly
                 ? "Tap the star on a recipe to save a favorite."
                 : "Cook a dish to see it here for one-tap replay.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CGFloat.Stir.space6 + CGFloat.Stir.space2) // 40pt
        }
        .padding(CGFloat.Stir.space6 + CGFloat.Stir.space2) // 40pt
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        do {
            let fetched = try repository.savedMealEntries(for: household)
            self.rows = fetched
            // Rebuild search blobs at load time. Title lowered once,
            // every ingredient displayName concatenated. Excludes
            // canonicalSlug (users search the visible names). Re-built
            // only on load — toggling favorites / sorting / typing
            // doesn't invalidate the blobs.
            var blobs: [UUID: String] = [:]
            blobs.reserveCapacity(fetched.count)
            for entry in fetched {
                let titleLower = entry.title.lowercased()
                var ingredientLower = ""
                if let plan = entry.plan,
                   let ings = plan.ingredients as? Set<RecipeIngredient> {
                    // Single allocation — append each displayName, space
                    // between so partial-word cross-matches don't span
                    // boundaries ("salt" shouldn't match "salted peanuts"
                    // next to "water").
                    for ing in ings {
                        if let name = ing.displayName, !name.isEmpty {
                            ingredientLower.append(" ")
                            ingredientLower.append(name.lowercased())
                        }
                    }
                }
                blobs[entry.id] = titleLower + ingredientLower
            }
            self.searchBlobs = blobs
            self.errorMessage = nil
            rebuildFilteredRows()
        } catch {
            Logger.coreData.error("SavedMeals load failed: \(error.localizedDescription, privacy: .public)")
            self.errorMessage = "Couldn't load saved meals."
        }
    }
}
