// RootCoordinatorFastPathTests
//
// Covers the warm-launch fast path's min-duration LoadingView gate:
//
//   1. Fast-path conditions met → phase starts as .loading at init,
//      then flips to .ready after fastPathMinLoadingDuration.
//   2. Fast-path conditions NOT met (no cached snapshot, or no cached
//      canonical key, or no onboarded profile) → phase stays .loading
//      (no fast-path Task spawned, RootView's .task drives bootstrap).
//   3. The phase-equality race-safety check protects a terminal phase
//      that another path set before the timer fired.
//
// The bootstrap network call is NOT exercised here — RootView's
// `.task { coordinator.bootstrap() }` only fires when SwiftUI mounts
// LoadingView, which doesn't happen in unit tests. That keeps the test
// focused on the timer logic without standing up MockURLProtocol.

import XCTest
@testable import Stir

@MainActor
final class RootCoordinatorFastPathTests: XCTestCase {

    // MARK: - Helpers

    private static func config() -> AppConfig {
        AppConfig(
            supabase: AppConfig.Supabase(
                url: URL(string: "https://test.supabase.co")!,
                anonKey: "test-anon",
            ),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            build: "1.0.0 (1)",
            osVersion: "17.5",
        )
    }

    /// Constructs a UserDefaults backed by a unique suite per test run so
    /// fast-path's `sharedStorage.readCanonicalUserKey()` reads test-scoped
    /// state and doesn't leak into the App Group container.
    ///
    /// `SharedStorage` is in the `Shared/` folder which is compiled into
    /// both the main app target and the test target — Swift sees two
    /// types of the same name. Fully-qualified `Stir.SharedStorage` picks
    /// the main-app-target one, which is what `RootCoordinator.init`
    /// expects.
    private static func uniqueSharedStorage() -> Stir.SharedStorage {
        let suite = "stir.fastpath.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Stir.SharedStorage(defaults: defaults)
    }

    /// EntitlementService whose `hydrationState` is `.hydrated(.cachedSnapshot)`.
    /// Achieved via the two-instance pattern: hydrate one instance, then
    /// create a second on the same Keychain — its init's `restoreFromCachedSnapshotIfFresh`
    /// rehydrates from the just-written cache.
    private static func cachedEntitlementService(
        keychain: MockKeychain,
        tier: Tier = .free,
        billingState: BillingState = .none,
    ) -> EntitlementService {
        let setup = EntitlementService(keychain: keychain)
        setup.hydrate(from: BootstrapResponse.Entitlements(
            tier: tier,
            billingState: billingState,
            isTrial: false,
            expiresAt: nil,
            voiceEnabled: false,
            billingRetryBanner: false,
            standingPantryCap: 25,
            quotas: [],
        ))
        return EntitlementService(keychain: keychain)
    }

    /// Onboarded HouseholdProfile keyed on `canonicalKey`, persisted via
    /// the in-memory PersistenceController.
    private static func onboardedProfile(
        controller: PersistenceController,
        canonicalKey: String,
    ) throws -> HouseholdProfileRepository {
        let repo = HouseholdProfileRepository(controller: controller)
        let profile = try repo.ensureHouseholdProfile(for: canonicalKey)
        try repo.markOnboardingComplete(profile)
        return repo
    }

    private static func sessionClient() -> SupabaseSessionClient {
        SupabaseSessionClient(
            config: config(),
            keychain: MockKeychain(),
            urlSession: .shared,
            sentry: StubSentry(),
        )
    }

    // MARK: - Tests

    func test_fastPath_phaseStartsLoading_thenFlipsToReady_afterMinDuration() async throws {
        let canonicalKey = "install:test-fastpath-1"
        let keychain = MockKeychain()
        let entitlements = Self.cachedEntitlementService(keychain: keychain)
        let storage = Self.uniqueSharedStorage()
        storage.writeCanonicalUserKey(canonicalKey)
        let controller = PersistenceController(inMemory: true)
        let repo = try Self.onboardedProfile(controller: controller, canonicalKey: canonicalKey)

        let coord = RootCoordinator(
            config: Self.config(),
            entitlements: entitlements,
            cloudKit: CloudKitAvailabilityStore(),
            household: CurrentHouseholdStore(),
            sentry: StubSentry(),
            identityService: IdentityService(
                cloudKit: MockCloudKitAccountProvider(.status(.noAccount)),
                keychain: MockKeychain(),
            ),
            sessionClient: Self.sessionClient(),
            aiDispatch: nil,
            persistenceController: controller,
            pantryItemRepository: PantryItemRepository(controller: controller),
            solveRepository: SolveRepository(controller: controller),
            householdRepo: repo,
            sharedStorage: storage,
            revenueCat: MockRevenueCatService(),
            fastPathMinLoadingDuration: .milliseconds(50),
        )

        // Fast-path was triggered: phase still `.loading` because the timer
        // hasn't fired yet. (The Task is enqueued but the sleep hasn't elapsed.)
        XCTAssertEqual(coord.phase, .loading)

        // Wait past the min-duration with a buffer for scheduling jitter.
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(coord.phase, .ready)
    }

    func test_fastPath_skipped_whenNoCachedSnapshot() async throws {
        // Fresh keychain — no cached entitlement snapshot to restore.
        let entitlements = EntitlementService(keychain: MockKeychain())
        let storage = Self.uniqueSharedStorage()
        storage.writeCanonicalUserKey("install:test-no-cache")
        let controller = PersistenceController(inMemory: true)
        let repo = try Self.onboardedProfile(
            controller: controller,
            canonicalKey: "install:test-no-cache",
        )

        let coord = RootCoordinator(
            config: Self.config(),
            entitlements: entitlements,
            cloudKit: CloudKitAvailabilityStore(),
            household: CurrentHouseholdStore(),
            sentry: StubSentry(),
            identityService: IdentityService(
                cloudKit: MockCloudKitAccountProvider(.status(.noAccount)),
                keychain: MockKeychain(),
            ),
            sessionClient: Self.sessionClient(),
            aiDispatch: nil,
            persistenceController: controller,
            pantryItemRepository: PantryItemRepository(controller: controller),
            solveRepository: SolveRepository(controller: controller),
            householdRepo: repo,
            sharedStorage: storage,
            revenueCat: MockRevenueCatService(),
            fastPathMinLoadingDuration: .milliseconds(50),
        )

        XCTAssertEqual(coord.phase, .loading)

        // Wait past the min-duration with a buffer. Fast-path was skipped,
        // so the timer never fired. Phase stays `.loading` until something
        // (in production: RootView's .task → bootstrap) drives a transition.
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(coord.phase, .loading)
    }

    func test_fastPath_skipped_whenNoCachedCanonicalKey() async throws {
        let canonicalKey = "install:test-no-storage"
        let keychain = MockKeychain()
        let entitlements = Self.cachedEntitlementService(keychain: keychain)
        let storage = Self.uniqueSharedStorage()
        // Intentionally NOT writing the canonical key to storage.
        let controller = PersistenceController(inMemory: true)
        let repo = try Self.onboardedProfile(
            controller: controller,
            canonicalKey: canonicalKey,
        )

        let coord = RootCoordinator(
            config: Self.config(),
            entitlements: entitlements,
            cloudKit: CloudKitAvailabilityStore(),
            household: CurrentHouseholdStore(),
            sentry: StubSentry(),
            identityService: IdentityService(
                cloudKit: MockCloudKitAccountProvider(.status(.noAccount)),
                keychain: MockKeychain(),
            ),
            sessionClient: Self.sessionClient(),
            aiDispatch: nil,
            persistenceController: controller,
            pantryItemRepository: PantryItemRepository(controller: controller),
            solveRepository: SolveRepository(controller: controller),
            householdRepo: repo,
            sharedStorage: storage,
            revenueCat: MockRevenueCatService(),
            fastPathMinLoadingDuration: .milliseconds(50),
        )

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coord.phase, .loading)
    }

    func test_fastPath_skipped_whenProfileNotOnboarded() async throws {
        let canonicalKey = "install:test-not-onboarded"
        let keychain = MockKeychain()
        let entitlements = Self.cachedEntitlementService(keychain: keychain)
        let storage = Self.uniqueSharedStorage()
        storage.writeCanonicalUserKey(canonicalKey)
        let controller = PersistenceController(inMemory: true)
        // Profile exists but onboardingCompleted == false.
        let repo = HouseholdProfileRepository(controller: controller)
        _ = try repo.ensureHouseholdProfile(for: canonicalKey)
        // Intentionally NOT calling markOnboardingComplete.

        let coord = RootCoordinator(
            config: Self.config(),
            entitlements: entitlements,
            cloudKit: CloudKitAvailabilityStore(),
            household: CurrentHouseholdStore(),
            sentry: StubSentry(),
            identityService: IdentityService(
                cloudKit: MockCloudKitAccountProvider(.status(.noAccount)),
                keychain: MockKeychain(),
            ),
            sessionClient: Self.sessionClient(),
            aiDispatch: nil,
            persistenceController: controller,
            pantryItemRepository: PantryItemRepository(controller: controller),
            solveRepository: SolveRepository(controller: controller),
            householdRepo: repo,
            sharedStorage: storage,
            revenueCat: MockRevenueCatService(),
            fastPathMinLoadingDuration: .milliseconds(50),
        )

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(coord.phase, .loading)
    }

    /// Helper for the alternate-failure-phase tests below. Builds a
    /// fast-path-eligible coordinator with a long min-duration timer so
    /// the test can mutate phase before the timer fires.
    private func makeFastPathRaceCoordinator(canonicalKey: String) throws -> RootCoordinator {
        let storage = Self.uniqueSharedStorage()
        storage.writeCanonicalUserKey(canonicalKey)
        let controller = PersistenceController(inMemory: true)
        let repo = try Self.onboardedProfile(controller: controller, canonicalKey: canonicalKey)
        return RootCoordinator(
            config: Self.config(),
            entitlements: Self.cachedEntitlementService(keychain: MockKeychain()),
            cloudKit: CloudKitAvailabilityStore(),
            household: CurrentHouseholdStore(),
            sentry: StubSentry(),
            identityService: IdentityService(
                cloudKit: MockCloudKitAccountProvider(.status(.noAccount)),
                keychain: MockKeychain(),
            ),
            sessionClient: Self.sessionClient(),
            aiDispatch: nil,
            persistenceController: controller,
            pantryItemRepository: PantryItemRepository(controller: controller),
            solveRepository: SolveRepository(controller: controller),
            householdRepo: repo,
            sharedStorage: storage,
            revenueCat: MockRevenueCatService(),
            fastPathMinLoadingDuration: .milliseconds(200),
        )
    }

    /// CR3-W4 fix: pin the GUARD's equality semantics on every terminal
    /// phase, not just `.ready`. The previous test passed even if the
    /// guard were `if self.phase != .ready` (a wrong-but-permissive
    /// variant). These additional tests force `.offlineFallback` and
    /// `.configurationError` between attemptFastPathLaunch and the
    /// min-duration timer firing; both must be preserved.

    func test_fastPath_doesNotOverwrite_offlineFallback() async throws {
        let coord = try makeFastPathRaceCoordinator(canonicalKey: "install:test-offline-race")
        XCTAssertEqual(coord.phase, .loading)
        coord._testSetPhase(.offlineFallback)
        XCTAssertEqual(coord.phase, .offlineFallback)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coord.phase, .offlineFallback,
                       "Min-duration timer must NOT clobber a terminal `.offlineFallback` phase.")
    }

    func test_fastPath_doesNotOverwrite_configurationError() async throws {
        let coord = try makeFastPathRaceCoordinator(canonicalKey: "install:test-config-race")
        XCTAssertEqual(coord.phase, .loading)
        let configErrorPhase = RootCoordinator.Phase.configurationError("Config-side fatal.")
        coord._testSetPhase(configErrorPhase)
        XCTAssertEqual(coord.phase, configErrorPhase)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(coord.phase, configErrorPhase,
                       "Min-duration timer must NOT clobber a terminal `.configurationError` phase.")
    }

    func test_fastPath_doesNotOverwrite_terminalPhaseSetBeforeTimer() async throws {
        // Simulates the race where bootstrap (or any other path) sets phase
        // to a terminal value (.ready / .offlineFallback / .onboarding)
        // BEFORE the min-duration timer fires. The timer's phase-equality
        // guard `if self.phase == .loading` should make it a no-op.
        let canonicalKey = "install:test-race-guard"
        let keychain = MockKeychain()
        let entitlements = Self.cachedEntitlementService(keychain: keychain)
        let storage = Self.uniqueSharedStorage()
        storage.writeCanonicalUserKey(canonicalKey)
        let controller = PersistenceController(inMemory: true)
        let repo = try Self.onboardedProfile(controller: controller, canonicalKey: canonicalKey)

        let coord = RootCoordinator(
            config: Self.config(),
            entitlements: entitlements,
            cloudKit: CloudKitAvailabilityStore(),
            household: CurrentHouseholdStore(),
            sentry: StubSentry(),
            identityService: IdentityService(
                cloudKit: MockCloudKitAccountProvider(.status(.noAccount)),
                keychain: MockKeychain(),
            ),
            sessionClient: Self.sessionClient(),
            aiDispatch: nil,
            persistenceController: controller,
            pantryItemRepository: PantryItemRepository(controller: controller),
            solveRepository: SolveRepository(controller: controller),
            householdRepo: repo,
            sharedStorage: storage,
            revenueCat: MockRevenueCatService(),
            // Long enough for our explicit phase mutation below to happen first.
            fastPathMinLoadingDuration: .milliseconds(200),
        )

        XCTAssertEqual(coord.phase, .loading)

        // Force a terminal phase before the timer fires (simulates bootstrap
        // step 6 setting `.offlineFallback` on a fast-failing network).
        coord.handleOnboardingFinished()  // public surface: sets phase = .ready
        XCTAssertEqual(coord.phase, .ready)

        // Wait past the min-duration. The timer's equality guard should
        // observe phase != .loading and skip the assignment — phase stays
        // whatever the prior path set it to.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(coord.phase, .ready)
    }

    func test_readyAndOnboardingCompletionDrainQueuedSharesWithoutForeground() throws {
        let controller = PersistenceController(inMemory: true)
        let storage = Self.uniqueSharedStorage()
        let cloud = CloudKitAvailabilityStore()
        cloud.update(with: .install(uuid: "queued-share"))
        let coordinator = RootCoordinator(
            config: Self.config(), entitlements: EntitlementService(keychain: MockKeychain()),
            cloudKit: cloud, sentry: StubSentry(), sessionClient: Self.sessionClient(),
            persistenceController: controller, sharedStorage: storage, revenueCat: MockRevenueCatService()
        )
        _ = try coordinator.selectHousehold(for: "install:queued-share", previousKey: nil, installationID: "queued-share")
        let first = Stir.PendingImport(url: "https://example.com/recipe", text: nil, capturedAt: Date(), consumingUserKey: "install:queued-share")
        storage.writePendingImport(first)
        coordinator.drainPendingImportsIfReady()
        XCTAssertNil(coordinator.activeImport, "Loading retains the queued payload")
        XCTAssertEqual(storage.readPendingImport()?.id, first.id)

        coordinator._testSetPhase(.ready)
        coordinator.drainPendingImportsIfReady()
        XCTAssertEqual(coordinator.activeImport?.id, first.id)
        let next = Stir.PendingImport(url: nil, text: "second recipe", capturedAt: Date(), consumingUserKey: "install:queued-share")
        storage.writePendingImport(next)
        coordinator.drainPendingImportsIfReady()
        XCTAssertEqual(storage.readPendingImport()?.id, next.id, "An active import retains the next share")
        coordinator.dismissImport()
        coordinator._testSetPhase(.onboarding)
        coordinator.handleOnboardingFinished()
        XCTAssertEqual(coordinator.activeImport?.id, next.id)
    }

    func test_selectedControllerOwnsOnboardingImportAndRetentionMaintenance() throws {
        let controller = PersistenceController(inMemory: true)
        let storage = Self.uniqueSharedStorage()
        let cloud = CloudKitAvailabilityStore()
        cloud.update(with: .install(uuid: "composition"))
        let coordinator = RootCoordinator(
            config: Self.config(), entitlements: EntitlementService(keychain: MockKeychain()),
            cloudKit: cloud, sentry: StubSentry(), sessionClient: Self.sessionClient(),
            persistenceController: controller, sharedStorage: storage, revenueCat: MockRevenueCatService()
        )
        let profile = try coordinator.selectHousehold(for: "install:composition", previousKey: nil, installationID: "composition")
        let onboarding = coordinator.makeOnboardingViewModel(for: profile)
        onboarding.customDislikes = ["cilantro"]
        onboarding.selectedEquipment = [.oven]
        onboarding.servingsDefault = 4
        try onboarding.savePreferences()
        try onboarding.saveKitchen()
        try onboarding.completeOnboarding()
        XCTAssertEqual(profile.dietaryRuleArray.first?.managedObjectContext, controller.viewContext)
        XCTAssertEqual(profile.kitchenEquipmentArray.first?.managedObjectContext, controller.viewContext)
        XCTAssertEqual(profile.servingsDefault, 4)

        let recipe = RecipeImportResponse.ImportedRecipe(
            title: "Tomato pasta", servings: 2, estimatedMinutes: 20,
            ingredients: [.init(displayName: "pasta", canonicalSlug: "pasta", amountText: "8 oz", group: nil)],
            steps: [.init(stepNumber: 1, instructionText: "Cook the pasta.", timerSeconds: 600, cautionTags: nil)],
            parseQuality: .high, editHints: nil
        )
        _ = try coordinator.makeImportViewModel(for: profile).buildRecipePlan(recipe, source: .pastedText)
        try controller.save()
        XCTAssertEqual((profile.recipePlans?.anyObject() as? RecipePlan)?.managedObjectContext, controller.viewContext)
        let oldImport = try coordinator.recipeImportRepository.start(for: profile, input: .init(
            importID: UUID(), source: .pastedText, sourceURL: nil, ocrPageCount: 0, rawContent: "recipe"
        ))
        try coordinator.recipeImportRepository.markCompleted(oldImport, recipePlanID: UUID(), aiRequestID: nil)
        let oldID = try XCTUnwrap(oldImport.id)
        let now = Date()
        oldImport.completedAt = now.addingTimeInterval(-31 * 86_400)
        try controller.save()
        coordinator.runImportRetentionMaintenance(now: now)
        XCTAssertNil(try coordinator.recipeImportRepository.find(importID: oldID))
    }

    func test_coordinatorPromotesOnlyItsExactInstallationKey() throws {
        let controller = PersistenceController(inMemory: true)
        let coordinator = RootCoordinator(
            config: Self.config(), entitlements: EntitlementService(keychain: MockKeychain()),
            sentry: StubSentry(), sessionClient: Self.sessionClient(), persistenceController: controller,
            sharedStorage: Self.uniqueSharedStorage(), revenueCat: MockRevenueCatService()
        )
        let repository = HouseholdProfileRepository(controller: controller)
        let local = try repository.ensureHouseholdProfile(for: "install:own")
        let unrelated = try repository.ensureHouseholdProfile(for: "install:other")
        _ = try coordinator.selectHousehold(for: "ck:A", previousKey: "install:other", installationID: "own")
        XCTAssertEqual(unrelated.canonicalUserKey, "install:other")
        let promoted = try coordinator.selectHousehold(for: "ck:B", previousKey: "install:own", installationID: "own")
        XCTAssertEqual(promoted, local)
        let otherAccount = try coordinator.selectHousehold(for: "ck:C", previousKey: "ck:B", installationID: "own")
        XCTAssertNotEqual(otherAccount.objectID, promoted.objectID)
        XCTAssertEqual(local.canonicalUserKey, "ck:B")
    }

}

// MARK: - Stub

private final class StubSentry: SentryReporting, @unchecked Sendable {
    func captureError(_: any Error, context _: [String: String]) {}
    func breadcrumb(category _: String, message _: String, data _: [String: String]) {}
    func setUserContext(keyHash _: String) {}
}
