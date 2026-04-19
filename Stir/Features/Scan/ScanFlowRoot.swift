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

    private let cameraService: CameraService

    init(
        aiDispatch: AIDispatch,
        pantryRepo: PantryItemRepository,
        solveRepo: SolveRepository,
        householdStore: CurrentHouseholdStore,
        entitlements: EntitlementService,
    ) {
        self._scanViewModel = State(wrappedValue: ScanViewModel(
            aiDispatch: aiDispatch,
            pantryRepo: pantryRepo,
            householdStore: householdStore,
            entitlements: entitlements,
        ))
        self._solveViewModel = State(wrappedValue: SolveViewModel(
            aiDispatch: aiDispatch,
            solveRepo: solveRepo,
            householdStore: householdStore,
        ))
        self.cameraService = CameraService()
    }

    enum Route: Hashable {
        case capture
        case review
        case options
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
                    DinnerOptionsView(viewModel: solveViewModel)
                }
            }
            .navigationDestination(for: DishCard.self) { dish in
                DishPreviewView(viewModel: solveViewModel, dish: dish)
            }
            .sheet(isPresented: $showConstraintsSheet) {
                ConstraintsSheet(
                    viewModel: solveViewModel,
                    onSolve: {
                        path.append(.options)
                    },
                )
                .interactiveDismissDisabled(false)
            }
            .interactiveDismissDisabled(path.contains(.capture))
        }
    }

    private func onReviewConfirmed() async {
        let ingredients = await scanViewModel.confirmFromReview()
        solveViewModel.prepare(with: ingredients)
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

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)

            VStack(spacing: 12) {
                Text("Point at what you've got.")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Stir turns one photo of your fridge, pantry, or counter into three dinner options you can actually cook tonight.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 24)

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task { await grantAndContinue() }
                } label: {
                    Text(cameraService.currentPermission == .authorized ? "Start scanning" : "Allow camera access")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                Button("Not now", action: onCancel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .navigationTitle("Scan kitchen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel", action: onCancel)
            }
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
