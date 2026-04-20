// RootCoordinator
//
// Drives the launch sequence described in the step-2 prompt:
//
//   identity resolve
//     ↓
//   supabase bootstrap (with AUTH-01 retry + 5xx backoff baked into the client)
//     ↓
//   entitlement hydrate
//     ↓
//   PostHog identify + app_opened capture
//     ↓
//   decide route (onboarding vs Tonight Home)
//
// Edge cases handled per the prompt's table:
//   - Bootstrap 400 VAL-01 → fatal-for-this-launch error screen
//   - Bootstrap 5xx after backoff exhaustion → fall back to cached snapshot
//     if <24h; else offline-mode flag + free-tier defaults
//   - CloudKit account flip mid-session → re-resolve + update CloudKit store

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class RootCoordinator {
    enum Phase: Sendable, Equatable {
        case loading
        case configurationError(String)
        case onboarding
        case ready
        case offlineFallback  // ran on cached entitlement snapshot
    }

    let config: AppConfig
    let entitlements: EntitlementService
    let cloudKit: CloudKitAvailabilityStore
    let household: CurrentHouseholdStore
    private let sentry: any SentryReporting
    private let identityService: IdentityService
    private(set) var sessionClient: SupabaseSessionClient
    private(set) var aiDispatch: AIDispatch
    let pantryItemRepository: PantryItemRepository
    let solveRepository: SolveRepository
    /// RC SDK facade. Used for logIn (keeping RC's canonical key in sync
    /// with Supabase's) and for the paywall's offerings/purchase flows.
    let revenueCat: any RevenueCatPurchasing
    private let trialReminders: TrialReminderScheduler

    private(set) var phase: Phase = .loading

    /// Provided to OnboardingRoot when phase == .onboarding.
    private(set) var onboardingViewModel: OnboardingViewModel?

    private var accountChangesTask: Task<Void, Never>?

    /// In-flight bootstrap task. Concurrent callers (RootView's `.task { }`
    /// plus a manual retry Task) await the same task instead of kicking off
    /// duplicate launch sequences. Nil once bootstrap finishes.
    private var bootstrapTask: Task<Void, Never>?

    /// Last-known AccountState for emitting `entitlement_state_changed` when
    /// scenePhase-driven refresh picks up a new billing state. Nil until
    /// the first successful bootstrap.
    private var lastEmittedAccountState: AccountState?

    /// Ongoing refresh task for scenePhase .active → configBootstrap. Keeps
    /// concurrent foreground transitions from double-firing.
    private var refreshTask: Task<Void, Never>?

    /// Currently-presented paywall trigger. Set via `presentPaywall(_:)`;
    /// cleared when PaywallView dismisses. SwiftUI `.fullScreenCover(item:)`
    /// drives presentation from this.
    var activePaywallTrigger: PaywallTrigger?

    /// Fresh-cook request signal. Set by DishPreview's "Start Cooking"
    /// button on the Solve flow, cleared when Cook Mode dismisses.
    /// Drives a `.fullScreenCover(item:)` at the TonightHome layer —
    /// NOT nested inside ScanFlowRoot — so Cook Mode doesn't collide
    /// with ScanFlow's own fullScreenCover (iOS queues the second
    /// presentation forever, silently hanging).
    var activeFreshCook: FreshCookRequest?

    /// Identifiable wrapper for `activeFreshCook`. SwiftUI's
    /// `.fullScreenCover(item:)` needs an `Identifiable`, and passing
    /// a `RecipePlan` directly leaks Core Data into the coordinator
    /// surface. Struct-by-UUID keeps the coordinator framework-free.
    struct FreshCookRequest: Identifiable, Equatable {
        let id: UUID
        let recipePlan: RecipePlan
        let household: HouseholdProfile
        init(recipePlan: RecipePlan, household: HouseholdProfile) {
            self.id = UUID()
            self.recipePlan = recipePlan
            self.household = household
        }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    init(
        config: AppConfig,
        entitlements: EntitlementService = EntitlementService(),
        cloudKit: CloudKitAvailabilityStore = CloudKitAvailabilityStore(),
        household: CurrentHouseholdStore = CurrentHouseholdStore(),
        sentry: any SentryReporting = SentryReporter.shared,
        identityService: IdentityService = IdentityService(),
        sessionClient: SupabaseSessionClient? = nil,
        aiDispatch: AIDispatch? = nil,
        pantryItemRepository: PantryItemRepository = PantryItemRepository(),
        solveRepository: SolveRepository = SolveRepository(),
        revenueCat: (any RevenueCatPurchasing)? = nil,
        trialReminders: TrialReminderScheduler = .shared,
    ) {
        self.config = config
        self.entitlements = entitlements
        self.cloudKit = cloudKit
        self.household = household
        self.sentry = sentry
        self.identityService = identityService
        let client = sessionClient ?? SupabaseSessionClient(config: config, sentry: sentry)
        self.sessionClient = client
        self.aiDispatch = aiDispatch ?? AIDispatch(session: client, config: config)
        self.pantryItemRepository = pantryItemRepository
        self.solveRepository = solveRepository
        self.revenueCat = revenueCat ?? RevenueCatService.shared
        self.trialReminders = trialReminders
    }

    /// Runs the full launch sequence. Idempotent — callable from
    /// `.task { }` or an explicit retry button. Concurrent callers share the
    /// same in-flight task so we don't double-bootstrap when retry() fires
    /// alongside RootView's .task modifier.
    func bootstrap() async {
        if let existing = bootstrapTask {
            await existing.value
            return
        }
        let task = Task { await self.runBootstrap() }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func runBootstrap() async {
        Logger.coordinator.info("bootstrap start")
        self.phase = .loading

        // 1. Resolve canonical identity.
        let canonicalKey = await identityService.resolve()
        let installationID = await identityService.installationID()
        cloudKit.update(with: canonicalKey)
        let keyHash = CanonicalKeyHash.hash(canonicalKey)

        // 2. Observability identify (before first capture).
        sentry.breadcrumb(
            category: "launch",
            message: "identity_resolved",
            data: [
                "canonical_key_hash": keyHash,
                "is_cloudkit": canonicalKey.isCloudKit ? "true" : "false",
            ],
        )
        sentry.setUserContext(keyHash: keyHash)
        PostHogClient.shared.identify(distinctID: keyHash)

        // 3. Bootstrap Supabase session. Wrapped in withTimeout so a TCP
        //    partial-response hang at the Edge Function doesn't park the
        //    entire launch sequence indefinitely — URLSession's default
        //    resource timeout is effectively infinite (7 days), which
        //    would leave a hung first launch in .loading forever without
        //    this outer cap. 20s allows for a retry cycle (0.5 + 1.5 + 3s
        //    backoffs + one final attempt) while still bounding the
        //    user's wait before we surface an offline fallback.
        var bootstrapSucceeded = false
        let localSessionClient = sessionClient
        do {
            let response = try await withTimeout(seconds: 20, operation: "sessionBootstrap") {
                try await localSessionClient.bootstrap(
                    installationID: installationID,
                    cloudKitRecordName: canonicalKey.cloudKitRecordName,
                )
            }
            entitlements.hydrate(from: response.entitlements, flags: response.featureFlags)
            bootstrapSucceeded = true
            Logger.coordinator.info(
                "bootstrap ok tier=\(response.entitlements.tier.rawValue, privacy: .public) new=\(response.isNewUser, privacy: .public)",
            )
        } catch StirError.validation(let fieldErrors, let message) {
            Logger.coordinator.error(
                "bootstrap VAL-01: \(message, privacy: .public) fields=\(fieldErrors.count, privacy: .public)",
            )
            sentry.captureError(
                StirError.validation(fieldErrors: fieldErrors, message: message),
                context: ["phase": "bootstrap", "canonical_key_hash": keyHash],
            )
            self.phase = .configurationError(
                "Something went wrong starting the app. Please try again.",
            )
            return
        } catch {
            Logger.coordinator.warning(
                "bootstrap failed: \(error.localizedDescription, privacy: .public)",
            )
            sentry.breadcrumb(
                category: "launch",
                message: "bootstrap_failed",
                data: ["canonical_key_hash": keyHash, "error": String(describing: error)],
            )
            entitlements.markHydrationFailed()
        }

        // 4. Pre-create HouseholdProfile (Round-1 Q4 decision: eager creation
        //    anchored to the resolved canonical_user_key).
        let canonicalKeyString = canonicalKey.stringValue
        do {
            let repo = HouseholdProfileRepository()
            let profile = try repo.ensureHouseholdProfile(for: canonicalKeyString)
            household.set(profile)

            // 5. Emit app_opened now that identity + profile are both resolved.
            let props: [String: Any] = [
                "cold_start": true,
                "build": config.build,
                "os_version": config.osVersion,
                "canonical_user_key_hash": keyHash,
                "is_cloudkit": canonicalKey.isCloudKit,
                "bootstrap_succeeded": bootstrapSucceeded,
            ]
            PostHogClient.shared.capture(.appOpened, properties: props)

            // 6. Route based on onboarding status.
            if profile.onboardingCompleted {
                self.onboardingViewModel = nil
                self.phase = bootstrapSucceeded ? .ready : .offlineFallback
            } else {
                self.onboardingViewModel = OnboardingViewModel(profile: profile)
                PostHogClient.shared.capture(.onboardingStarted, properties: [
                    "canonical_user_key_hash": keyHash,
                    "is_cloudkit": canonicalKey.isCloudKit,
                ])
                self.phase = .onboarding
            }

            Logger.coordinator.info("bootstrap complete phase=\(String(describing: self.phase), privacy: .public)")
        } catch {
            Logger.coordinator.error(
                "core data pre-create failed: \(error.localizedDescription, privacy: .public)",
            )
            sentry.captureError(
                StirError.coreData(underlying: error),
                context: ["phase": "ensure_profile", "canonical_key_hash": keyHash],
            )
            self.phase = .configurationError(
                "Stir couldn't open its local database. Try reinstalling if this persists.",
            )
        }

        // 7. Post-bootstrap entitlement wiring: RC logIn, trial-reminder,
        //    customerInfoStream observation. Runs only on successful
        //    bootstrap — offline fallback skips these because iOS doesn't
        //    know the authoritative billing state yet.
        if bootstrapSucceeded {
            await handlePostBootstrapEntitlement(canonicalKey: canonicalKeyString)
        } else {
            // Offline: still seed lastEmittedAccountState so a subsequent
            // foreground refresh that lands the real state emits a clean
            // transition rather than appearing as a "from=nil" event.
            primeLastEmittedAccountState()
        }

        // 8. Observe CloudKit account changes for the life of the app.
        startAccountChangesObserver()
    }

    /// RC logIn + trial reminder + customerInfoStream observer. Called
    /// once per successful bootstrap. Idempotent under concurrent callers
    /// (RC logIn short-circuits when the key is unchanged; the observer
    /// cancels its prior task before starting a new one).
    private func handlePostBootstrapEntitlement(canonicalKey: String) async {
        // 1. Keep RC's identity in sync with ours. Partial-success risk
        //    called out by the CA2 audit: Supabase bootstrap already
        //    succeeded, so the local entitlement snapshot is authoritative
        //    for this launch. A dropped `Purchases.logIn` call would
        //    leave RC aliased to the previous key (typically the old
        //    install:<uuid>), so future RC webhooks would route to the
        //    wrong canonical_user_key — the exact failure CLAUDE.md
        //    §Aliasing warns about. Retry with bounded backoff.
        await logInWithRetries(canonicalKey: canonicalKey)

        // 2. Seed lastEmittedAccountState without emitting (initial-state
        //    isn't a transition). Subsequent `emitAccountStateChangeIfNeeded`
        //    calls compare against this seed.
        primeLastEmittedAccountState()

        // 3. Trial reminder: schedule when we're in trial; cancel otherwise.
        await updateTrialReminder()

        // 4. Start the customerInfo observer — RC informs us of purchase
        //    events from outside our process (e.g. manage-subscription
        //    flow in Apple ID). Every change triggers a configBootstrap
        //    refresh from our source of truth (Supabase).
        //
        //    Protocol-level `startObserving` so this wiring participates
        //    in tests (mock RC services can optionally observe test
        //    notifications; prod service hooks `Purchases.customerInfoStream`).
        await revenueCat.startObserving { [weak self] in
            Task { @MainActor in
                await self?.refreshEntitlementsOnForeground()
            }
        }
    }

    private func primeLastEmittedAccountState() {
        lastEmittedAccountState = AccountState.derive(
            tier: entitlements.tier,
            billingState: entitlements.billingState,
            cloudKitAvailable: cloudKit.isAvailable,
        )
    }

    /// Compare the current derived AccountState with the last-emitted one
    /// and emit `entitlement_state_changed` iff it changed. Idempotent under
    /// no-op calls; safe to invoke multiple times per refresh.
    private func emitAccountStateChangeIfNeeded() {
        let next = AccountState.derive(
            tier: entitlements.tier,
            billingState: entitlements.billingState,
            cloudKitAvailable: cloudKit.isAvailable,
        )
        guard let previous = lastEmittedAccountState, previous != next else {
            // Either first-run (no previous) or no change — seed + skip.
            lastEmittedAccountState = next
            return
        }
        PostHogClient.shared.capture(
            .entitlementStateChanged,
            properties: BillingTelemetryProperties.entitlementStateChanged(
                fromState: previous,
                toState: next,
                billingState: entitlements.billingState,
            ),
        )
        Logger.coordinator.info(
            "account state \(previous.rawValue, privacy: .public) → \(next.rawValue, privacy: .public)",
        )
        lastEmittedAccountState = next
    }

    private func updateTrialReminder() async {
        if entitlements.billingState == .trial, let expires = entitlements.expiresAt {
            await trialReminders.ensureReminder(expiresAt: expires)
        } else {
            trialReminders.cancel()
        }
    }

    /// Attempt `revenueCat.logIn` with bounded retries so a transient RC
    /// outage doesn't desync identity between Supabase (our source of
    /// truth) and RC (source of entitlement webhooks). Three attempts with
    /// exponential backoff (0.5s, 1.5s) match the SupabaseSessionClient
    /// 5xx retry cadence; a genuinely-down RC will still eventually be
    /// caught by the next app foreground or by `refreshEntitlementsOnForeground`
    /// calling the paywall offerings path, which surfaces PAY-01 visibly.
    ///
    /// Each call is wrapped in a 10s timeout so a hung RC request doesn't
    /// block bootstrap completion. Non-fatal on final exhaustion — the
    /// coordinator continues to `.ready`; the mismatch self-heals on the
    /// next successful launch or on any subsequent `logIn` call.
    private func logInWithRetries(canonicalKey: String) async {
        let maxAttempts = 3
        let rc = self.revenueCat
        for attempt in 0..<maxAttempts {
            do {
                try await withTimeout(seconds: 10, operation: "rc.logIn") {
                    try await rc.logIn(canonicalUserKey: canonicalKey)
                }
                if attempt > 0 {
                    Logger.coordinator.info("RC logIn succeeded on attempt \(attempt + 1, privacy: .public)")
                }
                return
            } catch {
                let remaining = maxAttempts - attempt - 1
                Logger.coordinator.warning(
                    "RC logIn attempt \(attempt + 1, privacy: .public) failed (\(remaining, privacy: .public) remaining): \(error.localizedDescription, privacy: .public)",
                )
                if remaining == 0 { break }
                // Exponential-ish backoff: 0.5s, 1.5s.
                let backoffMs: UInt64 = attempt == 0 ? 500 : 1_500
                try? await Task.sleep(nanoseconds: backoffMs * 1_000_000)
            }
        }
        Logger.coordinator.error(
            "RC logIn exhausted after \(maxAttempts, privacy: .public) attempts — RC alias may be stale until next successful call",
        )
        sentry.breadcrumb(
            category: "launch",
            message: "rc_login_exhausted",
            data: ["canonical_key_hash": CanonicalKeyHash.hash(canonicalKey)],
        )
    }

    // MARK: - Foreground refresh (scenePhase .active)

    /// Called on scenePhase transitions to `.active`. Re-reads entitlements
    /// from Supabase (`configBootstrap` endpoint — doesn't re-mint the JWT)
    /// and emits `entitlement_state_changed` iff the user's account state
    /// moved. Also re-ensures the trial reminder matches the fresh state.
    ///
    /// Concurrent callers share the same in-flight task — foregrounding
    /// twice within a single refresh cycle shouldn't double-fire.
    func refreshEntitlementsOnForeground() async {
        if let existing = refreshTask {
            await existing.value
            return
        }
        let task = Task { await self.runRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func runRefresh() async {
        // 15-second wall-clock cap. URLSession's default resource timeout
        // is effectively infinite (7 days) — without this wrapper, a
        // partial-response hang (server accepted connection, never
        // replies) would park `refreshTask` indefinitely and block every
        // subsequent foreground transition behind the `existing.value`
        // await in `refreshEntitlementsOnForeground`. 15s is well above
        // the p95 for a healthy Supabase round-trip.
        do {
            let sessionClient = self.sessionClient
            let response = try await withTimeout(seconds: 15, operation: "configBootstrap") {
                try await sessionClient.configBootstrap()
            }
            entitlements.hydrate(from: response.entitlements, flags: response.featureFlags)
            emitAccountStateChangeIfNeeded()
            await updateTrialReminder()
            Logger.coordinator.debug(
                "foreground refresh ok tier=\(self.entitlements.tier.rawValue, privacy: .public)",
            )
        } catch StirError.timeout(let op, let seconds) {
            // Timeout is a distinct, expected failure mode — log at
            // warning, don't surface to Sentry. Next foreground retries.
            Logger.coordinator.warning(
                "foreground refresh timed out (\(op, privacy: .public) > \(seconds, privacy: .public)s) — keeping cached snapshot",
            )
        } catch {
            // Non-fatal: keep the cached snapshot. Retry on next
            // foreground cycle. The only time a refresh failure matters
            // is when the user's entitlement actually changed under us;
            // in practice the webhook-driven path catches up within a
            // few seconds.
            Logger.coordinator.warning(
                "foreground refresh failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }

    /// Called by OnboardingRoot when the flow finishes (Setup 2 Continue).
    func handleOnboardingFinished() {
        guard let profile = household.profile else { return }
        let hash = profile.canonicalUserKey.map(CanonicalKeyHash.hash) ?? ""
        PostHogClient.shared.capture(.onboardingCompleted, properties: [
            "canonical_user_key_hash": hash,
        ])
        self.onboardingViewModel = nil
        self.phase = .ready
    }

    /// Retry for the error-screen Retry button.
    func retry() {
        Task { await bootstrap() }
    }

    // MARK: - Paywall presentation

    /// Surface the paywall from any feature gate. Idempotent — calling
    /// with the same trigger twice is a no-op while the paywall is open.
    func presentPaywall(_ trigger: PaywallTrigger) {
        if activePaywallTrigger != nil { return }
        activePaywallTrigger = trigger
    }

    /// Dismissal hook from PaywallView. Resets the trigger AND schedules
    /// a foreground refresh so any successful purchase lands on iOS as
    /// fast as the webhook→Supabase hop allows.
    func dismissPaywall(wasSuccessful: Bool) {
        activePaywallTrigger = nil
        if wasSuccessful {
            Task { await refreshEntitlementsOnForeground() }
        }
    }

    // MARK: - Cook Mode entry (from Solve flow)

    /// Called by DishPreview when the user taps "Start Cooking". The
    /// caller is expected to also dismiss any presenting modal (e.g.
    /// ScanFlowRoot via `@Environment(\.dismiss)`) on the same
    /// runloop tick. SwiftUI will complete that dismiss, then the
    /// `.fullScreenCover(item: $activeFreshCook)` at TonightHome
    /// picks up and presents Cook Mode cleanly — avoiding the
    /// "Currently, only presenting a single sheet is supported"
    /// warning that nested fullScreenCovers trigger.
    func startCookMode(recipePlan: RecipePlan, household: HouseholdProfile) {
        activeFreshCook = FreshCookRequest(recipePlan: recipePlan, household: household)
    }

    /// Dismissal hook from CookModeRoot. Clears the request so the
    /// fullScreenCover drops.
    func dismissCookMode() {
        activeFreshCook = nil
    }

    /// Build a PaywallViewModel bound to this coordinator's RC + entitlement
    /// stack. PaywallView instantiates via this so the VM wiring stays in
    /// one place.
    func makePaywallViewModel(trigger: PaywallTrigger) -> PaywallViewModel {
        PaywallViewModel(
            trigger: trigger,
            service: revenueCat,
            entitlements: entitlements,
            onEntitlementRefreshRequested: { [weak self] in
                Task { @MainActor in await self?.refreshEntitlementsOnForeground() }
            },
        )
    }

    // MARK: - CloudKit change observer

    /// Subscribe to `.CKAccountChanged` and re-run bootstrap whenever the
    /// freshly-resolved identity differs from what CloudKitAvailabilityStore
    /// currently holds. Comparing against the live store (rather than a
    /// captured `initialKey` from the first bootstrap) keeps A→B→A flips
    /// correct: the second A-flip re-resolves because the store is at B.
    private func startAccountChangesObserver() {
        accountChangesTask?.cancel()
        accountChangesTask = Task { [weak self] in
            guard let self else { return }
            for await newKey in self.identityService.observeAccountChanges() {
                if self.cloudKit.lastResolvedKey == newKey { continue }
                Logger.coordinator.info("cloudkit account changed — re-resolving")
                self.cloudKit.update(with: newKey)
                PostHogClient.shared.capture(.syncStateChanged, properties: [
                    "is_cloudkit": newKey.isCloudKit,
                ])
                // Re-run bootstrap so entitlements + profile lineage follow the new key.
                await self.bootstrap()
            }
        }
    }

    // Intentionally no deinit: RootCoordinator lives for the app's full
    // lifetime; capturing accountChangesTask in a nonisolated deinit would
    // require main-actor gymnastics for no runtime benefit.
}
