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

    private(set) var phase: Phase = .loading

    /// Provided to OnboardingRoot when phase == .onboarding.
    private(set) var onboardingViewModel: OnboardingViewModel?

    private var accountChangesTask: Task<Void, Never>?

    init(
        config: AppConfig,
        entitlements: EntitlementService = EntitlementService(),
        cloudKit: CloudKitAvailabilityStore = CloudKitAvailabilityStore(),
        household: CurrentHouseholdStore = CurrentHouseholdStore(),
        sentry: any SentryReporting = SentryReporter.shared,
        identityService: IdentityService = IdentityService(),
    ) {
        self.config = config
        self.entitlements = entitlements
        self.cloudKit = cloudKit
        self.household = household
        self.sentry = sentry
        self.identityService = identityService
        let client = SupabaseSessionClient(config: config, sentry: sentry)
        self.sessionClient = client
        self.aiDispatch = AIDispatch(session: client, config: config)
        self.pantryItemRepository = PantryItemRepository()
        self.solveRepository = SolveRepository()
    }

    /// Runs the full launch sequence. Idempotent — callable from
    /// `.task { }` or an explicit retry button.
    func bootstrap() async {
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
        (sentry as? SentryReporter)?.setUserContext(keyHash: keyHash)
        PostHogClient.shared.identify(distinctID: keyHash)

        // 3. Bootstrap Supabase session.
        var bootstrapSucceeded = false
        do {
            let response = try await sessionClient.bootstrap(
                installationID: installationID,
                cloudKitRecordName: canonicalKey.cloudKitRecordName,
            )
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

        // 7. Observe CloudKit account changes for the life of the app.
        startAccountChangesObserver(initialKey: canonicalKey)
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

    // MARK: - CloudKit change observer

    private func startAccountChangesObserver(initialKey: CanonicalUserKey) {
        accountChangesTask?.cancel()
        accountChangesTask = Task { [weak self] in
            guard let self else { return }
            for await newKey in self.identityService.observeAccountChanges() {
                guard newKey != initialKey else { continue }
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
