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

    /// Tab key for the post-launch shell. Drives `StirTabRoot`'s
    /// selection binding so deep-links and intra-tab nav (e.g. the
    /// Tonight bookmark button → Saved) write through one observable
    /// surface rather than wiring private @State up through the view
    /// tree.
    enum Tab: String, Sendable, Hashable {
        case tonight
        case saved
        case settings
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
    /// Cooking-session repo, brokered through the coordinator so Tonight
    /// + Cook Mode read through the same plumbing. CR1-W4 fix: previously
    /// `TonightHomeView.refreshState()` instantiated its own
    /// `CookingSessionRepository()` per refresh — asymmetric with every
    /// other read on the screen and not stub-able from tests.
    let cookingSessionRepository: CookingSessionRepository
    /// HouseholdProfile accessor — owns existence checks at fast-path init
    /// and creation in the full-bootstrap path. Injected so tests can stub
    /// the on-disk profile state without touching Core Data directly.
    private let householdRepo: HouseholdProfileRepository
    /// App Group key/value access. Injected so tests can drive the warm-
    /// launch fast-path decision via a deterministic stub instead of the
    /// real container, and so reads/writes go through one instance per
    /// coordinator (rather than constructing a fresh struct per call site).
    private let sharedStorage: SharedStorage
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

    /// Set by `attemptFastPathLaunch()` when warm-launch inputs were all
    /// present (cached entitlement snapshot, previously-resolved canonical
    /// key in App Group, onboarded HouseholdProfile for that key). Drives
    /// `bootstrap()` into validate-only mode — UI runs on cached state,
    /// the bootstrap call hydrates fresher data underneath. The minimum
    /// LoadingView duration that goes with this mode is a separate concern
    /// (`fastPathMinLoadingDuration`, enforced by a Task in
    /// `attemptFastPathLaunch` directly, not via reads of this flag).
    /// One-shot: cleared the moment `bootstrap()` reads it, so a manual
    /// `retry()` after a failed validate runs the full launch sequence.
    private var isFastPathLaunch = false

    /// Minimum duration the wordmark LoadingView is shown on a fast-path
    /// launch before the timer flips phase to `.ready`. Below this floor
    /// the wordmark would flash for one frame (or not at all on a hot
    /// device), eroding the brand moment for the returning-user cohort.
    /// Default 500ms is well under the worst-case full-bootstrap window
    /// (500–2500ms) so the perceived launch is still noticeably faster
    /// on slow networks.
    ///
    /// Injected at init for tests — pass `.zero` to remove the floor and
    /// observe the timer logic without the wall-clock wait.
    private let fastPathMinLoadingDuration: Duration

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

    /// "Pro comparison" sheet signal — drives a `.sheet(item:)` mounted
    /// on `SettingsRootView` (NOT RootView) that mounts
    /// `ProComparisonSheet` directly (Premium-vs-Pro side-by-side, Pro
    /// CTAs only). Distinct from `activePaywallTrigger` (which presents
    /// the full Premium-anchored PaywallView via `.fullScreenCover(item:)`).
    /// Keeping these two surfaces on separate coordinator slots means
    /// the app retains its single-presenter invariant — opening one
    /// while the other is up is a no-op rather than a silently-dropped
    /// second presentation ("Currently, only presenting a single sheet
    /// is supported"). UUID-keyed so two rapid taps produce distinct
    /// entries (matches SolveAgain/OtherOptions pattern).
    ///
    /// Sheet binding lives on `SettingsRootView` rather than `RootView`
    /// because Settings is the only origin of pro-comparison
    /// presentation, AND stacking a `.sheet(item:)` adjacent to
    /// RootView's paywall `.fullScreenCover(item:)` caused an iOS 26
    /// modifier-stack conflict on voice-quota taps from inside Cook Mode
    /// — see `CookModeRoot.swift:287`'s mirrored paywall fullScreenCover.
    /// Both Cook Mode VC and RootView VC race to present the paywall on
    /// `activePaywallTrigger` flips; the third presentation modifier on
    /// RootView destabilized the reconciliation enough that Cook Mode
    /// would tear down mid-presentation, dropping the user on Tonight.
    var activeProComparison: ProComparisonEntry?

    /// Identifiable wrapper for the pro-comparison sheet. Carries the
    /// `PaywallTrigger` so `paywall_viewed` telemetry distinguishes the
    /// two entry points (Free→Pro discovery vs Premium→Pro upgrade)
    /// once their triggers diverge upstream.
    struct ProComparisonEntry: Identifiable, Equatable {
        let id: UUID
        let trigger: PaywallTrigger
    }

    /// Currently-selected tab in `StirTabRoot`. Defaults to Tonight on
    /// every fresh launch — a returning user lands on the most-seen
    /// surface, not whichever tab they last poked at. Mutated from
    /// the Tonight bookmark jump-button (→ `.saved`) and from any
    /// future deep-link routes that target a specific tab.
    var selectedTab: Tab = .tonight

    /// Unified Cook Mode launch signal. Drives a SINGLE
    /// `.fullScreenCover(item:)` at TonightHome covering every path
    /// into Cook Mode (fresh from Solve, resume from banner, cook-
    /// again from recents). Multiple concurrent fullScreenCover
    /// modifiers on the same view — even with at-most-one item set —
    /// provoke iOS 18/26's "Currently, only presenting a single
    /// sheet is supported" warning and queue the later-arriving
    /// presentation silently. One cover modifier keeps presentations
    /// predictable.
    var activeCookLaunch: CookModeLaunch?

    /// "Solve again" launch signal. Drives a `.fullScreenCover(item:)`
    /// at TonightHome that mounts a `SolveAgainRoot` — the constraints
    /// sheet → DinnerOptionsView → DishPreviewView flow, skipping
    /// scan/review and re-using the latest pantry snapshot. UUID-keyed
    /// (not Bool) so two rapid taps produce two distinct signals and
    /// each presentation is honored.
    var activeSolveAgain: SolveAgainEntry?

    /// Identifiable wrapper for the solve-again cover. Carries the
    /// pre-prepared ingredients to seed `SolveViewModel` plus a fresh
    /// UUID per launch so SwiftUI's Identifiable diff re-presents
    /// cleanly on consecutive taps. `Equatable` is synthesized —
    /// `DinnerSolveRequest.IngredientLite` itself conforms to
    /// `Equatable`, so manual `lhs.id == rhs.id` is no longer
    /// necessary. Identity-only equality wasn't load-bearing anyway:
    /// `requestSolveAgain` mints a fresh UUID per call, so two equal-
    /// content launches still produce distinct `id`s.
    struct SolveAgainEntry: Identifiable, Equatable {
        let id: UUID
        let ingredients: [DinnerSolveRequest.IngredientLite]
    }

    /// Called from Tonight's "Solve again" tile. Consumers pass the
    /// `[IngredientLite]` derived from
    /// `SolveRepository.latestPantryIngredients(for:)`; the cover
    /// presents and SolveViewModel is primed via `prepare(with:)`
    /// inside `SolveAgainRoot`'s init.
    func requestSolveAgain(ingredients: [DinnerSolveRequest.IngredientLite]) {
        activeSolveAgain = SolveAgainEntry(id: UUID(), ingredients: ingredients)
    }

    /// Dismissal hook from `SolveAgainRoot`. Clears the active entry
    /// so the cover drops.
    func dismissSolveAgain() {
        activeSolveAgain = nil
    }

    /// "Other options" launch signal. Drives a `.fullScreenCover(item:)`
    /// at TonightHome that mounts `OtherOptionsRoot` — a list of the
    /// alternate dishes from the same MealSolveRequest as the current
    /// Tonight pick, lifted from persisted Core Data (no AI spend).
    /// UUID-keyed (not Bool) so two rapid taps produce distinct
    /// presentations, matching the SolveAgain pattern.
    var activeOtherOptions: OtherOptionsEntry?

    /// Identifiable wrapper for the other-options cover. Carries the
    /// current pick's SuggestedDish UUID so the destination view knows
    /// which dish to EXCLUDE from the alternate list.
    struct OtherOptionsEntry: Identifiable, Equatable {
        let id: UUID
        let currentPickSuggestedDishId: UUID
    }

    /// Called from Tonight's "Other options" hero-card button. Consumers
    /// pass the SuggestedDish id of the current Tonight pick; the cover
    /// fetches the latest solve's other dishes and presents them.
    func requestOtherOptions(currentPickSuggestedDishId: UUID) {
        activeOtherOptions = OtherOptionsEntry(
            id: UUID(),
            currentPickSuggestedDishId: currentPickSuggestedDishId,
        )
    }

    /// Dismissal hook from `OtherOptionsRoot`. Clears the active entry
    /// so the cover drops.
    func dismissOtherOptions() {
        activeOtherOptions = nil
    }

    /// Deep-link scan request signal. `StirDeepLinkHandler` flips this
    /// to a fresh UUID when a widget/intent/Live-Activity tap lands
    /// with `stir://scan/start`. TonightHomeView observes via
    /// `.onChange` and presents its Scan cover. UUID (rather than Bool)
    /// so two rapid taps produce two distinct signals and each
    /// presentation is honored.
    var pendingDeepLinkScan: UUID?

    enum CookModeLaunch: Identifiable, Equatable {
        /// Fresh Cook Mode launched from DishPreview → Start Cooking.
        /// Recipe plan + household are resolved at DishPreview time;
        /// CookModeRoot's .task creates the CookingSession.
        ///
        /// `id` is constructed by the coordinator's `startCookMode(…)`
        /// factory (never defaulted at the call site). Each fresh
        /// launch needs a distinct UUID so SwiftUI's Identifiable
        /// diff re-presents the cover rather than animating a no-op
        /// swap when the same recipe is started twice.
        case fresh(FreshLaunch)
        /// Resumed or re-opened session (resumable banner, Cook Again
        /// on a recent). CookingSession already exists.
        case resume(session: CookingSession)

        struct FreshLaunch: Equatable {
            let id: UUID
            let recipePlan: RecipePlan
            let household: HouseholdProfile
            static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        }

        var id: String {
            switch self {
            case let .fresh(launch): return "fresh-\(launch.id)"
            case let .resume(session): return "resume-\(session.id?.uuidString ?? "unknown")"
            }
        }

        static func == (lhs: CookModeLaunch, rhs: CookModeLaunch) -> Bool {
            lhs.id == rhs.id
        }
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
        cookingSessionRepository: CookingSessionRepository = CookingSessionRepository(),
        householdRepo: HouseholdProfileRepository = HouseholdProfileRepository(),
        sharedStorage: SharedStorage = SharedStorage(),
        revenueCat: (any RevenueCatPurchasing)? = nil,
        trialReminders: TrialReminderScheduler = .shared,
        fastPathMinLoadingDuration: Duration = .milliseconds(500),
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
        self.cookingSessionRepository = cookingSessionRepository
        self.householdRepo = householdRepo
        self.sharedStorage = sharedStorage
        self.revenueCat = revenueCat ?? RevenueCatService.shared
        self.trialReminders = trialReminders
        self.fastPathMinLoadingDuration = fastPathMinLoadingDuration
        attemptFastPathLaunch()
    }

    /// Warm-launch fast path. When the inputs to render Tonight Home are
    /// all on-device — fresh cached entitlements, a previously-resolved
    /// canonical_user_key in the App Group, and a HouseholdProfile for
    /// that key with `onboardingCompleted == true` — flip phase to `.ready`
    /// synchronously and kick off `bootstrap()` in validate-and-correct
    /// mode. The user sees Tonight Home in the first frame instead of
    /// LoadingView for the duration of identity resolve + Supabase round-
    /// trip (typically 500–2500ms).
    ///
    /// Conditions intentionally exclude:
    ///   - First-launch / un-onboarded users (no SharedStorage key, or
    ///     profile.onboardingCompleted == false). Onboarding flow needs
    ///     the proper bootstrap-first sequence to assign the right key.
    ///   - Stale snapshots (>24h). The cache TTL is enforced by
    ///     `EntitlementService.restoreFromCachedSnapshotIfFresh` — if it
    ///     didn't restore, hydrationState stays `.loading` and we skip.
    ///   - CK account flips while killed: the cached canonical_user_key
    ///     mismatches the live identity. The background bootstrap will
    ///     detect this and re-route — `runBootstrap(fastPath: true)`
    ///     re-calls `ensureHouseholdProfile` with the fresh key and
    ///     transitions to `.onboarding` if the new account is un-onboarded.
    ///     For the brief window before that resolves, the user sees the
    ///     prior account's Tonight content.
    ///
    /// **Action-during-validate window (accepted v1 risk):** between
    /// `phase = .ready` and the validate-bootstrap completing, the user
    /// can interact with Tonight (e.g. tap Solve Dinner). Outbound API
    /// calls during this window will use `SupabaseSessionClient`'s cached
    /// JWT (Keychain-persisted across launches); on AUTH-01 the client's
    /// silent re-bootstrap path will mint a fresh JWT against the live
    /// identity, so a stale-cached-key scenario self-heals at the
    /// network layer rather than producing a wrong-attribution write.
    /// Strictest mitigation (gating buttons until validate completes)
    /// is deferred — the v1 window is small, the network-layer self-
    /// heal is in place, and iCloud account flips while the app is
    /// killed are rare.
    private func attemptFastPathLaunch() {
        guard case .hydrated(source: .cachedSnapshot) = entitlements.hydrationState else { return }
        guard let cachedKey = sharedStorage.readCanonicalUserKey(), !cachedKey.isEmpty else { return }
        // Reconstitute the typed identity from the cached string. A
        // malformed value (theoretically possible from a corrupted App
        // Group write or a forward/backward incompatible release) is
        // treated as a cache miss — runBootstrap will resolve fresh.
        guard let cachedIdentity = CanonicalUserKey.parse(cachedKey) else {
            Logger.coordinator.warning(
                "fast-path skipped — cached canonical_user_key failed to parse",
            )
            return
        }

        let profileResult = Result { try householdRepo.findExisting(for: cachedKey) }
        let maybeProfile: HouseholdProfile?
        switch profileResult {
        case .success(let profile):
            maybeProfile = profile
        case .failure(let error):
            // Don't silently coalesce a Core Data fetch failure into
            // "no fast-path" — log so a regression in the persistence
            // layer surfaces in fast-path traces. The non-fast-path
            // launch will surface the same error and route to
            // `.configurationError`; this just makes the diagnostic
            // visible at the entry point.
            Logger.coordinator.warning(
                "fast-path skipped — findExisting threw: \(error.localizedDescription, privacy: .public)",
            )
            return
        }
        guard let profile = maybeProfile, profile.onboardingCompleted else { return }

        household.set(profile)
        // Pre-update CloudKitAvailabilityStore from the cached identity
        // BEFORE seeding `lastEmittedAccountState`. `AccountState.derive`
        // reads `cloudKitAvailable` for the (.free, _) case + the
        // (.premium|.pro, .none) defensive cases. Without this pre-update,
        // `cloudKit.isAvailable` is the default `false`; bootstrap step 1
        // later flips it to true for ck:-prefixed users; the post-bootstrap
        // `emitAccountStateChangeIfNeeded` then sees a fake transition
        // (anonymousLocal → anonymousSyncedFree) that's purely an init-
        // ordering artifact. Pre-updating here closes that gap.
        cloudKit.update(with: cachedIdentity)
        // Seed `lastEmittedAccountState` from the cached snapshot so the
        // post-bootstrap `emitAccountStateChangeIfNeeded` (in
        // `handlePostBootstrapEntitlement`) compares server-truth against
        // cached-truth. Without this seed, that first emit-attempt would
        // see `nil` and silently set the state without emitting, causing
        // a genuine cached→server transition to disappear from telemetry.
        primeLastEmittedAccountState()
        // Phase intentionally STAYS `.loading` here. The min-duration
        // timer below flips it to `.ready` after `fastPathMinLoadingDurationMs`
        // unless bootstrap landed first and already set a terminal phase
        // (.ready / .offlineFallback / .onboarding). Preserves the wordmark
        // brand moment instead of flashing past it.
        isFastPathLaunch = true
        Logger.coordinator.info("fast-path launch start")

        // Min-duration LoadingView gate. Sleeps for the brand-moment
        // window, then flips phase IFF bootstrap hasn't already landed.
        // The phase-equality check is the race-safety: bootstrap may
        // have already set .ready (success), .offlineFallback (failure),
        // or .onboarding (server says profile un-onboarded) — we never
        // overwrite a terminal phase.
        //
        // Bootstrap itself is NOT spawned here — RootView's LoadingView-
        // anchored `.task { coordinator.bootstrap() }` fires it once
        // SwiftUI mounts LoadingView (which it does because phase is
        // `.loading`). One trigger, one canonical entry point. Earlier
        // drafts spawned a second `Task { await self.bootstrap() }` from
        // here, which deduped via `bootstrapTask` but doubled the
        // architectural surface unnecessarily.
        Task { [duration = fastPathMinLoadingDuration] in
            try? await Task.sleep(for: duration)
            if self.phase == .loading {
                self.phase = .ready
            }
        }
    }

    /// Runs the full launch sequence. Idempotent — callable from
    /// `.task { }` or an explicit retry button. Concurrent callers share the
    /// same in-flight task so we don't double-bootstrap when retry() fires
    /// alongside RootView's .task modifier.
    ///
    /// When `attemptFastPathLaunch()` set `isFastPathLaunch = true` at init
    /// time, this runs in validate mode: no LoadingView gate, errors keep
    /// the cached UI showing, success only flips phase if the server's
    /// view diverges from cache (e.g. server says onboarding incomplete).
    func bootstrap() async {
        if let existing = bootstrapTask {
            await existing.value
            return
        }
        let useFastPath = isFastPathLaunch
        isFastPathLaunch = false  // one-shot — retry() runs the full sequence
        let task = Task { await self.runBootstrap(fastPath: useFastPath) }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    private func runBootstrap(fastPath: Bool = false) async {
        if fastPath {
            Logger.coordinator.info("bootstrap start (fast-path validate)")
        } else {
            Logger.coordinator.info("bootstrap start")
            self.phase = .loading
        }

        // 0. ActivityKit reconciliation. Live Activities persist across
        //    force-quit; our in-memory `activities` dict is per-process
        //    and empty on cold launch, so without this every subsequent
        //    end()/update() silently no-ops against ActivityKit's
        //    persisted activities — leaving the stale Lock Screen
        //    countdown ticking up indefinitely (observed device-side
        //    2026-05-03 with the count-up bug compounding the issue).
        //    Process-once gated inside `LiveActivityManager.reconcileOnLaunch`
        //    so this is a no-op on `retry()` and CK-account-change
        //    re-bootstraps that would otherwise kill an in-progress
        //    activity mid-cook.
        await LiveActivityManager.reconcileOnLaunch()

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

        // PostHog identity transition (SA2-C1, 2026-04-24). Read the
        // previously-persisted canonical key and decide the right SDK
        // primitive so the identity graph stays consistent across
        // install→ck migrations (alias) and across genuine user flips
        // on shared devices (reset). Prior to this, plain identify()
        // on every bootstrap fragmented the voice_conversion_event
        // funnel at every paid conversion.
        let previousKey = sharedStorage.readCanonicalUserKey()
        let newKeyString = canonicalKey.stringValue
        applyPostHogIdentityTransition(
            previousKey: previousKey,
            newKey: newKeyString,
            newKeyHash: keyHash,
        )

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
            if !fastPath {
                // Non-fast-path: VAL-01 is fatal-for-this-launch — show
                // the error screen. The user can retry; a persistent
                // VAL-01 indicates an iOS-client schema bug that needs
                // a fix to ship.
                self.phase = .configurationError(
                    "Something went wrong starting the app. Please try again.",
                )
                return
            }
            // Fast-path: cached UI is up. Mark hydration failed and FALL
            // THROUGH to steps 4–8 so lifecycle hooks (writeCanonicalUserKey,
            // ensureHouseholdProfile, app_opened, post-bootstrap entitlement
            // wiring, startAccountChangesObserver) still run for this
            // active session. Returning early would leave the user using
            // cached UI with a broken lifecycle (no CK account-change
            // observer, no RC observer, no trial-reminder reschedule).
            // app_opened fires once at step 5 with bootstrap_succeeded:
            // false; no emit-here-then-emit-there duplication.
            entitlements.markHydrationFailed()
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
        // Mirror the resolved canonical_user_key into the App Group so
        // StirShareExtension can bind PendingImport payloads to the
        // active user (CWE-345 defense against cross-iCloud-account
        // payload bleed). Written on every bootstrap so an account
        // switch after install re-syncs the shared surface.
        sharedStorage.writeCanonicalUserKey(canonicalKeyString)
        do {
            let profile = try householdRepo.ensureHouseholdProfile(for: canonicalKeyString)
            household.set(profile)

            // 5. Emit app_opened now that identity + profile are both resolved.
            emitAppOpenedTelemetry(
                keyHash: keyHash,
                isCloudKit: canonicalKey.isCloudKit,
                bootstrapSucceeded: bootstrapSucceeded,
            )

            // 6. Route based on onboarding status.
            if profile.onboardingCompleted {
                self.onboardingViewModel = nil
                // Both paths (fast-path + non-fast-path) converge on the
                // same routing rule: success → .ready, failure → .offlineFallback.
                //
                // Fast-path successful bootstrap: phase was already .ready
                // from `attemptFastPathLaunch`; this assignment is a no-op
                // (Equatable phase, SwiftUI doesn't re-render).
                //
                // Fast-path failed bootstrap: flip to .offlineFallback so
                // the user sees the OfflineBanner. Hiding the offline
                // signal would leave the user on stale cached data with
                // no way to know they're not getting fresh entitlements
                // (spec §6 SYNC-01 messaging). The banner appearing
                // mid-render is mildly jarring, but worse-UX alternative
                // is silent staleness — the banner has a Retry affordance,
                // silent staleness has none.
                self.phase = bootstrapSucceeded ? .ready : .offlineFallback
            } else {
                // Server says onboarding not complete. Fast-path optimistically
                // showed Tonight; correct course now. Rare in practice
                // (cached profile said onboardingCompleted == true but
                // server-side state diverged — e.g. user reinstalled with
                // same iCloud while mid-onboarding on another device).
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
            // Fast-path: cached household is already set on `self.household`.
            // Don't unmount the UI for a Core Data fetch failure on a key
            // we already used successfully at init time. Still emit
            // app_opened so the active session shows up in the launch
            // funnel (we have keyHash + canonicalKey from steps 1–2; the
            // failure was on profile lookup, not identity).
            if fastPath {
                emitAppOpenedTelemetry(
                    keyHash: keyHash,
                    isCloudKit: canonicalKey.isCloudKit,
                    bootstrapSucceeded: bootstrapSucceeded,
                )
            } else {
                self.phase = .configurationError(
                    "Stir couldn't open its local database. Try reinstalling if this persists.",
                )
            }
        }

        // 7. Post-bootstrap entitlement wiring: RC logIn, trial-reminder,
        //    customerInfoStream observation. Runs only on successful
        //    bootstrap — offline fallback skips these because iOS doesn't
        //    know the authoritative billing state yet.
        if bootstrapSucceeded {
            await handlePostBootstrapEntitlement(canonicalKey: canonicalKeyString)
        } else {
            // Offline: reconcile lastEmittedAccountState. Strict superset
            // of `primeLastEmittedAccountState` — emits a transition iff
            // state changed AND seeds either way. In fast-path, the seed
            // was set in `attemptFastPathLaunch` from cached state; bootstrap
            // failure left entitlements at cached state, so this no-ops.
            // In non-fast-path, lastEmittedAccountState is nil, so this
            // takes the seed-without-emit branch. Either way, a subsequent
            // foreground refresh that lands the real state will emit a
            // clean transition rather than appearing as a "from=nil" event.
            emitAccountStateChangeIfNeeded()
        }

        // 8. Observe CloudKit account changes for the life of the app.
        startAccountChangesObserver()
    }

    /// Apply the correct PostHog identity primitive for the observed
    /// transition — alias for install→ck (merge personas), reset for
    /// genuine user flips on shared devices (unbind queue + rotate
    /// $device_id), identify for first-install or same-key refresh.
    ///
    /// Key shape reminder (CLAUDE.md §Canonical user key):
    ///   install:<UUID>  — anonymous, iCloud not available
    ///   ck:<32-hex>     — CloudKit-keyed, iCloud available
    ///
    /// Transition table:
    /// ┌─ previous ─┬─ new ──────┬─ action ─────────────────────┐
    /// │ nil        │ anything   │ identify (first launch)      │
    /// │ same       │ same       │ identify (no-op refresh)     │
    /// │ install:X  │ ck:Y       │ alias(Y) → identify(Y)       │
    /// │ ck:X       │ ck:Y       │ reset() → identify(Y)        │
    /// │ ck:X       │ install:Y  │ reset() → identify(Y)        │
    /// │ install:X  │ install:Y  │ reset() → identify(Y)        │
    /// └────────────┴────────────┴──────────────────────────────┘
    func applyPostHogIdentityTransition(
        previousKey: String?,
        newKey: String,
        newKeyHash: String,
        client: PostHogClient = PostHogClient.shared,
    ) {
        guard let previous = previousKey, !previous.isEmpty else {
            // First launch — nothing to alias or reset.
            client.identify(distinctID: newKeyHash)
            return
        }
        if previous == newKey {
            // Same identity, fresh bootstrap (TTL expiry, scenePhase,
            // config flip). identify is idempotent on the SDK side; we
            // call it anyway so a fresh worker process still gets bound.
            client.identify(distinctID: newKeyHash)
            return
        }
        let previousIsInstall = previous.hasPrefix("install:")
        let newIsCk = newKey.hasPrefix("ck:")
        if previousIsInstall && newIsCk {
            // Alias-forward: the install:-keyed persona gains a ck:
            // record when iCloud becomes available. PostHog alias()
            // merges the two identities into one person, preserving
            // voice_conversion_event continuity across the migration.
            Logger.coordinator.info(
                "posthog_alias_forward previous_hash=\(CanonicalKeyHash.hash(previous), privacy: .public) new_hash=\(newKeyHash, privacy: .public)",
            )
            sentry.breadcrumb(
                category: "launch",
                message: "posthog_alias_forward",
                data: [
                    "previous_hash": CanonicalKeyHash.hash(previous),
                    "new_hash": newKeyHash,
                ],
            )
            // Per PostHog SDK semantics, alias(...) ties the CURRENT
            // distinct_id to the alias argument. The previous-hash
            // persona is the "current" one from PostHog's perspective
            // (it was the last identify), so we alias to newKeyHash
            // first, THEN identify(newKeyHash) to bind subsequent
            // events to the merged person.
            client.alias(to: newKeyHash)
            client.identify(distinctID: newKeyHash)
            return
        }
        // Genuine different user (ck:A→ck:B, ck:X→install:Y, or
        // install:X→install:Y which means a fresh install rolled its
        // installation UUID). Reset rotates $device_id, clears the
        // event queue, and unbinds distinct_id — prevents the new
        // user inheriting the prior user's device-anonymous events.
        Logger.coordinator.info(
            "posthog_reset_on_user_flip previous_hash=\(CanonicalKeyHash.hash(previous), privacy: .public) new_hash=\(newKeyHash, privacy: .public)",
        )
        sentry.breadcrumb(
            category: "launch",
            message: "posthog_reset_on_user_flip",
            data: [
                "previous_hash": CanonicalKeyHash.hash(previous),
                "new_hash": newKeyHash,
            ],
        )
        client.reset()
        client.identify(distinctID: newKeyHash)
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

        // 2. Reconcile the post-hydrate AccountState against the prior
        //    seed. `emitAccountStateChangeIfNeeded` is a strict superset
        //    of `primeLastEmittedAccountState`: it emits the transition
        //    iff state changed AND seeds either way.
        //
        //    Behavior in each path:
        //    - Non-fast-path: lastEmittedAccountState is nil at this point;
        //      the function takes the "nil → next" branch and seeds without
        //      emitting (correct — the very first launch of a session
        //      isn't a transition).
        //    - Fast-path: lastEmittedAccountState was seeded in
        //      `attemptFastPathLaunch` from the cached snapshot. If the
        //      user's billing state changed while the app was killed
        //      (e.g. they purchased Premium via web/another device, the
        //      RC webhook updated server-side), this fires the transition
        //      with from_state=cached, to_state=server — the exact event
        //      the funnel needs to attribute the conversion. Replacing
        //      `primeLastEmittedAccountState` here was the fix for an
        //      issue where the seeding path overwrote the cached seed
        //      without emitting, silently swallowing real transitions.
        emitAccountStateChangeIfNeeded()

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

    /// scenePhase-driven foreground refresh that no-ops in two cases:
    ///   1. A bootstrap is in flight — `bootstrapTask != nil`. Bootstrap
    ///      itself hydrates entitlements; configBootstrap on top of it
    ///      would race and double-fire network calls. Important for the
    ///      warm-launch fast path where validate-bootstrap runs in the
    ///      background and the scenePhase observer would otherwise fire
    ///      configBootstrap concurrently.
    ///   2. The last server hydrate is fresher than 5s. A fresh-launch
    ///      scenePhase transition right after `/v1/session/bootstrap`
    ///      returns shouldn't immediately re-fetch the same data via
    ///      `/v1/config/bootstrap`.
    ///
    /// Intentional refreshes (RC `customerInfoStream`, paywall dismiss)
    /// call `refreshEntitlementsOnForeground()` directly — those signal
    /// a known state change and shouldn't be skipped.
    func refreshEntitlementsIfStale() async {
        if bootstrapTask != nil {
            Logger.coordinator.debug("foreground refresh skipped — bootstrap in flight")
            return
        }
        if let last = entitlements.lastHydratedAt, Date().timeIntervalSince(last) < 5 {
            Logger.coordinator.debug("foreground refresh skipped — hydration is fresh")
            return
        }
        await refreshEntitlementsOnForeground()
    }

    /// `app_opened` emit. Centralized so all three call sites (success
    /// path, fast-path VAL-01, fast-path Core Data failure) carry the
    /// same property contract — `cold_start`, `build`, `os_version`,
    /// `canonical_user_key_hash`, `is_cloudkit`, `bootstrap_succeeded`.
    /// Spec §15 / canonical-properties.md governs the property list.
    private func emitAppOpenedTelemetry(
        keyHash: String,
        isCloudKit: Bool,
        bootstrapSucceeded: Bool,
    ) {
        PostHogClient.shared.capture(.appOpened, properties: [
            "cold_start": true,
            "build": config.build,
            "os_version": config.osVersion,
            "canonical_user_key_hash": keyHash,
            "is_cloudkit": isCloudKit,
            "bootstrap_succeeded": bootstrapSucceeded,
        ])
    }

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

    /// Called by OnboardingRoot when the flow finishes — either via
    /// the Setup 2 completion transition, a Skip-forward shortcut,
    /// or the Welcome "See a sample" bypass. Fires the coordinator
    /// phase flip + clears the onboarding VM.
    ///
    /// Note: `onboarding_completed` PostHog emission is now owned by
    /// OnboardingViewModel.fireOnboardingCompletedEvent() (called from
    /// OnboardingCompletionView + the See-a-sample handler in
    /// OnboardingRoot). Moved out of the coordinator so every
    /// emission site picks up Spec §15 properties (duration_sec +
    /// skipped_steps) from the ViewModel — the coordinator doesn't
    /// hold the onboarding start-time anchor or the skipped-steps
    /// list, so it can't assemble the full payload.
    func handleOnboardingFinished() {
        self.onboardingViewModel = nil
        self.phase = .ready
    }

    /// Retry for the error-screen Retry button.
    func retry() {
        Task { await bootstrap() }
    }

    // MARK: - Tutorial replay (SCA-5)

    /// Reset the named in-app tutorial and route the user to the tab
    /// where it presents. Called from Settings → "Show tutorial again".
    /// Settings used to mutate `selectedTab` directly; centralizing the
    /// reset+route here keeps the replay sequence in one owner so a
    /// future tutorial added on a non-Tonight surface only changes this
    /// switch, not every Settings call site.
    func replayTutorial(_ key: TutorialKey, manager: TutorialManager = .shared) {
        manager.reset(key)
        switch key {
        case .tonightTour:
            selectedTab = .tonight
        }
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

    /// Surface the Premium-vs-Pro comparison sheet directly (skipping the
    /// full PaywallView). Idempotent — calling while one is up is a no-op
    /// (SwiftUI `.sheet(item:)` would otherwise replace the existing
    /// presentation, which on rapid double-tap can leak the in-flight
    /// `vm.load()` from the first presentation). If the full paywall is
    /// open, this is also a no-op so we don't stack a sheet over a
    /// fullScreenCover.
    func presentProComparison(trigger: PaywallTrigger) {
        if activeProComparison != nil { return }
        if activePaywallTrigger != nil { return }
        activeProComparison = ProComparisonEntry(id: UUID(), trigger: trigger)
    }

    /// Dismissal hook from `RootView`'s `.sheet(item:)` onDismiss. Clears
    /// the active entry. Pro-comparison-driven purchases route through
    /// the same `onEntitlementRefreshRequested` callback as PaywallView,
    /// so no explicit refresh hook is needed here — the VM's success
    /// path already kicks off `refreshEntitlementsOnForeground`.
    func dismissProComparison() {
        activeProComparison = nil
    }

    // MARK: - Cook Mode entry (from Solve flow)

    /// Called by DishPreview when the user taps "Start Cooking". The
    /// caller is expected to also dismiss any presenting modal (e.g.
    /// ScanFlowRoot via `@Environment(\.dismiss)`) on the same
    /// runloop tick. SwiftUI completes that dismiss, then the
    /// `.fullScreenCover(item: $activeCookLaunch)` at TonightHome
    /// picks up and presents Cook Mode — avoiding the
    /// "Currently, only presenting a single sheet is supported"
    /// warning that nested fullScreenCovers trigger.
    func startCookMode(recipePlan: RecipePlan, household: HouseholdProfile) {
        activeCookLaunch = .fresh(
            .init(id: UUID(), recipePlan: recipePlan, household: household),
        )
    }

    /// Resume / re-open an existing CookingSession. Used by the
    /// TonightHome resumable banner and "Cook Again" on recents.
    func resumeCookMode(_ session: CookingSession) {
        activeCookLaunch = .resume(session: session)
    }

    /// Dismissal hook from CookModeRoot. Clears the active launch
    /// so the fullScreenCover drops.
    func dismissCookMode() {
        activeCookLaunch = nil
    }

    // MARK: - Deep-link routing

    /// Called by StirDeepLinkHandler when a widget/intent/Live-Activity
    /// tap lands with `stir://scan/start`. Flips `pendingDeepLinkScan`
    /// to a fresh UUID so TonightHomeView's `.onChange` observer fires
    /// even if we just cleared it.
    func requestDeepLinkScan() {
        pendingDeepLinkScan = UUID()
    }

    /// Clear the scan signal once TonightHomeView has acted on it.
    func clearDeepLinkScan() {
        pendingDeepLinkScan = nil
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

    #if DEBUG
    /// Test-only setter for `phase`. Lets `RootCoordinatorFastPathTests`
    /// pin the equality-not-inequality semantics of the fast-path min-
    /// duration timer guard against any terminal phase, not just `.ready`.
    /// Production code MUST flow through the bootstrap pipeline; this
    /// hatch is gated `#if DEBUG`.
    func _testSetPhase(_ phase: Phase) {
        self.phase = phase
    }
    #endif
}
