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
    /// Retained reference to the concrete voice driver so the view
    /// owns its lifetime for the duration of Cook Mode. May be either
    /// a `RealtimeSession` (C.2 Live path) or a `SpeechFallbackService`
    /// (C.3 fallback) — typed as the protocol existential so the view
    /// doesn't branch on driver type.
    @State private var voiceDriver: (any VoiceSessionDriver)?
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

                let killSwitch = entitlements.flagBool(forKey: "disable_cook_realtime") ?? false
                let canVoice = entitlements.canAccess(.voiceCookMode) == .allowed
                let driverForVM = await buildVoiceDriver(session: session)

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

                // Wire callbacks on the driver that was preWarmed above.
                wireVoiceDriver(driverForVM, vm: vm)

                // Register the rebuild hook so the VM can ask for a
                // fresh driver after closeVoiceSession(). Without this,
                // every "Ask with voice" tap post-close surfaced
                // "Voice isn't available on this device" because the
                // prior driver was nilled out (observed 2026-04-22).
                vm.onRequestNewVoiceSession = { [weak vm] in
                    guard let vm else { return }
                    let newDriver = await self.buildVoiceDriver(session: session)
                    vm.attachVoiceDriver(newDriver)
                    self.wireVoiceDriver(newDriver, vm: vm)
                }

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
        .onDisappear {
            // Defense in depth: the VM's exit() path is the canonical
            // teardown site (calls driver.close + AVAudioSession
            // deactivate), but if the user dismisses via a code path
            // that doesn't run exit() — e.g., a swipe-down on the
            // fullScreenCover, or the parent dismissing for another
            // reason — close() on the driver still needs to fire so
            // the WebSocket/mic tap/audio session all tear down. Both
            // calls are idempotent (close() has internal guards;
            // deactivate() uses an isActiveForCookMode flag), so a
            // second invocation after VM exit is a safe no-op.
            //
            // Reading `self.voiceDriver` (which some VM paths nil
            // mid-session on invariant violations) would miss teardown
            // if nil'd before this fires. `voiceDriver?.close()` on a
            // nil @State is a no-op — acceptable because the nil-ing
            // path already called close(). Kept simple by design.
            voiceDriver?.close()
            AVAudioSessionConfigurator.deactivate()
        }
        // Paywall presentation from inside Cook Mode.
        //
        // RootView also binds a `.fullScreenCover` to
        // `$coordinator.activePaywallTrigger`, which works for every
        // feature except this one: Cook Mode is itself a fullScreenCover
        // presented from TonightHome inside RootView. When the Free-tier
        // user taps "Ask with voice", RootView's VC is already presenting
        // Cook Mode, so RootView's paywall cover can't present a second
        // modal on top — iOS silently queues it and the user sees
        // nothing.
        //
        // Mirroring the modifier here presents the paywall from Cook
        // Mode's own VC, which has no active modal, so presentation
        // succeeds. On dismiss we clear the trigger the same way
        // RootView does. Both bindings read the same state; SwiftUI's
        // reconciler picks the leaf-most modifier whose source VC can
        // actually present — CookModeRoot wins while it's in the tree,
        // RootView wins when CookModeRoot is gone.
        .fullScreenCover(item: Binding(
            get: { coordinator.activePaywallTrigger },
            set: { if $0 == nil { coordinator.dismissPaywall(wasSuccessful: false) } },
        )) { trigger in
            let vm = coordinator.makePaywallViewModel(trigger: trigger)
            PaywallView(viewModel: vm)
                .onDisappear {
                    coordinator.dismissPaywall(wasSuccessful: vm.didSucceed)
                }
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

    /// Driver selection (C.2 + C.3, ADR 0007):
    ///   killSwitch || !canVoice  → no driver at all (Free path, or
    ///                                server-side kill flipped)
    ///   Premium+ + pre-warm Live  → RealtimeSession (C.2)
    ///   Pre-warm Live failed      → SpeechFallbackService (C.3)
    ///
    /// Called from `.task` at Cook Mode entry AND from the VM's
    /// `onRequestNewVoiceSession` closure when the user reopens voice
    /// after a `closeVoiceSession()` teardown. Same logic either way.
    /// Self is a SwiftUI View struct; writes to `@State self.voiceDriver`
    /// flow through the property wrapper normally.
    @MainActor
    private func buildVoiceDriver(session: CookingSession) async -> (any VoiceSessionDriver)? {
        let killSwitch = entitlements.flagBool(forKey: "disable_cook_realtime") ?? false
        let canVoice = entitlements.canAccess(.voiceCookMode) == .allowed

        if canVoice && !killSwitch {
            do {
                try AVAudioSessionConfigurator.activateForCookMode()
                let liveDriver = RealtimeSession(
                    aiDispatch: aiDispatch,
                    voiceTurnRepository: VoiceTurnRepository(),
                    cookingSession: session,
                )
                try await liveDriver.preWarm()
                self.voiceDriver = liveDriver
                Logger.voice.info("cook_mode_voice_live_ready")
                #if DEBUG
                VoiceSessionLog.log("cookmode.driver_selected", ["path": "live"])
                #endif
                return liveDriver
            } catch {
                // Live failed to pre-warm — fall back to C.3 silently.
                Logger.voice.warning(
                    "cook_mode_voice_live_fallback: \(error.localizedDescription, privacy: .public)",
                )
                #if DEBUG
                VoiceSessionLog.logError("cookmode.live_to_c3_fallback", error: error)
                #endif
                return await tryC3Fallback(session: session)
            }
        } else if canVoice && killSwitch {
            Logger.voice.info("cook_mode_voice_kill_switch_engaged → c3")
            #if DEBUG
            VoiceSessionLog.log("cookmode.driver_selected", ["path": "c3", "reason": "kill_switch"])
            #endif
            return await tryC3Fallback(session: session)
        }
        // Free tier: no driver. VM routes taps to paywall.
        return nil
    }

    /// Wire the driver's side-effect callbacks to the VM. Weak-VM
    /// captures break the driver ↔ VM retain cycle. Safe to call
    /// multiple times — each call replaces the prior closures.
    @MainActor
    private func wireVoiceDriver(_ driver: (any VoiceSessionDriver)?, vm: CookModeViewModel) {
        if let liveDriver = driver as? RealtimeSession {
            liveDriver.onAdvanceStepRequested = { [weak vm] in
                vm?.nextStep(advancedBy: "voice")
            }
            liveDriver.onStartTimerRequested = { [weak vm] seconds, label in
                Task { @MainActor [weak vm] in
                    await vm?.startTimerFromVoice(seconds: seconds, label: label)
                }
            }
            liveDriver.onVoiceStateChange = { [weak vm] state in
                vm?.applyDriverStateChange(state)
            }
        }
        if let fallbackDriver = driver as? SpeechFallbackService {
            fallbackDriver.onVoiceStateChange = { [weak vm] state in
                vm?.applyDriverStateChange(state)
            }
        }
    }

    /// Construct + pre-warm a SpeechFallbackService (C.3). Runs when the
    /// Live path is unavailable (kill switch, preWarm failure). Returns
    /// nil only if AVAudioSession activation itself fails, which is
    /// effectively terminal — the mic button still renders but every
    /// tap will surface the recognizerUnavailable toast path.
    @MainActor
    private func tryC3Fallback(session: CookingSession) async -> (any VoiceSessionDriver)? {
        let driver = SpeechFallbackService(
            aiDispatch: aiDispatch,
            voiceTurnRepository: VoiceTurnRepository(),
            cookingSession: session,
        )
        do {
            try AVAudioSessionConfigurator.activateForCookMode()
            try await driver.preWarm()
            self.voiceDriver = driver
            return driver
        } catch {
            Logger.voice.warning(
                "cook_mode_voice_c3_fallback_prewarm_failed: \(error.localizedDescription, privacy: .public)",
            )
            // Still return the driver — VM routes taps to
            // recognizerUnavailable cleanly rather than crashing on
            // a nil driver unexpectedly.
            self.voiceDriver = driver
            return driver
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
