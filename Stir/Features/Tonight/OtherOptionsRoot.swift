// OtherOptionsRoot
//
// Presents the OTHER 1–2 dishes from the same MealSolveRequest as the
// current Tonight pick — the affordance behind Tonight Home's
// "Other options" hero-card button. No AI spend: data is rehydrated
// from persisted Core Data via SolveRepository.
//
// Rendering: paper50 background, list of `DishOptionCard`s using
// the existing DesignSystem component. Tapping a card pushes the
// existing `DishPreviewView` so users land on a familiar full-detail
// surface (ingredients, steps, missing-ingredient callouts, Start
// Cooking, Save for later, Add to grocery).
//
// Why a dedicated root vs reusing DinnerOptionsView: DinnerOptionsView's
// `.task(id: "solve-once")` auto-issues a solve when phase ==
// .constraints. We seed the VM with phase = .options (no AI call), but
// DinnerOptionsView's toolbar carries a "Tune" button that re-presents
// a constraints sheet — irrelevant to this flow. A small dedicated
// root keeps the grammar tight to "browse alts; pick one to cook."
//
// Cover dismissal: mirrors SolveAgainRoot — when DishPreviewView's
// Start Cooking sets `coordinator.activeCookLaunch`, we observe it
// and call `onDismiss()` so the cover drops before the Cook Mode
// fullScreenCover at TonightHome presents (iOS modal stack guard).

import SwiftUI

struct OtherOptionsRoot: View {
    @State private var solveViewModel: SolveViewModel
    @State private var path: [Route] = []

    /// Coordinator reaches us via Environment (matches SolveAgainRoot
    /// pattern) so we can observe `activeCookLaunch` and bail when
    /// DishPreviewView kicks off Cook Mode from the alt.
    @Environment(RootCoordinator.self) private var coordinator

    private let alternates: [SolveRepository.OtherOption]
    private let onDismiss: () -> Void

    /// Local route enum — we don't reuse `ScanFlowRoot.Route` because
    /// this surface only has one destination (preview). Avoids
    /// adopting the broader Route enum's irrelevant cases (`capture`,
    /// `review`, `options`) that would otherwise need defensive
    /// EmptyView fallbacks here.
    enum Route: Hashable {
        case preview(DishCard)
    }

    init(
        currentPickSuggestedDishId: UUID,
        aiDispatch: AIDispatch,
        solveRepo: SolveRepository,
        householdStore: CurrentHouseholdStore,
        entitlements: EntitlementService,
        presentPaywall: ((PaywallTrigger) -> Void)?,
        onDismiss: @escaping () -> Void,
    ) {
        self.onDismiss = onDismiss

        // Resolve alts + rehydrate their DishCards in a SINGLE Core
        // Data fetch via `latestOtherOptionsWithCards`. The viewModel
        // state is captured before the first body render so the user
        // lands on the populated list rather than an empty flash.
        // Household is required to scope the solve query — missing
        // household means the empty state renders (no alts).
        //
        // We deliberately do NOT rehydrate the current PICK's dish card.
        // The user can only tap an ALT card from this surface (the hero
        // is excluded from `alternates`), so `persistedRecipePlan(for:)`
        // is only ever asked to resolve an alt's rank → UUID. The seed
        // tolerates the hero's slot being a placeholder (logged at
        // debug level for triage, not surfaced).
        let household = householdStore.profile
        var alts: [SolveRepository.OtherOption] = []
        var seedInputs: [(rank: Int, card: DishCard, dishId: UUID)] = []
        if let household {
            let pairs = solveRepo.latestOtherOptionsWithCards(
                excluding: currentPickSuggestedDishId,
                for: household,
            )
            alts = pairs.map(\.option)
            seedInputs = pairs.map { ($0.option.rank, $0.card, $0.option.suggestedDishId) }
        }
        self.alternates = alts

        let vm = SolveViewModel(
            aiDispatch: aiDispatch,
            solveRepo: solveRepo,
            householdStore: householdStore,
            entitlements: entitlements,
            presentPaywall: presentPaywall,
        )
        vm.seedFromPersistedSolve(inputs: seedInputs)
        self._solveViewModel = State(wrappedValue: vm)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                // Keep `navigationTitle` for the back-chevron label that
                // pushed destinations (DishPreviewView) read; the
                // visual title comes from the .principal toolbar item
                // below in the Stir display serif (matches Settings /
                // Saved / Substitution sheet so cross-screen rhythm
                // holds). Default `navigationTitle` chrome would fall
                // back to SF Pro Bold and read as off-brand.
                .navigationTitle("Other options")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: onDismiss)
                    }
                    ToolbarItem(placement: .principal) {
                        Text("Other options")
                            .stirFont(.displaySm)
                            .foregroundStyle(Color.Stir.textPrimary)
                    }
                }
                .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case let .preview(dish):
                        DishPreviewView(viewModel: solveViewModel, dish: dish)
                    }
                }
                .background(Color.Stir.paper50)
        }
        // Same Cook Mode handoff dance as SolveAgainRoot — DishPreviewView
        // → Start Cooking sets activeCookLaunch; we drop our cover so
        // TonightHome's CookMode cover can present unobstructed.
        .onChange(of: coordinator.activeCookLaunch) { _, new in
            if new != nil {
                onDismiss()
            }
        }
    }

    // MARK: - Body content

    @ViewBuilder
    private var content: some View {
        if alternates.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
                    Text("Other dishes from this round.")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                        .padding(.top, CGFloat.Stir.space2)

                    ForEach(alternates) { option in
                        if let card = solveViewModel.slots
                            .first(where: { $0.rank == option.rank })?
                            .dish
                        {
                            // Mirrors DinnerOptionsView's slot-card pattern:
                            // NavigationLink wraps the card, DishOptionCard
                            // does not host its own Button. Press feedback
                            // comes from DishOptionCardStyle.
                            NavigationLink(value: Route.preview(card)) {
                                DishOptionCard(
                                    rank: option.rank,
                                    title: option.title,
                                    totalTimeMinutes: option.totalTimeMinutes,
                                    whyItFits: option.whyItFits,
                                    missingIngredientCount: option.missingIngredientCount,
                                    tonightPick: false,
                                )
                            }
                            .buttonStyle(DishOptionCardStyle())
                        }
                    }
                }
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.vertical, CGFloat.Stir.space4)
            }
        }
    }

    /// Empty state — the latest solve's other dishes are unresolvable
    /// (rare CloudKit conflict / soft-delete). Surface a simple
    /// "no alternates" message + a Done CTA. We don't push to "Solve
    /// again" here because the user already has SolveAgain on Tonight;
    /// reaching this state via the empty fallback shouldn't add a
    /// surprise re-solve flow.
    private var emptyState: some View {
        VStack(spacing: CGFloat.Stir.space3) {
            Spacer(minLength: CGFloat.Stir.space7)
            Image.Stir.sparkles
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(Color.Stir.ember600)
                .frame(width: 80, height: 80)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusHero, style: .continuous)
                        .fill(Color.Stir.ember100),
                )

            Text("No other options here.")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.center)

            Text("Try Solve again on the Tonight screen for a fresh round of dinners.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CGFloat.Stir.space4)

            PrimaryButton(title: "Done", action: onDismiss)
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.top, CGFloat.Stir.space3)

            Spacer()
        }
        .padding(.horizontal, CGFloat.Stir.screenMargin)
    }
}
