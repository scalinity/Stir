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
    /// Error shown when Cook Mode setup either times out (15s tripwire
    /// in `.task`) or throws. Split into title + body so the EmptyState
    /// surface renders a proper headline + supporting line instead of
    /// cramming both into one paragraph.
    private struct InitErrorMessage {
        let title: String
        let body: String
    }

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
    /// Teardown closure captured at each driver build. On dismiss the
    /// closure is invoked — which closes WHICHEVER driver was built
    /// most recently. Replaces the prior `@State voiceDriver` pattern
    /// because the @State could desync from what the VM currently
    /// holds after a close-and-rebuild cycle (closeVoiceSession nils
    /// the VM's driver, then `onRequestNewVoiceSession` builds a new
    /// one — the @State pointer didn't automatically track across
    /// that handoff). A closure strongly captures its driver on build
    /// and is guaranteed-correct for whatever build replaced it.
    /// Review finding W-D W18 (CA2).
    @State private var driverTeardown: (@MainActor () -> Void)?
    @State private var initError: InitErrorMessage?

    /// SCA-55: presented after OutcomeFeedback resolves with
    /// `PostSubmitIntent.openLeftovers`. Lifetime is one finish—> one
    /// LeftoversSessionViewModel; nilled on dismiss OR after the user
    /// picks a dish (handoff persists then closes the cover). Identifiable
    /// via the VM's `solveRequestID` UUID — fresh per finish, so two
    /// consecutive cooks in the same Cook Mode session each get their
    /// own cover presentation rather than animating a no-op swap.
    @State private var leftoversSession: LeftoversSessionViewModel?
    /// SCA-66: identity-wrapping the recipePlan UUID so the sheet
    /// modifier (`.sheet(item:)`) has an Identifiable handle.
    /// Premium+ users with rating ≥ 4 on an un-saved recipe receive
    /// the "Save this as a one-tap weeknight meal?" prompt; Free
    /// users see the same card with a paywall-routed "Yes" CTA.
    @State private var repeatCandidateContext: RepeatCandidateContext?
    /// SCA-55 sticky-intent flag for the Free → paywall → Leftovers path.
    /// Set when OutcomeFeedback emits `.openPaywall(.leftoversGate)`;
    /// observed alongside `entitlements.tier` AND `entitlements.billingState`
    /// so a successful purchase auto-opens Leftovers (SCA-56 fix —
    /// observing `tier` alone misses the expired-Premium re-purchase path
    /// where only `billingState` flips, AND the in-`hydrate(from:)` write
    /// ordering race where `tier` writes first while `billingState` is
    /// still stale). Cleared on consume, the safety timeout, or dismiss
    /// without purchase.
    @State private var pendingLeftoversIntent: Bool = false
    /// SCA-56: Cancellable handles for the ad-hoc Tasks the post-submit
    /// handoffs used to fire-and-forget. Storing them lets the success
    /// path (`.onChange` observer consuming `pendingLeftoversIntent`)
    /// cancel the safety timeout, prevents re-entrancy when a user
    /// starts a second cook within the timeout window, and stops orphan
    /// Tasks from surviving CookModeRoot teardown. Both are `MainActor`
    /// Tasks so cancellation is synchronous from the actor.
    ///
    /// SCA-122 rename: `postSubmitPresentationTask` (previously
    /// `leftoversPresentationTask`) is shared across BOTH the SCA-55
    /// leftovers cover-handoff AND the SCA-66 repeat-candidate sheet
    /// paywall handoff (added in SCA-114). The two intents are mutually
    /// exclusive at decision time (postSubmitIntent short-circuits on
    /// leftoverCount>0 before the rating check), so cancellation on
    /// re-arm is benign today. If a future intent overlaps with either
    /// path, give it its own slot — don't add a third caller to this
    /// one.
    @State private var leftoversTimeoutTask: Task<Void, Never>?
    @State private var postSubmitPresentationTask: Task<Void, Never>?

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
                            substitutionRepository: coordinator.substitutionRepository,
                            pantryRepository: coordinator.pantryItemRepository,
                            onDismiss: { viewModel.substitutionPresentationRequested = false },
                        )
                    }
                    .fullScreenCover(isPresented: Binding(
                        get: { viewModel.finishPresentationRequested },
                        set: { viewModel.finishPresentationRequested = $0 },
                    )) {
                        OutcomeFeedbackView(
                            session: viewModel.session,
                            onSubmitted: { intent in
                                handlePostSubmit(intent: intent)
                            },
                            entitlements: entitlements,
                        )
                    }
                    // SCA-55 — Leftovers cover. Presented when OutcomeFeedback
                    // bubbles `.openLeftovers` (Premium+ + leftoverCount>0)
                    // OR when a successful Free→paywall purchase trips the
                    // sticky-intent path. UUID-keyed via the VM's
                    // `solveRequestID` so two consecutive finishes get
                    // distinct presentations.
                    .fullScreenCover(item: $leftoversSession) { vm in
                        LeftoversRoot(
                            viewModel: vm,
                            onSelect: { dish in
                                handleLeftoverDishSelected(dish, vm: vm)
                            },
                            onDismiss: {
                                leftoversSession = nil
                                onDismiss()
                            },
                        )
                    }
                    // SCA-66 — repeat-candidate save card. Sheet (not
                    // fullScreenCover) so the user keeps context on the
                    // underlying surface; medium presentationDetent
                    // applied inside the card view itself.
                    .sheet(
                        item: $repeatCandidateContext,
                        // SCA-116: route the parent CookMode dismiss
                        // through the .sheet onDismiss parameter so
                        // EVERY dismissal path closes Cook Mode —
                        // button taps AND swipe-down-to-dismiss.
                        // Pre-fix the close lived only in the card's
                        // onDismiss closure, which `.sheet(item:)`
                        // does NOT invoke on swipe-down (the binding
                        // setter nils the item directly without
                        // running the closure body). Result: card
                        // disappeared but Cook Mode stayed open
                        // underneath, trapping the user.
                        onDismiss: {
                            onDismiss()
                        },
                    ) { ctx in
                        RepeatCandidateCard(
                            recipePlan: recipePlan,
                            entitlements: entitlements,
                            // SCA-114: wrap the paywall handoff in a
                            // cancellable Task using the existing
                            // presentation-task slot (mirrors the
                            // SCA-56 leftovers pattern). Pre-fix the
                            // card itself used DispatchQueue.main.
                            // asyncAfter — uncancellable, magic 0.05,
                            // and racy on view teardown / double-tap.
                            // The 50ms gap is the cover-handoff
                            // standard from SCA-56 documented at
                            // `Self.coverHandoffGap`.
                            presentPaywall: { trigger in
                                cancelPostSubmitPresentationTask()
                                postSubmitPresentationTask = Task { @MainActor in
                                    try? await Task.sleep(for: Self.coverHandoffGap)
                                    guard !Task.isCancelled else { return }
                                    coordinator.presentPaywall(trigger)
                                }
                            },
                            // SCA-116: card-action close path nils the
                            // binding only. The parent CookMode dismiss
                            // runs from the .sheet `onDismiss:` above,
                            // so both swipe-down and explicit button
                            // taps converge on the same close. Avoids
                            // double-firing onDismiss() when the
                            // binding-set + closure-call both run.
                            onDismiss: {
                                repeatCandidateContext = nil
                            },
                        )
                        .id(ctx.id)  // force fresh view per recipe
                    }
                    // Sticky-intent observation for the Free→paywall
                    // success path (SCA-55 D5/D6). When the user purchases
                    // through the leftovers-gate paywall, RootCoordinator's
                    // dismissPaywall(wasSuccessful:) fires
                    // refreshEntitlementsOnForeground() — once the refresh
                    // lands, present LeftoversRoot.
                    //
                    // SCA-56: observe BOTH `tier` AND `billingState`, not
                    // just `tier`. Two real scenarios were silently broken
                    // by the single-dimension observer: (1) expired-Premium
                    // re-purchase only flips billingState (.expired→.active);
                    // tier stays .premium, observer never fires. (2)
                    // EntitlementService.hydrate writes tier then billingState
                    // sequentially — observer firing on the tier write reads
                    // stale .blockedByTier from canAccess (which routes
                    // through effectiveTier) and bails before billingState
                    // catches up. canAccess re-derives from both dimensions,
                    // so two observers that call the same checker covers
                    // every settle path.
                    .onChange(of: entitlements.tier) { _, _ in
                        consumePendingLeftoversIntentIfReady()
                    }
                    .onChange(of: entitlements.billingState) { _, _ in
                        consumePendingLeftoversIntentIfReady()
                    }
                    // SCA-56: cancel any in-flight post-submit Tasks if
                    // CookModeRoot leaves the tree (parent rebuild, app
                    // background-kill recovery). Without this, the
                    // fire-and-forget timeout/presentation Tasks survive
                    // the View teardown and write to a detached @State.
                    // Covers both the SCA-55 leftovers handoff and the
                    // SCA-66 / SCA-114 repeat-candidate paywall handoff.
                    .onDisappear {
                        leftoversTimeoutTask?.cancel()
                        leftoversTimeoutTask = nil
                        postSubmitPresentationTask?.cancel()
                        postSubmitPresentationTask = nil
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
                    // SCA-71: surface the post-paywall sticky-intent
                    // wait so users who just bought Premium see
                    // something happening while the RevenueCat webhook
                    // → Supabase bootstrap → tier-flip round-trip
                    // settles. Only renders when the paywall has
                    // dismissed (otherwise the cover hides this view
                    // anyway) AND we're still waiting on the
                    // entitlement refresh. Cleared by the same
                    // observers that consume `pendingLeftoversIntent`.
                    .overlay(alignment: .top) {
                        if pendingLeftoversIntent
                            && coordinator.activePaywallTrigger == nil
                        {
                            ActivatingPremiumBanner()
                                .padding(.top, 60)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: pendingLeftoversIntent)
            } else if let initError {
                VStack(spacing: 0) {
                    EmptyState(
                        icon: Image.Stir.softError,
                        title: initError.title,
                        message: initError.body,
                    )
                    SecondaryButton(title: "Close") {
                        onDismiss()
                    }
                    .padding(.horizontal, CGFloat.Stir.space4)
                    .padding(.bottom, CGFloat.Stir.space5)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.Stir.paper50.ignoresSafeArea())
            } else {
                ProgressView("Getting Cook Mode ready…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.Stir.paper50.ignoresSafeArea())
            }
        }
        .task {
            guard viewModel == nil, initError == nil else { return }

            // Surface an initError affordance after 15s if setup
            // hasn't produced a VM — users whose network has stalled
            // on the Gemini Live mint, or whose Core Data createSession
            // is blocked on sync, shouldn't be stuck on a ProgressView
            // with no Close button. If setup ultimately succeeds after
            // the 15s tripwire, `viewModel` flips non-nil and the init-
            // error branch is hidden again (UI prefers viewModel if
            // both are set). Review finding W-D W19 (CA2).
            let timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                if self.viewModel == nil, self.initError == nil {
                    self.initError = InitErrorMessage(
                        title: "Cook Mode is taking longer than expected",
                        body: "Check your connection and try again.",
                    )
                    Logger.ui.warning("cook_mode_init_timeout_15s")
                }
            }
            defer { timeoutTask.cancel() }

            do {
                let repo = coordinator.cookingSessionRepository
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
                    cookingSessionRepository: coordinator.cookingSessionRepository,
                    cookTimerRepository: coordinator.cookTimerRepository,
                    substitutionRepository: coordinator.substitutionRepository,
                    pantryItemRepository: coordinator.pantryItemRepository,
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
                    // P1-K (2026-04-23): if a post-commit refresh failure
                    // earlier in this Cook Mode entry pinned fallback,
                    // skip Live and go straight to C.3. See
                    // `CookModeViewModel.pinFallbackForCookSession`.
                    let forceFallback = vm.pinFallbackForCookSession
                    let newDriver = await self.buildVoiceDriver(
                        session: session,
                        forceFallback: forceFallback,
                    )
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
                initError = InitErrorMessage(
                    title: "Couldn't start Cook Mode",
                    body: "Please try again.",
                )
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
            // reason — the most-recently-built driver still needs
            // close(). Both calls are idempotent (close() has internal
            // guards; deactivate() uses an isActiveForCookMode flag),
            // so a second invocation after VM exit is a safe no-op.
            // The teardown closure is captured at driver-build time,
            // so rebuilds swap it atomically and there's no stale-@
            // State race. Review finding W-D W18 (CA2).
            driverTeardown?()
            AVAudioSessionConfigurator.deactivate()
            // Same defense-in-depth principle for Live Activities:
            // exit/finish end them through targeted cancellation, but a
            // dismissal path that bypasses both (programmatic
            // `coordinator.dismissCookMode`, parent rebuilding the
            // cover) would orphan the Lock Screen surface — leaving it
            // ticking past 00:00 for hours. Idempotent — the VM's
            // exit/finish paths empty the manager's dict before
            // shouldDismiss flips, so this is a no-op on the happy path.
            if let viewModel {
                Task { await viewModel.teardownLiveActivitiesOnDismiss() }
            }
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

    // MARK: - SCA-55 Leftovers handoff

    /// 50ms post-submit handoff gap. SwiftUI's `.fullScreenCover` AND
    /// `.sheet` dismiss animations run ~0.35s; the `isPresented` flip
    /// is synchronous but queueing a second presentation bind in the
    /// same tick can swallow it on iOS 17/18. 50ms is empirically
    /// large enough to let the dismiss animation start while staying
    /// well under the user-perceptible window. Used by:
    ///   - SCA-55 leftovers branch (OutcomeFeedback → LeftoversRoot,
    ///     both fullScreenCovers on CookModeRoot)
    ///   - SCA-55 paywall branch (OutcomeFeedback on CookModeRoot →
    ///     PaywallView at RootView)
    ///   - SCA-66/SCA-114 repeat-candidate paywall handoff (sheet on
    ///     CookModeRoot → PaywallView at RootView, sheet-after-sheet)
    /// All three need the gap because
    /// the OutcomeFeedback dismiss runs the same animation regardless
    /// of where the next cover is bound.
    private static let coverHandoffGap: Duration = .milliseconds(50)
    /// Sticky-intent safety timeout. If RevenueCat's webhook → Supabase
    /// bootstrap → entitlement-refresh round-trip stalls past this
    /// window, drop the sticky intent and close Cook Mode normally on
    /// the paywall's own dismiss. Sized larger than the typical webhook
    /// SLA (~1-3s) to absorb APNS-push backpressure.
    private static let stickyIntentTimeout: Duration = .seconds(15)

    /// Route OutcomeFeedback's PostSubmitIntent. The OutcomeFeedback cover
    /// is dismissed in every branch so iOS isn't asked to stack two
    /// fullScreenCovers (LeftoversRoot or PaywallView would otherwise be
    /// queued silently behind the still-presenting OutcomeFeedback).
    @MainActor
    private func handlePostSubmit(intent: OutcomeFeedbackView.PostSubmitIntent) {
        guard let viewModel else {
            // Defensive: no VM means submit() shouldn't have run, but if
            // it did, fall back to the dismiss path so the cover doesn't
            // strand the user.
            onDismiss()
            return
        }
        viewModel.finishPresentationRequested = false

        switch intent {
        case .dismiss:
            onDismiss()

        case .openLeftovers:
            // SCA-57: cooking is finished — release the Live voice
            // driver / WS / AVAudioSession now rather than waiting for
            // CookModeRoot.onDisappear (which runs after the user
            // finishes the leftovers prompt 60-180s later). The 30-min
            // hard session cap (LiveSessionLimits.maxSessionDurationSec)
            // ticks the whole time otherwise. driverTeardown?() on
            // .onDisappear stays as defense-in-depth — the underlying
            // close is idempotent.
            Task { @MainActor in
                await viewModel.closeVoiceSessionFromHost()
            }
            cancelPostSubmitPresentationTask()
            postSubmitPresentationTask = Task { @MainActor in
                try? await Task.sleep(for: Self.coverHandoffGap)
                guard !Task.isCancelled else { return }
                presentLeftovers()
            }

        case .suggestSave(let recipePlanId):
            // SCA-66: rating ≥ 4 on un-saved recipe — surface the save
            // prompt as a sheet. 50ms gap mirrors the leftovers handoff
            // pattern so iOS doesn't try to stack two presentations.
            cancelPostSubmitPresentationTask()
            postSubmitPresentationTask = Task { @MainActor in
                try? await Task.sleep(for: Self.coverHandoffGap)
                guard !Task.isCancelled else { return }
                repeatCandidateContext = RepeatCandidateContext(id: recipePlanId)
            }

        case .openPaywall(let trigger):
            // SCA-57: same rationale as .openLeftovers — user is done
            // cooking; close voice early.
            Task { @MainActor in
                await viewModel.closeVoiceSessionFromHost()
            }
            // Re-arm: cancel any prior in-flight timer/presentation
            // Tasks before stamping new ones. Without this, two cooks
            // in a single Cook Mode session stack overlapping timers
            // and the older one can race in and clear the newer
            // sticky intent (DB1 #3 / DB2 #1 / CA1 #1).
            cancelLeftoversTimeoutTask()
            cancelPostSubmitPresentationTask()
            pendingLeftoversIntent = true
            leftoversTimeoutTask = Task { @MainActor in
                try? await Task.sleep(for: Self.stickyIntentTimeout)
                guard !Task.isCancelled, pendingLeftoversIntent else { return }
                pendingLeftoversIntent = false
            }
            postSubmitPresentationTask = Task { @MainActor in
                try? await Task.sleep(for: Self.coverHandoffGap)
                guard !Task.isCancelled else { return }
                coordinator.presentPaywall(trigger)
            }
        }
    }

    /// Single transition for the post-purchase sticky-intent path.
    /// Called from BOTH the `.onChange(of: tier)` and
    /// `.onChange(of: billingState)` observers — re-derives via
    /// `canAccess(.leftoversMode)` so any settle order produces a
    /// correct decision. No-op when there's nothing pending or the
    /// user isn't yet entitled.
    @MainActor
    private func consumePendingLeftoversIntentIfReady() {
        guard pendingLeftoversIntent,
              entitlements.canAccess(.leftoversMode) == .allowed,
              leftoversSession == nil
        else { return }
        cancelLeftoversTimeoutTask()
        pendingLeftoversIntent = false
        presentLeftovers()
    }

    @MainActor
    private func cancelLeftoversTimeoutTask() {
        leftoversTimeoutTask?.cancel()
        leftoversTimeoutTask = nil
    }

    @MainActor
    private func cancelPostSubmitPresentationTask() {
        postSubmitPresentationTask?.cancel()
        postSubmitPresentationTask = nil
    }

    /// Build a fresh `LeftoversSessionViewModel` and bind it to
    /// `leftoversSession` so the SwiftUI `.fullScreenCover(item:)` picks
    /// it up. Single source of truth so both the direct Premium path
    /// (handlePostSubmit → .openLeftovers) and the sticky-intent path
    /// (post-purchase consume) construct the VM identically.
    @MainActor
    private func presentLeftovers() {
        // SCA-56: dropped `[weak coordinator]` capture — coordinator is
        // an app-singleton injected via @Environment, outlives every
        // view, and the strong cycle [weak] would prevent (VM →
        // closure → coordinator → … → VM) doesn't exist because
        // coordinator never holds the VM.
        leftoversSession = LeftoversSessionViewModel(
            recipePlan: recipePlan,
            household: household,
            aiDispatch: aiDispatch,
            entitlements: entitlements,
            presentPaywall: { trigger in
                // SCA-105: belt-and-suspenders presenting-context check.
                // findFollowUpIdea's gate runs sync at the top of an async
                // function, but the call site (LeftoversSolveView's
                // "Find idea" CTA) is reachable only while Cook Mode's
                // cover sequence is alive. If the cover is already
                // unwinding (user backgrounds, slow-device race), gating
                // on activeCookLaunch ensures the paywall doesn't fire
                // onto TonightHome with no Cook Mode context. No-op in
                // the happy path.
                guard coordinator.activeCookLaunch != nil else {
                    // Review W4: log the suppression so the rate is
                    // observable. If this fires regularly in production,
                    // the underlying race needs a different fix
                    // (e.g. gate-trip earlier in findFollowUpIdea
                    // before the async hop, or a VM-local isDismissing
                    // flag). >1% of leftovers gates = revisit.
                    Logger.coordinator.info(
                        "leftovers_paywall_suppressed: trigger=\(trigger.telemetryValue, privacy: .public) reason=cover_unwinding",
                    )
                    return
                }
                coordinator.presentPaywall(trigger)
            },
        )
    }

    /// LeftoversRoot.onSelect handler. Persist the picked dish via the
    /// dedicated `createLeftoversSolveWithDish` path (single dish, no
    /// pantry, sourced from `recipePlan`), emit `leftovers_dish_selected`
    /// telemetry, then drop both covers. The new RecipePlan becomes the
    /// latest completed solve so TonightHome's `latestTonightPick` will
    /// surface it as the next hero card automatically — matches the
    /// LeftoversSolveView helper text "adds it to tomorrow's Tonight."
    @MainActor
    private func handleLeftoverDishSelected(
        _ dish: DishCard,
        vm: LeftoversSessionViewModel,
    ) {
        // SCA-106: persistence is now async because the save runs on a
        // background NSManagedObjectContext. Wrap the whole branch in a
        // @MainActor Task so failures still route through the existing
        // VM error surface, and so the cover-handoff dismiss sequence
        // remains in @MainActor scope.
        Task { @MainActor in
            do {
                let outcome = try await coordinator.solveRepository.createLeftoversSolveWithDish(
                    on: household,
                    from: recipePlan,
                    dish: dish,
                    aiRequestId: nil,
                    promptVersion: vm.lastPromptVersion,
                )
                PostHogClient.shared.capture(
                    .leftoversDishSelected,
                    properties: [
                        "rank": dish.rank,
                        // Snapshot taken at solve-start in
                        // LeftoversSessionViewModel — defends against the
                        // user toggling items off after the dishes render
                        // but before tapping a card (DB1 #11).
                        "leftovers_items_count": vm.selectedItemsCountAtSolve,
                        "prompt_version": vm.lastPromptVersion ?? "unknown",
                        // "unknown" placeholder beats "" so PostHog
                        // dashboards that filter by ID don't silently
                        // drop these events (DB1 #7).
                        "source_recipe_plan_id": recipePlan.id?.uuidString ?? "unknown",
                        "new_recipe_plan_id": outcome.recipePlan.id?.uuidString ?? "unknown",
                        // SCA-106: background-context save latency in ms.
                        // Dashboard signal: p95(persist_ms) > 50 OR a sudden
                        // jump in the long tail = revisit the bg-context
                        // path or split into a coarser batch.
                        "persist_ms": outcome.persistMs,
                    ],
                )
                // SCA-75: dismiss the LeftoversRoot cover first, then —
                // after the cover-handoff gap — dismiss CookModeRoot. Both
                // covers used to drop in the same synchronous tick; iOS
                // sometimes swallowed the second dismiss-animation when
                // they overlapped. Mirrors the present-direction gap.
                leftoversSession = nil
                try? await Task.sleep(for: Self.coverHandoffGap)
                onDismiss()
            } catch {
                // SCA-56 (W1): persistence failed — DON'T silently dismiss
                // as if success. Keep the LeftoversRoot cover up and
                // transition the VM to its `.error` stage so the existing
                // ErrorView surface (LeftoversSolveView) renders an
                // actionable message. The `meal_rated` properties emitted
                // upstream still record the offer; the per-dish
                // `leftovers_dish_selected` is correctly suppressed because
                // no plan was created.
                Logger.coreData.error(
                    "createLeftoversSolveWithDish failed: \(error.localizedDescription, privacy: .public)",
                )
                SentryReporter.shared.captureError(
                    error,
                    context: [
                        "screen": "leftovers_handoff",
                        "source_recipe_plan_id": recipePlan.id?.uuidString ?? "unknown",
                        "error_type": String(describing: type(of: error)),
                    ],
                )
                vm.markPersistenceFailed(
                    code: "AI-02",
                    // SCA-73: copy adjusted now that ErrorView surfaces a
                    // Retry button — "try a different one" was prescriptive
                    // and steered users away from the simpler retry path.
                    message: "Couldn't save that idea. Tap Try again, or pick a different one.",
                    dish: dish,
                )
            }
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
    /// Self is a SwiftUI View struct; writes to `@State self.driverTeardown`
    /// flow through the property wrapper normally. The teardown closure
    /// strongly captures the built driver so dismiss always tears down
    /// whichever driver was most recently assembled.
    @MainActor
    private func buildVoiceDriver(
        session: CookingSession,
        forceFallback: Bool = false,
    ) async -> (any VoiceSessionDriver)? {
        let killSwitch = entitlements.flagBool(forKey: "disable_cook_realtime") ?? false
        let canVoice = entitlements.canAccess(.voiceCookMode) == .allowed

        // P1-K (2026-04-23): caller pinned fallback (post-commit refresh
        // failure handoff). Skip Live preWarm entirely and route to C.3.
        // Saves ~2 s of handshake latency the user would otherwise
        // perceive on every subsequent tap before landing in C.3 anyway.
        if forceFallback {
            Logger.voice.info("cook_mode_voice_force_fallback → c3")
            #if DEBUG
            VoiceSessionLog.log("cookmode.driver_selected", ["path": "c3", "reason": "force_fallback"])
            #endif
            return await tryC3Fallback(session: session)
        }

        if canVoice && !killSwitch {
            do {
                try AVAudioSessionConfigurator.activateForCookMode()
                let liveDriver = RealtimeSession(
                    aiDispatch: aiDispatch,
                    voiceTurnRepository: coordinator.voiceTurnRepository,
                    cookingSession: session,
                )
                try await liveDriver.preWarm()
                // If the Task was cancelled during preWarm (user swiped
                // down on the Cook Mode sheet, or parent re-rendered),
                // don't leak the partially-wired driver into @State.
                // Close it immediately so WS / audio / notification
                // bookkeeping unwinds; return nil so the caller skips
                // VM construction. Review 2026-04-22 §Warning #3.
                if Task.isCancelled {
                    liveDriver.close()
                    return nil
                }
                self.driverTeardown = { [liveDriver] in liveDriver.close() }
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
                if Task.isCancelled { return nil }
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
            liveDriver.onGoToStepRequested = { [weak vm] step1Indexed in
                // Tool passes 1-indexed step number (matches what the
                // user says and what the model speaks). VM's jumpToStep
                // uses 0-indexed internally.
                vm?.jumpToStep(step1Indexed - 1, advancedBy: "voice")
            }
            liveDriver.onStartTimerRequested = { [weak vm] seconds, label in
                // Await the real timer creation + notification schedule
                // so the tool response reflects the on-screen CookTimer
                // state (NOT an LLM guess). `startTimerFromVoice` writes
                // to Core Data + calls `timerService.start` which is
                // what drives the countdown the user sees.
                guard let vm else {
                    return CookModeViewModel.VoiceTimerSnapshot(
                        state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
                    )
                }
                await vm.startTimerFromVoice(seconds: seconds, label: label)
                return vm.currentStepTimerSnapshot()
            }
            // Voice timer control. Closures return the post-action
            // snapshot so the tool response carries accurate state
            // back to the model for narration.
            liveDriver.onTimerQueryRequested = { [weak vm] in
                vm?.currentStepTimerSnapshot()
                    ?? CookModeViewModel.VoiceTimerSnapshot(
                        state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
                    )
            }
            liveDriver.onTimerPauseRequested = { [weak vm] in
                await vm?.pauseCurrentTimerFromVoice()
                    ?? CookModeViewModel.VoiceTimerSnapshot(
                        state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
                    )
            }
            liveDriver.onTimerResumeRequested = { [weak vm] in
                await vm?.resumeCurrentTimerFromVoice()
                    ?? CookModeViewModel.VoiceTimerSnapshot(
                        state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
                    )
            }
            liveDriver.onTimerCancelRequested = { [weak vm] in
                await vm?.cancelCurrentTimerFromVoice()
                    ?? CookModeViewModel.VoiceTimerSnapshot(
                        state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
                    )
            }
            liveDriver.onTimerRestartRequested = { [weak vm] seconds, label in
                await vm?.restartCurrentTimerFromVoice(seconds: seconds, label: label)
                    ?? CookModeViewModel.VoiceTimerSnapshot(
                        state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
                    )
            }
            liveDriver.onVoiceStateChange = { [weak vm] state in
                vm?.applyDriverStateChange(state)
            }
            liveDriver.onTurnFinalized = { [weak vm] summary in
                vm?.recordLiveTurnSummary(summary)
            }
            liveDriver.onTurnTranscriptFinalized = { [weak vm] snapshot in
                vm?.recordTurnTranscript(snapshot)
            }
            liveDriver.onVoiceSessionRefreshResolved = { [weak vm] reason, turns, sessionID, success in
                vm?.recordVoiceSessionRefresh(
                    reason: reason,
                    turnsAtRefresh: turns,
                    sessionID: sessionID,
                    success: success,
                )
            }
            // P1-K (2026-04-23): pin C.3 fallback for the rest of this
            // Cook Mode entry when a post-commit refresh failure lands.
            // Fresh Live preWarm after the same class of failure tends
            // to repeat; pinning saves ~2 s of handshake ping-pong the
            // user would perceive on every subsequent tap.
            liveDriver.onVoiceFallbackRequired = { [weak vm] reason in
                vm?.setPinFallbackForCookSession(reason: reason)
            }
            liveDriver.onSubstitutionRequestedFromVoice = { [weak vm] subEventID in
                vm?.emitVoiceSubstitutionRequested(subEventID: subEventID)
            }
            liveDriver.onSubstitutionResolvedFromVoice = { [weak vm] constraintSafe, subEventID in
                vm?.emitVoiceSubstitutionResolved(
                    constraintSafe: constraintSafe,
                    subEventID: subEventID,
                )
            }
            liveDriver.onSubstitutionAppliedFromVoice = { [weak vm] subEventID, missing, text, conversion in
                vm?.applyVoiceSubstitution(
                    subEventID: subEventID,
                    missingIngredient: missing,
                    substitutionText: text,
                    amountConversion: conversion,
                )
            }
            liveDriver.onVoiceTurnStuckWatchdogFired = {
                [weak vm] (sessionID: String, turnIndex: Int, toolCallType: String?, elapsedStuckMs: Int, turnLengthAtStuck: Int) in
                vm?.recordVoiceTurnStuckWatchdogFired(
                    sessionID: sessionID,
                    turnIndex: turnIndex,
                    toolCallType: toolCallType,
                    elapsedStuckMs: elapsedStuckMs,
                    turnLengthAtStuck: turnLengthAtStuck,
                )
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
            voiceTurnRepository: coordinator.voiceTurnRepository,
            cookingSession: session,
        )
        do {
            try AVAudioSessionConfigurator.activateForCookMode()
            try await driver.preWarm()
            self.driverTeardown = { [driver] in driver.close() }
            return driver
        } catch {
            Logger.voice.warning(
                "cook_mode_voice_c3_fallback_prewarm_failed: \(error.localizedDescription, privacy: .public)",
            )
            // Still return the driver — VM routes taps to
            // recognizerUnavailable cleanly rather than crashing on
            // a nil driver unexpectedly.
            self.driverTeardown = { [driver] in driver.close() }
            return driver
        }
    }
}

// MARK: - SCA-71 sticky-intent banner

/// Top-of-screen banner shown after a successful leftovers-gate
/// purchase, while the RevenueCat → Supabase bootstrap → tier-flip
/// round-trip settles. Replaces the prior silent wait between paywall
/// dismiss and LeftoversRoot presentation. Non-tappable — the underlying
/// state-machine clears itself on tier flip or the 15s safety timeout.
private struct ActivatingPremiumBanner: View {
    var body: some View {
        HStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.Stir.ember600)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Activating Premium…")
                    .stirFont(.labelMd)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.ink900)
                Text("Opening your leftovers ideas next.")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }
            Spacer(minLength: CGFloat.Stir.space2)
        }
        .padding(.horizontal, CGFloat.Stir.space4)
        .padding(.vertical, CGFloat.Stir.space3 - 2) // 10pt
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                .fill(Color.Stir.paper100)
                .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 2),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                .strokeBorder(Color.Stir.ember600.opacity(0.25), lineWidth: 1),
        )
        .padding(.horizontal, CGFloat.Stir.screenMargin)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Activating Premium. Opening your leftovers ideas next.")
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
        HStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.Stir.amber600)
                .accessibilityHidden(true)
            Text(message)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink900)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: CGFloat.Stir.space2)
            Button {
                onDismiss()
            } label: {
                Image.Stir.close
                    .foregroundStyle(Color.Stir.ink500)
                    .padding(CGFloat.Stir.space2)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, CGFloat.Stir.space4)
        .padding(.vertical, CGFloat.Stir.space3 - 2) // 10pt
        // FD1-2 fix: tokenized surface — paper100 + Stir radiusMd matches
        // the rest of the app's toasts (Tonight uses an ink900 capsule
        // for its variant; this card-shape variant uses paper100). Spec
        // §3.3 forbids translucency on text containers.
        .background(
            Color.Stir.paper100,
            in: RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous),
        )
        .padding(.horizontal, CGFloat.Stir.space4)
    }
}
