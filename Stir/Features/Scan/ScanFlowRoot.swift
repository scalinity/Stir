// ScanFlowRoot
//
// Hosts the full scan → solve → preview flow inside a single NavigationStack.
// Owns both ScanViewModel and SolveViewModel and chains them by handing
// the scan's confirmed ingredients to solve.
//
// Presented as a full-screen cover from TonightHomeView. Dismisses on
// Cancel at any step (swipe-down is disabled while camera session is live
// so users don't accidentally drop a capture).

import SwiftUI

struct ScanFlowRoot: View {
    @State private var scanViewModel: ScanViewModel
    @State private var solveViewModel: SolveViewModel
    @State private var path: [Route] = []
    @State private var showConstraintsSheet = false

    @Environment(\.dismiss) private var dismiss

    /// Needed for the `activeCookLaunch` observer below — when
    /// `DishPreviewView`'s Start Cooking handler flips that property,
    /// we MUST drop this cover so iOS can present TonightHome's Cook
    /// Mode cover (concurrent `.fullScreenCover`s queue the second
    /// silently otherwise — see RootCoordinator.activeCookLaunch
    /// doc-comment + the matching observers in SolveAgainRoot /
    /// OtherOptionsRoot). DishPreviewView's own `dismiss()` resolves
    /// inside the navigationDestination and pops the nav stack one
    /// level (back to DinnerOptionsView) instead of dismissing this
    /// cover; observing the launch signal at the body root, where
    /// `dismiss()` does map to the cover, is the reliable path.
    @Environment(RootCoordinator.self) private var coordinator

    private let cameraService: CameraService

    init(
        aiDispatch: AIDispatch,
        pantryRepo: PantryItemRepository,
        solveRepo: SolveRepository,
        householdStore: CurrentHouseholdStore,
        entitlements: EntitlementService,
        cameraService: CameraService = CameraService(),
        presentPaywall: ((PaywallTrigger) -> Void)? = nil,
    ) {
        self._scanViewModel = State(wrappedValue: ScanViewModel(
            aiDispatch: aiDispatch,
            pantryRepo: pantryRepo,
            householdStore: householdStore,
            entitlements: entitlements,
            presentPaywall: presentPaywall,
        ))
        self._solveViewModel = State(wrappedValue: SolveViewModel(
            aiDispatch: aiDispatch,
            solveRepo: solveRepo,
            householdStore: householdStore,
            entitlements: entitlements,
            presentPaywall: presentPaywall,
        ))
        self.cameraService = cameraService
    }

    enum Route: Hashable {
        case capture
        case review
        case options
        /// Selected-dish detail screen. `DishCard` is Hashable (via its
        /// own conformance on all stored fields), so the enum stays
        /// Hashable. We wrap the dish in a Route case rather than
        /// letting `NavigationLink` push a bare `DishCard` — the stack's
        /// typed path is `[Route]`, and SwiftUI refuses to activate a
        /// `NavigationLink(value:)` whose type doesn't match the path.
        case preview(DishCard)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScanPrimerBody(
                viewModel: scanViewModel,
                cameraService: cameraService,
                onContinue: { path.append(.capture) },
                onCancel: { dismiss() },
            )
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .capture:
                    ScanCaptureView(
                        viewModel: scanViewModel,
                        cameraService: cameraService,
                        onCaptured: { path.append(.review) },
                    )
                case .review:
                    ScanReviewView(
                        viewModel: scanViewModel,
                        onConfirm: { Task { await onReviewConfirmed() } },
                    )
                case .options:
                    DinnerOptionsView(
                        viewModel: solveViewModel,
                        onTune: { showConstraintsSheet = true },
                    )
                case let .preview(dish):
                    DishPreviewView(viewModel: solveViewModel, dish: dish)
                }
            }
            .sheet(isPresented: $showConstraintsSheet) {
                ConstraintsSheet(
                    viewModel: solveViewModel,
                    onSolve: {
                        // First solve → push the options screen onto
                        // the stack. Re-tune from options → we're
                        // already there; just rerun the solve in
                        // place. Pushing again would stack a duplicate
                        // route + show two back chevrons.
                        if case .options = path.last {
                            solveViewModel.startSolve()
                        } else {
                            path.append(.options)
                        }
                    },
                )
                .interactiveDismissDisabled(false)
            }
            .interactiveDismissDisabled(path.contains(.capture))
        }
        // Cook Mode handoff — mirrors SolveAgainRoot / OtherOptionsRoot.
        // When DishPreviewView's Start Cooking sets activeCookLaunch,
        // drop this cover so TonightHome's `.fullScreenCover(item:
        // $activeCookLaunch)` can present unobstructed.
        .onChange(of: coordinator.activeCookLaunch) { _, new in
            if new != nil {
                dismiss()
            }
        }
    }

    private func onReviewConfirmed() async {
        let result = await scanViewModel.confirmFromReview()
        solveViewModel.prepare(with: result.ingredients, parseID: result.parseID)
        showConstraintsSheet = true
    }
}

// ScanPrimerBody — same copy + CTA as the old ScanPrimerView, but without
// its own NavigationStack (the parent ScanFlowRoot owns navigation now).
// Kept inline here to avoid a no-added-value file.

private struct ScanPrimerBody: View {
    @Bindable var viewModel: ScanViewModel
    let cameraService: CameraService
    let onContinue: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 64

    var body: some View {
        VStack(spacing: CGFloat.Stir.space5) {
            Spacer()
            heroIcon
                .accessibilityHidden(true)

            VStack(spacing: CGFloat.Stir.space3) {
                Text("Point at what you've got.")
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                    .multilineTextAlignment(.center)
                Text("Stir turns one photo of your fridge, pantry, or counter into three dinner options you can actually cook tonight.")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink500)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, CGFloat.Stir.space5)

            Spacer()

            VStack(spacing: CGFloat.Stir.space3) {
                PrimaryButton(
                    title: cameraService.currentPermission == .authorized
                        ? "Start scanning"
                        : "Allow camera access",
                    action: { Task { await grantAndContinue() } },
                )
                TextButton(title: "Not now", action: onCancel)
            }
            .padding(.horizontal, CGFloat.Stir.screenMarginHero)
            .padding(.bottom, CGFloat.Stir.space5)
        }
        .background(Color.Stir.paper50)
        // Keep `navigationTitle` for the back-chevron label +
        // VoiceOver; the visible title comes from the .principal
        // toolbar item below in the Stir display serif. Default
        // chrome would render in SF Pro Bold and break the
        // cross-screen rhythm (matches Settings / Saved / Pantry).
        .navigationTitle("Scan kitchen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .principal) {
                Text("Scan kitchen")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    @ViewBuilder
    private var heroIcon: some View {
        // Respect Reduce Motion — no pulse for users who've opted out.
        // Use @ScaledMetric so the hero scales with Dynamic Type rather
        // than clipping at XXXL or looking tiny at XS.
        let base = Image.Stir.scan
            .font(.system(size: heroIconSize, weight: .semibold)) // justification: dynamic-scaled hero icon size via @ScaledMetric, not a static literal
            .foregroundStyle(Color.Stir.ember600)
        if reduceMotion {
            base
        } else {
            base.symbolEffect(.pulse)
        }
    }

    private func grantAndContinue() async {
        let before = cameraService.currentPermission
        let state = await cameraService.requestPermission()
        PostHogClient.shared.capture(.cameraPermissionResult, properties: [
            "granted": state == .authorized,
            "previously_determined": before != .notDetermined,
        ])
        if state == .authorized {
            onContinue()
        }
    }
}
