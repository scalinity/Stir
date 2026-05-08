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
        // Page bg + nav bar tinted paper50 keeps the saved-tab surface
        // continuous with Tonight (matches mockup 10 §Saved Library).
        //
        // Nav bar is hidden so we can render the serif title inline in
        // the safeAreaInset header — the `.principal` ToolbarItem
        // approach grew the bar unpredictably with a non-default font
        // and left a wide dead-air gap below the title. The inline
        // `Text("Saved meals")` carries the `.isHeader` accessibility
        // trait, so VoiceOver still announces a header for the screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        // Propagates to descendants — any future navigationDestination
        // pushed from this view must restore its own toolbar.
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            // Single source of truth for title vertical rhythm. Above-
            // title padding and title-to-filterBar VStack spacing are
            // wired to the same value so the "Saved meals" band stays
            // symmetric — bumping one without the other would silently
            // un-center the title within its header strip.
            let titleVerticalPadding = CGFloat.Stir.space5
            VStack(spacing: titleVerticalPadding) {
                Text("Saved meals")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
                    .frame(maxWidth: .infinity)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, titleVerticalPadding)
                filterBar
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.bottom, CGFloat.Stir.space2)
            .background(Color.Stir.paper50)
            // Hairline seam — header inset is sticky, so when list
            // rows scroll behind it the divider keeps the boundary
            // legible. Subtle on paper50 (ink100 vs #FAF7F2) but
            // present.
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
        // SCA-30 — full-screen Saved tab tutorial. Mounts on first
        // visit explaining how meals end up saved, the search/sort/
        // favorites filter, and the Cook Again CTA.
        .tutorial(key: .savedMeals) { SavedMealsTutorial() }
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
                    Image.Stir.sort
                        .foregroundStyle(Color.Stir.ink700)
                        .minTapTarget()
                }
                .accessibilityLabel("Sort — \(sortOption.rawValue)")
            }

            HStack(spacing: CGFloat.Stir.space2) {
                Image.Stir.search
                    .foregroundStyle(Color.Stir.ink500)
                    .accessibilityHidden(true)
                TextField("Search by title or ingredient", text: $searchQuery)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .foregroundStyle(Color.Stir.ink900)
                if !searchQuery.isEmpty {
                    Button { searchQuery = "" } label: {
                        Image.Stir.clearField
                            .foregroundStyle(Color.Stir.ink300)
                            .minTapTarget()
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, CGFloat.Stir.space3)
            .padding(.vertical, CGFloat.Stir.space2)
            .stirCard(
                borderColor: Color.Stir.ink100,
                radius: CGFloat.Stir.radiusMd,
            )
        }
    }

    // MARK: - List

    private var list: some View {
        List(filteredRows) { row in
            // `.center` so the star aligns with the vertical middle of
            // the row regardless of how many lines the title wraps to.
            // `.top` left it hugging the first title baseline, which
            // looked off when the title spanned two lines.
            HStack(alignment: .center, spacing: CGFloat.Stir.space3 + 2) { // 14pt — tight but legible
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
            .listRowBackground(Color.Stir.paper50)
            .listRowSeparatorTint(Color.Stir.divider)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    handleDeleteTap(row: row)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                // ember700 is the deepest brand red-orange — destructive
                // intent in the warm palette without the system .red
                // pop, keeps the saved-tab surface continuous.
                .tint(Color.Stir.ember700)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.Stir.paper50)
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
            (isFavorite ? Image.Stir.favoriteFill : Image.Stir.favoriteOutline)
                .foregroundStyle(isFavorite ? Color.Stir.ember600 : Color.Stir.ink300)
                .minTapTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Save to favorites")
    }

    private func handleDeleteTap(row: CookingSessionRepository.SavedMealEntry) {
        guard let plan = row.plan else { return }
        // Optimistic: remove from in-memory state first so the row
        // animates out without waiting on the Core Data save. If the
        // save fails we reload to restore truth.
        rows.removeAll { $0.id == row.id }
        searchBlobs.removeValue(forKey: row.id)
        rebuildFilteredRows()
        let saved = solveRepository.softDelete(plan)
        if !saved {
            Task { await load() }
        }
    }

    private func handleFavoriteTap(row: CookingSessionRepository.SavedMealEntry) {
        entitlements.gate(
            .savedFavorites,
            paywall: { coordinator.presentPaywall(.savedFavoritesGate) },
            allow: {
                guard let plan = row.plan else { return }
                let newValue = !plan.isFavorite
                _ = solveRepository.setFavorite(newValue, on: plan)
                if newValue {
                    PostHogClient.shared.capture(
                        .favoriteSaved,
                        // SCA-120: emit `source: .savedReplay` for
                        // re-favorite taps from the Saved tab so the
                        // favorites funnel separates these from
                        // first-time Tonight saves and post-meal
                        // suggestSave routes.
                        properties: BillingTelemetryProperties.favoriteSaved(
                            recipeOrigin: plan.typedOrigin.rawValue,
                            source: .savedReplay,
                        ),
                    )
                }
                // Refresh rows so the UI picks up the new isFavorite.
                Task { await load() }
            },
        )
    }

    @ViewBuilder
    private func ratingLine(rating: Int?) -> some View {
        if let rating, rating > 0 {
            // Delegates to the shared DesignSystem component.
            // Review finding W-E W23 (CA3).
            StarRatingRow(rating: rating, size: .bodySm)
        }
    }

    // MARK: - Empty / loading

    private var emptyState: some View {
        VStack(spacing: CGFloat.Stir.space3 + 2) { // 14pt — airy but not lonely
            (showFavoritesOnly ? Image.Stir.favoriteOutline : Image.Stir.savedTray)
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
