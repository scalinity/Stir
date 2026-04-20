// DishPreviewView
//
// Step-4 landing page. Shows the chosen dish in full: ingredients,
// steps, missing-from-pantry callouts. "Start Cooking" dismisses the
// parent ScanFlowRoot and routes Cook Mode presentation through
// `RootCoordinator.activeFreshCook` so it presents cleanly at the
// TonightHome layer — nested fullScreenCovers (ScanFlow + CookMode)
// hit iOS's "only single sheet" limit and silently queue the inner
// presentation forever.

import SwiftUI

struct DishPreviewView: View {
    @Bindable var viewModel: SolveViewModel
    let dish: DishCard

    @Environment(EntitlementService.self) private var entitlements
    @Environment(RootCoordinator.self) private var coordinator
    /// Dismisses the enclosing ScanFlowRoot fullScreenCover. After
    /// it dismisses, TonightHome's `activeFreshCook` cover presents
    /// Cook Mode — sequential, no modal collision.
    @Environment(\.dismiss) private var dismiss

    @State private var hasCapturedSelection = false
    @State private var localFavorite: Bool = false

    /// Ingredient amount column min width — scales with Dynamic Type so
    /// amounts like "1 1/2 cups" don't clip at AX sizes. Value at
    /// default body is the previous hardcoded 80pt.
    @ScaledMetric(relativeTo: .subheadline) private var amountColumnMinWidth: CGFloat = 80

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                missingIngredientsSection
                ingredientsSection
                stepsSection
            }
            .padding()
        }
        .navigationTitle(dish.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    handleFavoriteTap()
                } label: {
                    // Favorite star uses `ember600` on active, `ink300` on
                    // inactive — the warm-palette counterpart to SwiftUI's
                    // default yellow. Stays on-brand across the paywall-
                    // trigger surfaces (DishPreview, Saved, Cook).
                    Image(systemName: localFavorite ? "star.fill" : "star")
                        .foregroundStyle(localFavorite ? Color.Stir.ember600 : Color.Stir.ink300)
                }
                .accessibilityLabel(localFavorite ? "Remove from favorites" : "Save to favorites")
            }
        }
        .safeAreaInset(edge: .bottom) {
            startCookingBar
                .padding(.horizontal)
                .padding(.bottom, 8)
                .background(.bar)
        }
        .onAppear {
            // Guard against re-capture on back-nav re-entry. NavigationStack
            // creates a fresh DishPreviewView on each push so @State resets,
            // meaning this fires exactly once per push — never on subsequent
            // .onAppear calls triggered by deeper navigation returning.
            guard !hasCapturedSelection else { return }
            hasCapturedSelection = true
            viewModel.selectDish(dish)
            // Initial favorite state reflects the persisted RecipePlan if any.
            localFavorite = viewModel.persistedRecipePlan(for: dish)?.isFavorite ?? false
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(dish.totalTimeMinutes) min", systemImage: "clock")
                    .accessibilityLabel("\(dish.totalTimeMinutes) minutes total time")
                Spacer()
                Label("Rank \(dish.rank)", systemImage: "trophy")
                    .accessibilityLabel("Rank \(dish.rank)")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text(dish.whyItFits)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            if !dish.reasoningSummary.isEmpty {
                Text(dish.reasoningSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var missingIngredientsSection: some View {
        if dish.missingIngredientCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Missing from your pantry", systemImage: "cart")
                    .font(.headline)
                Text("We'll flag these — pick them up or swap via substitution later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("\(dish.missingIngredientCount) item\(dish.missingIngredientCount == 1 ? "" : "s")")
                    .font(.subheadline.weight(.medium))
            }
            .padding()
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ingredients")
                .font(.headline)
            Text("Serves \(dish.recipePlan.servings)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(dish.recipePlan.ingredients.enumerated()), id: \.offset) { _, ing in
                    HStack(alignment: .top, spacing: 8) {
                        Text(ing.amountText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            // `minWidth`, not `width` — at AX1+ sizes the
                            // text may legitimately need more space than
                            // 80pt; a hard width would clip. Flexible lower
                            // bound keeps the column aligned at body size.
                            .frame(minWidth: amountColumnMinWidth, alignment: .leading)
                        Text(ing.displayName + (ing.isOptional ? "  (optional)" : ""))
                            .font(.subheadline)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(dish.recipePlan.steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.instructionText)
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                            if let secs = step.timerSeconds, secs > 0 {
                                Label("\(secs / 60) min timer", systemImage: "timer")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Favorite gate

    private func handleFavoriteTap() {
        // Gate: Free tier must resolve the paywall before a favorite
        // persists. effectiveTier handling in EntitlementService maps
        // "expired"/"none" → "free" so a lapsed Premium subscriber also
        // sees the paywall (correct — they lost the feature).
        switch entitlements.canAccess(.savedFavorites) {
        case .allowed:
            toggleFavoriteOptimistic()
        case .blockedByTier, .blockedByQuota, .blockedByBilling:
            coordinator.presentPaywall(.savedFavoritesGate)
        }
    }

    private func toggleFavoriteOptimistic() {
        guard let plan = viewModel.persistedRecipePlan(for: dish) else { return }
        let newValue = !localFavorite
        localFavorite = newValue
        viewModel.setFavorite(newValue, for: plan)
        if newValue {
            PostHogClient.shared.capture(
                .favoriteSaved,
                properties: BillingTelemetryProperties.favoriteSaved(
                    recipeOrigin: plan.typedOrigin.rawValue,
                ),
            )
        }
    }

    private var startCookingBar: some View {
        // Tap:
        //   1. Ask coordinator to queue a fresh Cook Mode session
        //      (recipe plan + household resolved from the VM).
        //   2. Dismiss ScanFlowRoot (we're inside its fullScreenCover).
        //   3. When ScanFlowRoot's dismiss animation completes,
        //      TonightHome's `.fullScreenCover(item: $activeFreshCook)`
        //      presents Cook Mode cleanly — no nested-modal collision.
        //
        // If persistedRecipePlan or currentHousehold is nil (rare CloudKit
        // nullify case, same guard as TonightHome.resumeCookMode), fall
        // through silently — no Cook Mode presents, no crash. Upstream
        // error handling catches the UX gap.
        Button {
            guard let plan = viewModel.persistedRecipePlan(for: dish),
                  let household = viewModel.currentHousehold
            else { return }
            coordinator.startCookMode(recipePlan: plan, household: household)
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .accessibilityHidden(true)
                Text("Start Cooking")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Opens Cook Mode step-by-step with optional timers.")
    }
}
