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

    @Environment(EntitlementService.self) private var entitlements
    @Environment(RootCoordinator.self) private var coordinator

    @State private var viewModel: CookModeViewModel?
    @State private var voiceDriver: SpeechFallbackService?
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
                    // Transient voice-error toast (empty transcript,
                    // mic denied, backend error). Auto-clears on tap.
                    .overlay(alignment: .top) {
                        if let msg = viewModel.voiceToastMessage {
                            VoiceToastView(message: msg) {
                                viewModel.voiceToastMessage = nil
                            }
                            .padding(.top, 60)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: viewModel.voiceToastMessage)
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

                // Driver selection (C.4 plumbing for C.2, ADR 0007):
                // `disable_cook_realtime` is the server-side kill switch.
                // Today it has no effect because RealtimeSession (C.2)
                // isn't implemented yet, but reading + passing the flag
                // means C.4 doesn't need re-plumbing when C.2 lands.
                // Once C.2 exists, the branch will be:
                //   if killSwitch || !canVoice → fallback
                //   else                        → RealtimeSession
                // For now: always fallback (the only driver).
                //
                // canVoice is pinned to a local so the single read at
                // Cook Mode entry drives both driver instantiation AND
                // the VM's `voiceDriver` arg — without the pin, a
                // bootstrap refresh mid-task could split the two reads
                // and leave the VM with a nil driver even though we
                // pre-warmed one.
                let killSwitch = entitlements.flagBool(forKey: "disable_cook_realtime") ?? false
                let canVoice = entitlements.canAccess(.voiceCookMode) == .allowed
                var driverForVM: (any VoiceSessionDriver)? = nil
                if canVoice {
                    // Pre-warm the AVAudioSession + STT + TTS so the
                    // first mic tap engages in <200ms. ADR 0007
                    // pre-commit: pre-warm at Cook Mode entry, not at
                    // first tap.
                    let newDriver = SpeechFallbackService(
                        aiDispatch: aiDispatch,
                        voiceTurnRepository: VoiceTurnRepository(),
                        cookingSession: session,
                    )
                    do {
                        try AVAudioSessionConfigurator.activateForCookMode()
                        try await newDriver.preWarm()
                        self.voiceDriver = newDriver
                        driverForVM = newDriver
                        Logger.voice.info(
                            "cook_mode_voice_prewarmed kill_switch=\(killSwitch, privacy: .public)",
                        )
                    } catch {
                        // Pre-warm failure is non-fatal — mic button
                        // will be visible but tap will surface an
                        // inline toast. The VM still gets the driver so
                        // it can report "voice not available" cleanly
                        // rather than crash.
                        Logger.voice.warning(
                            "cook_mode_voice_prewarm_failed: \(error.localizedDescription, privacy: .public)",
                        )
                        self.voiceDriver = newDriver
                        driverForVM = newDriver
                    }
                }
                // Free tier: no driver instantiated at all. The mic
                // button still renders (Daniel's pre-commit) and the
                // VM routes the tap to the paywall without touching
                // SFSpeechRecognizer / AVAudioEngine / AVSpeechSynthesizer.

                let capturedCoordinator = coordinator
                let vm = CookModeViewModel(
                    session: session,
                    recipePlan: recipePlan,
                    household: household,
                    source: source,
                    entitlements: entitlements,
                    voiceDriver: driverForVM,
                    disableCookRealtime: killSwitch,
                    presentPaywall: { trigger in capturedCoordinator.presentPaywall(trigger) },
                )
                self.viewModel = vm
                // Reconcile any leftover timers from a cross-device
                // arrival. No-op on fresh sessions.
                await vm.reconcileTimersOnForeground()

                // C.5: `cook_voice_default_on` (spec §15 client flag) —
                // Premium+ only; auto-begin the first voice turn so the
                // user doesn't have to tap mic on Cook Mode entry.
                //
                // Gated on:
                //   - flag=true (PostHog-sourced)
                //   - canVoice (resolved earlier — Premium+ with entitlement)
                //   - driverForVM != nil (pre-warm didn't hard-fail to no-driver)
                //   - !killSwitch (kill switch never auto-engages)
                // The VM routes the tap normally — permission prompts,
                // telemetry, the works — so we don't short-circuit any
                // of its guards. Auto-engage is just "simulated first
                // tap on entry", not a separate code path.
                let autoEngage = entitlements.flagBool(forKey: "cook_voice_default_on") ?? false
                if autoEngage && canVoice && driverForVM != nil && !killSwitch {
                    Logger.voice.info("cook_mode_voice_auto_engage")
                    await vm.handleMicTap()
                }
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

// MARK: - Voice toast

/// Small top-of-screen toast for voice-path errors. Tappable to dismiss;
/// caller's onDismiss is the only way to clear the message (no auto-
/// timeout — kitchen hands may be occupied).
private struct VoiceToastView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}
