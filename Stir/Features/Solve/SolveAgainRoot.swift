// SolveAgainRoot — a Solve flow seeded by a previously-saved pantry.
//
// Constraints sheet → DinnerOptionsView → DishPreviewView, seeded with
// a pre-prepared `[IngredientLite]` from the latest pantry snapshot.
// Mirrors `ScanFlowRoot`'s solve half but skips scan/review — Tonight's
// "Solve again" tile goes straight from "I have a pantry" to "give me
// three new dishes."
//
// CR1-W2 fix (2026-05-04): moved out of TonightHomeView.swift, where it
// was a private type living in the wrong feature directory.
//
// Route reuse: `ScanFlowRoot.Route` is the path-element type because
// `DinnerOptionsView`'s `NavigationLink(value:)` push hard-codes that
// enum's `.preview(dish)` case (the Solve flow's nav protocol shouldn't
// fork two parallel Route enums for the same destinations). `.capture`
// and `.review` are valid Route cases but unreachable from this entry —
// handled defensively in the destination switch. A future cleanup could
// hoist `Route` to a shared `SolveRoute.swift`; today's diff is the
// file-relocation half of CR1-W2 only.
//
// Presentation contract: the constraints sheet auto-presents on mount
// so the user always sets time/cuisine/goal before the AI streams.
// Dismissing the sheet without ever solving (path empty when onDismiss
// fires) auto-dismisses the cover — there's nothing meaningful behind a
// closed sheet at that point.

import SwiftUI

struct SolveAgainRoot: View {
    @State private var solveViewModel: SolveViewModel
    @State private var path: [ScanFlowRoot.Route] = []
    @State private var showConstraintsSheet = true

    /// Coordinator-via-Environment matches the established pattern in
    /// SavedMealsView / SettingsRootView / DishPreviewView. We need it
    /// here for the `activeCookLaunch` observer below — when
    /// `DishPreviewView` flips that property as part of its Start
    /// Cooking handler, we have to dismiss this cover so iOS can
    /// present the Cook Mode cover from TonightHome (concurrent
    /// `.fullScreenCover`s queue the second one silently otherwise).
    @Environment(RootCoordinator.self) private var coordinator

    private let onDismiss: () -> Void

    init(
        ingredients: [DinnerSolveRequest.IngredientLite],
        aiDispatch: AIDispatch,
        solveRepo: SolveRepository,
        householdStore: CurrentHouseholdStore,
        entitlements: EntitlementService,
        presentPaywall: ((PaywallTrigger) -> Void)?,
        onDismiss: @escaping () -> Void,
    ) {
        let vm = SolveViewModel(
            aiDispatch: aiDispatch,
            solveRepo: solveRepo,
            householdStore: householdStore,
            entitlements: entitlements,
            presentPaywall: presentPaywall,
        )
        // `parseID: nil` is intentional — this entry doesn't originate
        // in a scan, so the dinner-solve request won't carry a parse-
        // funnel link. Backend handles a nil parseID as "solve from
        // user-supplied pantry" without complaint.
        vm.prepare(with: ingredients, parseID: nil)
        self._solveViewModel = State(wrappedValue: vm)
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack(path: $path) {
            // Placeholder root — almost never visible. The constraints
            // sheet auto-presents on mount, and `handleSheetDismiss`
            // closes the cover on sheet-dismissal-without-solving.
            // Hiding the nav bar prevents an empty "Solve again" title
            // from flashing during the brief sheet→options transition
            // when the user solves successfully.
            Color.Stir.paper50
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ScanFlowRoot.Route.self) { route in
                    switch route {
                    case .options:
                        DinnerOptionsView(
                            viewModel: solveViewModel,
                            onTune: { showConstraintsSheet = true },
                        )
                        // Cancel lives at the .options level — that's
                        // the only reachable surface where the user
                        // might want to back out of the cover entirely
                        // (the constraints sheet has its own Cancel;
                        // DishPreviewView has system back-chevron).
                        // Without this, DinnerOptionsView's only
                        // toolbar action is `Tune` and the user has
                        // no way to leave the cover except swipe-down
                        // (which `.fullScreenCover` doesn't honor).
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cancel") { onDismiss() }
                            }
                        }
                    case let .preview(dish):
                        DishPreviewView(viewModel: solveViewModel, dish: dish)
                    case .capture, .review:
                        // Unreachable from this entry but the Route enum
                        // is shared with ScanFlowRoot. Render an
                        // EmptyView rather than crashing if state ever
                        // drifts.
                        EmptyView()
                    }
                }
                .sheet(
                    isPresented: $showConstraintsSheet,
                    onDismiss: handleSheetDismiss,
                ) {
                    ConstraintsSheet(
                        viewModel: solveViewModel,
                        onSolve: handleConstraintsSolve,
                    )
                }
        }
        // Cook Mode handoff — when `DishPreviewView`'s Start Cooking
        // sets `coordinator.activeCookLaunch`, we MUST dismiss this
        // cover so the Cook Mode `.fullScreenCover` at TonightHome can
        // present (iOS 18/26 silently queues the second concurrent
        // cover otherwise). DishPreviewView's own `dismiss()` only
        // pops the navigation stack one level — it doesn't drop the
        // cover. Observing the launch signal at this level closes the
        // cover via the bound coordinator binding the moment a Cook
        // Mode launch is requested.
        .onChange(of: coordinator.activeCookLaunch) { _, new in
            if new != nil {
                onDismiss()
            }
        }
    }

    /// `ConstraintsSheet`'s "Find me dinner" action. Mirrors
    /// `ScanFlowRoot`'s logic: first solve pushes `.options` onto the
    /// stack so DinnerOptionsView appears; subsequent re-tunes (when
    /// already on `.options`) just kick off another solve in place
    /// without stacking duplicate routes + back chevrons.
    private func handleConstraintsSolve() {
        if case .options = path.last {
            solveViewModel.startSolve()
        } else {
            path.append(.options)
        }
    }

    /// Dismissing the sheet without ever pushing `.options` (path
    /// stays empty) means the user backed out before solving — close
    /// the cover so they don't end up looking at a blank paper-50
    /// screen. After at least one solve, the path is non-empty and
    /// the sheet's dismissal is just a "go back to options" gesture.
    private func handleSheetDismiss() {
        if path.isEmpty {
            onDismiss()
        }
    }
}
