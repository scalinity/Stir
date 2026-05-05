// DishPreviewView
//
// Step-4 landing page. Shows the chosen dish in full: ingredients,
// steps, missing-from-pantry callouts. "Start Cooking" dismisses the
// parent ScanFlowRoot and routes Cook Mode presentation through
// `RootCoordinator.activeFreshCook` so it presents cleanly at the
// TonightHome layer — nested fullScreenCovers (ScanFlow + CookMode)
// hit iOS's "only single sheet" limit and silently queue the inner
// presentation forever.

import OSLog
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
    @State private var showGrocery: Bool = false
    /// Surfaces a toast when "Start Cooking" can't resolve the
    /// persisted RecipePlan or current household — a rare CloudKit
    /// race or upsert failure. Without this the button was a silent
    /// no-op; users would tap repeatedly with no feedback.
    @State private var errorToast: StirToastPayload?

    /// Ingredient amount column min width — scales with Dynamic Type so
    /// amounts like "1 1/2 cups" don't clip at AX sizes. Value at
    /// default body is the previous hardcoded 80pt.
    @ScaledMetric(relativeTo: .subheadline) private var amountColumnMinWidth: CGFloat = 80

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                header
                missingIngredientsSection
                ingredientsSection
                stepsSection
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.vertical, CGFloat.Stir.space4)
        }
        .background(Color.Stir.paper50)
        // Keep `navigationTitle` for the back-chevron label that
        // any caller pushed onto can read, plus VoiceOver. The
        // visible title comes from the .principal toolbar item
        // below in the Stir display serif (matches Settings /
        // Saved / OtherOptionsRoot grammar). Default chrome would
        // render in SF Pro Bold and break cross-screen rhythm.
        // `minimumScaleFactor` keeps long Gemini-generated names
        // readable when the bar is squeezed by trailing buttons —
        // mid-word "Quick Flatbrea…" truncation is the failure
        // mode we're avoiding.
        .navigationTitle(dish.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(dish.title)
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 14) {
                    Button {
                        presentGrocery()
                    } label: {
                        Image(systemName: "cart")
                            .foregroundStyle(Color.Stir.ink700)
                    }
                    .accessibilityLabel("Add to grocery")

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
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(isPresented: $showGrocery) {
            if let plan = viewModel.persistedRecipePlan(for: dish),
               let household = viewModel.currentHousehold {
                let vm = GroceryViewModel(
                    recipePlan: plan,
                    household: household,
                    aiDispatch: viewModel.aiDispatch,
                )
                GroceryListView(
                    viewModel: vm,
                    onDismiss: { showGrocery = false },
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Solid paper50 + hairline divider matches the
            // OutcomeFeedbackView / Cook Mode action-bar grammar. The
            // previous `.bar` material rendered translucent and let
            // scroll content bleed through under the button, which read
            // as the CTA "floating" mid-air instead of anchored to the
            // bottom edge.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.Stir.divider)
                    .frame(height: 1)
                startCookingBar
                    .padding(.horizontal, CGFloat.Stir.screenMargin)
                    .padding(.top, CGFloat.Stir.space3)
                    .padding(.bottom, CGFloat.Stir.space3)
            }
            .background(Color.Stir.paper50)
        }
        .stirToast($errorToast)
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
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            HStack {
                HStack(spacing: CGFloat.Stir.space1) {
                    Image.Stir.clock
                        .font(.system(size: CGFloat.Stir.iconSm))
                    Text("\(dish.totalTimeMinutes) min")
                        .stirFont(.bodySm)
                }
                Spacer()
                FitLabel(kind: .bestFit)
            }
            .foregroundStyle(Color.Stir.ink500)
            .accessibilityLabel("\(dish.totalTimeMinutes) minutes total, rank \(dish.rank)")

            Text(dish.whyItFits)
                .stirFont(.bodyLg)
                .foregroundStyle(Color.Stir.ink900)
                .fixedSize(horizontal: false, vertical: true)

            if !dish.reasoningSummary.isEmpty {
                Text(dish.reasoningSummary)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var missingIngredientsSection: some View {
        if dish.missingIngredientCount > 0 {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                HStack(spacing: CGFloat.Stir.space1 + 2) {
                    Image.Stir.cart
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                        .foregroundStyle(Color.Stir.amber600)
                    Text("Missing from your pantry")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink900)
                }
                Text("We'll flag these — pick them up or swap via substitution later.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                Text("\(dish.missingIngredientCount) item\(dish.missingIngredientCount == 1 ? "" : "s")")
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.amber600)
            }
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard(fill: Color.Stir.amber100, borderColor: nil)
        }
    }

    private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ingredients")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                Spacer()
                Text("Serves \(dish.recipePlan.servings)")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }

            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 + 2) {
                ForEach(Array(dish.recipePlan.ingredients.enumerated()), id: \.offset) { _, ing in
                    HStack(alignment: .top, spacing: CGFloat.Stir.space2) {
                        Text(ing.amountText)
                            .stirFont(.monoMd)
                            .foregroundStyle(Color.Stir.ink500)
                            .frame(minWidth: amountColumnMinWidth, alignment: .leading)
                        Text(ing.displayName + (ing.isOptional == true ? "  (optional)" : ""))
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink900)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard()
        }
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            Text("Steps")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)

            VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
                ForEach(Array(dish.recipePlan.steps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: CGFloat.Stir.space3 - 2) {
                        Text("\(idx + 1).")
                            .stirFont(.labelLg)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.Stir.ink500)
                        VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                            Text(step.instructionText)
                                .stirFont(.bodyMd)
                                .foregroundStyle(Color.Stir.ink900)
                                .fixedSize(horizontal: false, vertical: true)
                            if let secs = step.timerSeconds, secs > 0 {
                                HStack(spacing: CGFloat.Stir.space1) {
                                    Image.Stir.timer
                                        .font(.system(size: CGFloat.Stir.iconSm))
                                    Text("\(secs / 60) min timer")
                                        .stirFont(.bodySm)
                                }
                                .foregroundStyle(Color.Stir.ember600)
                            }
                        }
                    }
                }
            }
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard()
        }
    }

    // MARK: - Favorite gate

    private func handleFavoriteTap() {
        // Gate: Free tier must resolve the paywall before a favorite
        // persists. effectiveTier handling in EntitlementService maps
        // "expired"/"none" → "free" so a lapsed Premium subscriber also
        // sees the paywall (correct — they lost the feature).
        entitlements.gate(
            .savedFavorites,
            paywall: { coordinator.presentPaywall(.savedFavoritesGate) },
            allow: { toggleFavoriteOptimistic() },
        )
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

    /// Open the Grocery flow for this dish. Nil-guards on persisted
    /// plan + household (CloudKit nullify race) mirror `startCookingBar`.
    private func presentGrocery() {
        guard viewModel.persistedRecipePlan(for: dish) != nil,
              viewModel.currentHousehold != nil
        else {
            Logger.ui.error(
                "dish_preview_grocery_missing_plan_or_household rank=\(dish.rank, privacy: .public)",
            )
            errorToast = StirToastPayload(
                id: UUID(),
                message: "Couldn't build a grocery list for this one. Try another dish.",
                kind: .failed,
            )
            return
        }
        showGrocery = true
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
        PrimaryButton(title: "Start Cooking") {
            guard let plan = viewModel.persistedRecipePlan(for: dish),
                  let household = viewModel.currentHousehold
            else {
                Logger.ui.error(
                    "dish_preview_start_cooking_missing_plan_or_household rank=\(dish.rank, privacy: .public)",
                )
                errorToast = StirToastPayload(
                    id: UUID(),
                    message: "Couldn't start this one. Try another dish.",
                    kind: .failed,
                )
                return
            }
            coordinator.startCookMode(recipePlan: plan, household: household)
            dismiss()
        }
        .accessibilityHint("Opens Cook Mode step-by-step with optional timers.")
    }
}
