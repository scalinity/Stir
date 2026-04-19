// CookModeRoot
//
// fullScreenCover root for Cook Mode. Creates the CookingSession on
// presentation, hosts the StepCardView, and handles sheet transitions
// to SubstitutionSheet + OutcomeFeedback. Returns to Tonight Home via
// dismiss on exit or finish.
//
// Step-4 wiring: DishPreviewView's Start Cooking button now presents
// this view as fullScreenCover (not NavigationStack push) so a back-
// swipe can't accidentally drop the user out of cooking.

import OSLog
import SwiftUI

struct CookModeRoot: View {
    let recipePlan: RecipePlan
    let household: HouseholdProfile
    let aiDispatch: AIDispatch
    let source: CookModeViewModel.EntrySource
    /// Existing session to reuse — drives the Tonight Home "Resume
    /// cooking" path so resume actually resumes instead of silently
    /// orphaning the prior session and creating a fresh one. Nil =
    /// fresh start; create a new session in .task.
    let existingSession: CookingSession?
    let onDismiss: () -> Void

    @State private var viewModel: CookModeViewModel?
    @State private var initError: String?

    init(
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        aiDispatch: AIDispatch,
        source: CookModeViewModel.EntrySource,
        existingSession: CookingSession? = nil,
        onDismiss: @escaping () -> Void,
    ) {
        self.recipePlan = recipePlan
        self.household = household
        self.aiDispatch = aiDispatch
        self.source = source
        self.existingSession = existingSession
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            if let viewModel {
                StepCardView(viewModel: viewModel)
                    .sheet(isPresented: Binding(
                        get: { viewModel.substitutionPresentationRequested },
                        set: { viewModel.substitutionPresentationRequested = $0 },
                    )) {
                        SubstitutionSheetView(
                            recipePlan: recipePlan,
                            household: household,
                            session: viewModel.session,
                            currentStep: viewModel.currentStep,
                            aiDispatch: aiDispatch,
                            onDismiss: { viewModel.substitutionPresentationRequested = false },
                        )
                    }
                    .fullScreenCover(isPresented: Binding(
                        get: { viewModel.finishPresentationRequested },
                        set: { viewModel.finishPresentationRequested = $0 },
                    )) {
                        OutcomeFeedbackView(
                            session: viewModel.session,
                            onSubmitted: {
                                viewModel.finishPresentationRequested = false
                                onDismiss()
                            },
                        )
                    }
            } else if let message = initError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .accessibilityHidden(true)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Button {
                        onDismiss()
                    } label: {
                        Text("Close")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(40)
            } else {
                ProgressView("Getting Cook Mode ready…")
            }
        }
        .task {
            guard viewModel == nil, initError == nil else { return }
            do {
                let repo = CookingSessionRepository()
                let session: CookingSession
                if let existing = existingSession, existing.isResumable {
                    session = existing
                } else {
                    session = try repo.createSession(
                        on: household,
                        for: recipePlan,
                        entryPoint: entryPoint(for: source),
                    )
                }
                let vm = CookModeViewModel(
                    session: session,
                    recipePlan: recipePlan,
                    household: household,
                    source: source,
                )
                self.viewModel = vm
                // Reconcile any leftover timers from a cross-device
                // arrival. No-op on fresh sessions.
                await vm.reconcileTimersOnForeground()
            } catch {
                initError = "Couldn't start Cook Mode. Please try again."
                Logger.ui.error("CookModeRoot createSession failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        .onChange(of: viewModel?.shouldDismiss ?? false) { _, shouldDismiss in
            // VM flips shouldDismiss only when the user chose "Pause and
            // resume later" or "Abandon". "Keep cooking" leaves it false.
            if shouldDismiss { onDismiss() }
        }
    }

    private func entryPoint(for source: CookModeViewModel.EntrySource) -> CookingSession.EntryPoint {
        switch source {
        case .solve: return .solve
        case .saved: return .saved
        case .imported: return .imported
        case .leftovers: return .leftovers
        }
    }
}
