// CookModeVoiceIntegrationTests
//
// Phase C.4 coverage for the voice affordance wiring on CookModeViewModel.
// Validates the telemetry contract Daniel called out pre-commit:
//   Free       → voice_affordance_tapped(result=paywall_shown), paywall presented
//   Premium    → voice_affordance_tapped(result=voice_started),   driver.beginTurn
//   Perm Denied → voice_affordance_tapped(result=permission_denied), toast
//
// Also verifies the exit-cleanup invariant: mid-session exit closes
// the driver + deactivates AVAudioSession + writes endedAt.

import CoreData
import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class CookModeVoiceIntegrationTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var telemetrySpy: SpyTelemetry!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household)
        telemetrySpy = SpyTelemetry()
    }

    // MARK: - Free-tier path

    func test_freeUser_micTap_emitsPaywallShown_andCallsPaywall() async throws {
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .free, billingState: .none)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        var paywallTriggers: [PaywallTrigger] = []

        let vm = makeVM(
            session: session,
            entitlements: entitlements,
            voiceDriver: driver,   // present but Free route should ignore
            presentPaywall: { paywallTriggers.append($0) },
        )

        await vm.handleMicTap()

        XCTAssertEqual(paywallTriggers, [.voiceAffordanceTapped])
        let voiceAffordanceEvents = telemetrySpy.events.filter { $0.event == .voiceAffordanceTapped }
        XCTAssertEqual(voiceAffordanceEvents.count, 1)
        XCTAssertEqual(voiceAffordanceEvents.first?.properties["tier"] as? String, "free")
        XCTAssertEqual(voiceAffordanceEvents.first?.properties["result"] as? String, "paywall_shown")
        // Driver must not have been touched.
        XCTAssertEqual(driver.beginTurnCallCount, 0)
    }

    // MARK: - Premium path

    func test_premiumUser_micTap_emitsVoiceStarted_andCallsBeginTurn() async throws {
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        await vm.handleMicTap()

        XCTAssertEqual(driver.beginTurnCallCount, 1)
        let voiceAffordanceEvents = telemetrySpy.events.filter { $0.event == .voiceAffordanceTapped }
        XCTAssertEqual(voiceAffordanceEvents.count, 1)
        XCTAssertEqual(voiceAffordanceEvents.first?.properties["tier"] as? String, "premium")
        XCTAssertEqual(voiceAffordanceEvents.first?.properties["result"] as? String, "voice_started")
    }

    func test_premiumUser_permissionDenied_emitsPermissionDenied_showsToast() async throws {
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        driver.beginTurnErrorToThrow = SpeechFallbackError.permissionDenied(kind: .microphone)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        await vm.handleMicTap()

        let voiceAffordanceEvents = telemetrySpy.events.filter { $0.event == .voiceAffordanceTapped }
        XCTAssertEqual(voiceAffordanceEvents.count, 1)
        XCTAssertEqual(voiceAffordanceEvents.first?.properties["result"] as? String, "permission_denied")
        XCTAssertNotNil(vm.voiceToastMessage)
    }

    func test_expiredPremiumUser_treatedAsFree_emitsPaywallShown() async throws {
        // CLAUDE.md: billing_state=expired demotes tier to free for gating.
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .expired)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        var paywallTriggers: [PaywallTrigger] = []

        let vm = makeVM(
            session: session,
            entitlements: entitlements,
            voiceDriver: driver,
            presentPaywall: { paywallTriggers.append($0) },
        )

        await vm.handleMicTap()

        XCTAssertEqual(paywallTriggers, [.voiceAffordanceTapped])
        let voiceAffordanceEvents = telemetrySpy.events.filter { $0.event == .voiceAffordanceTapped }
        // Effective tier for expired Premium is Free — event tags that way.
        XCTAssertEqual(voiceAffordanceEvents.first?.properties["result"] as? String, "paywall_shown")
    }

    // MARK: - Exit cleanup

    func test_exitAbandon_closesDriver_deactivatesAudio_writesEndedAt() async throws {
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        XCTAssertNil(session.endedAt)
        XCTAssertEqual(driver.closeCallCount, 0)

        await vm.exit(markAbandoned: true)

        XCTAssertEqual(driver.cancelSpeakingCallCount, 1, "TTS must be cancelled before audio deactivate")
        XCTAssertEqual(driver.closeCallCount, 1, "Driver must be closed on exit")
        XCTAssertNotNil(session.endedAt, "endedAt must be written on abandon")
        XCTAssertTrue(vm.shouldDismiss)
    }

    func test_exitPauseLater_closesDriver_keepsEndedAtNilForResume() async throws {
        // Pause-and-resume-later: mic indicator MUST drop (cleanup runs)
        // but endedAt stays nil so Tonight Home's Resume banner still
        // finds this session on the next app open.
        let session = try freshSession()
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        let vm = makeVM(
            session: session,
            entitlements: makeEntitlements(tier: .premium, billingState: .active),
            voiceDriver: driver,
        )

        await vm.exit(markAbandoned: false)

        XCTAssertEqual(driver.closeCallCount, 1, "driver.close() must still run on pause")
        XCTAssertEqual(driver.cancelSpeakingCallCount, 1, "TTS must still be cancelled on pause")
        XCTAssertNil(session.endedAt,
                     "endedAt must stay nil on pause so resume still picks up the session")
        XCTAssertTrue(vm.shouldDismiss)
    }

    // MARK: - voiceEnabled invariant

    func test_voiceEnabled_doesNotFlipOnMicTap() async throws {
        let session = try freshSession()
        XCTAssertFalse(session.voiceEnabled)

        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)

        await vm.handleMicTap()
        XCTAssertFalse(session.voiceEnabled,
                       "voiceEnabled must flip only on first normal VoiceTurn, not on mic tap")
    }

    // MARK: - disable_cook_realtime plumbing

    func test_disableCookRealtime_flag_capturedAtEntry() throws {
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)

        let vmOff = makeVM(session: session, entitlements: entitlements, voiceDriver: driver,
                           disableCookRealtime: false)
        XCTAssertFalse(vmOff.disableCookRealtimeAtEntry)

        let vmOn = makeVM(session: session, entitlements: entitlements, voiceDriver: driver,
                          disableCookRealtime: true)
        XCTAssertTrue(vmOn.disableCookRealtimeAtEntry)
    }

    // MARK: - Helpers

    private func makeVM(
        session: CookingSession,
        entitlements: EntitlementService?,
        voiceDriver: (any VoiceSessionDriver)?,
        disableCookRealtime: Bool = false,
        presentPaywall: ((PaywallTrigger) -> Void)? = nil,
    ) -> CookModeViewModel {
        CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: .solve,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: CookTimerRepository(controller: controller),
            timerService: TimerService(
                repository: CookTimerRepository(controller: controller),
                sessionRepository: CookingSessionRepository(controller: controller),
                notificationCenter: FakeVoiceNotificationCenter(),
            ),
            analytics: telemetrySpy,
            entitlements: entitlements,
            voiceDriver: voiceDriver,
            disableCookRealtime: disableCookRealtime,
            presentPaywall: presentPaywall,
        )
    }

    private func freshSession() throws -> CookingSession {
        try CookingSessionRepository(controller: controller).createSession(
            on: household, for: recipePlan, entryPoint: .solve,
        )
    }

    private func makeRecipePlan(household: HouseholdProfile) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Voice Test Dish"
        plan.servings = 2
        plan.estimatedMinutes = 20
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        for (idx, text) in ["Step 1", "Step 2", "Step 3"].enumerated() {
            let step = RecipeStep(context: context)
            step.id = UUID()
            step.recipePlan = plan
            step.stepNumber = Int16(idx)
            step.sortOrder = Int16(idx)
            step.instructionText = text
        }
        try controller.save()
        return plan
    }

    private func makeEntitlements(tier: Tier, billingState: BillingState) -> EntitlementService {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: BootstrapResponse.Entitlements(
            tier: tier,
            billingState: billingState,
            isTrial: false,
            expiresAt: nil,
            voiceEnabled: billingState == .active && tier != .free,
            billingRetryBanner: false,
            quotas: [
                BootstrapResponse.Quota(featureKey: .voiceCookSession, used: 0, cap: 20, periodEnd: "2027-01-01"),
            ],
        ))
        return service
    }
}

// MARK: - Mock voice driver

@MainActor
final class MockVoiceSessionDriver: VoiceSessionDriver {
    let pathLabel: VoiceSessionPath
    private(set) var currentState: VoiceSessionState = .idle

    private(set) var preWarmCallCount = 0
    private(set) var beginTurnCallCount = 0
    private(set) var endTurnCallCount = 0
    private(set) var speakCallCount = 0
    private(set) var cancelSpeakingCallCount = 0
    private(set) var closeCallCount = 0

    /// If set, `beginTurn()` throws this error instead of advancing state.
    var beginTurnErrorToThrow: (any Error)?

    init(path: VoiceSessionPath) {
        self.pathLabel = path
    }

    func preWarm() async throws {
        preWarmCallCount += 1
        currentState = .ready
    }

    func beginTurn() async throws {
        beginTurnCallCount += 1
        if let err = beginTurnErrorToThrow { throw err }
        currentState = .userSpeaking
    }

    func endTurn(
        recipeContext: RealtimeRecipeContext,
        householdContext: RealtimeHouseholdContext,
        currentStepNumber: Int,
        recipePlanId: UUID,
    ) async throws -> CookTurnResult {
        endTurnCallCount += 1
        currentState = .modelSpeaking
        return CookTurnResult(
            transcript: "test",
            response: CookTurnResponse(
                spokenResponse: "mocked",
                suggestedAction: .none,
                actionParams: nil,
                promptVersion: "1.0.0",
                latencyMS: 10,
                retryCount: 0,
            ),
            sttLatencyMs: 5,
            backendLatencyMs: 5,
        )
    }

    func speak(_ text: String) async {
        speakCallCount += 1
        currentState = .ready
    }

    func cancelSpeaking() {
        cancelSpeakingCallCount += 1
    }

    func close() {
        closeCallCount += 1
        currentState = .closed
    }
}

// MARK: - Telemetry spy

/// Minimal PostHogClient spy that captures every capture() call for
/// assertion. NOT inheriting from the real PostHogClient — we subclass
/// to intercept, since the app wires the real class as a singleton
/// everywhere. Passing a spy into CookModeViewModel's analytics arg
/// works because the VM takes PostHogClient directly.
final class SpyTelemetry: PostHogClient, @unchecked Sendable {
    struct Captured: Sendable {
        let event: TelemetryEvent
        let properties: [String: Any]
    }
    private let lock = NSLock()
    private var _events: [Captured] = []
    var events: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    init() {
        super.init(testingOnly: true)
    }

    override func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        lock.lock()
        _events.append(Captured(event: event, properties: properties))
        lock.unlock()
    }
}

// MARK: - Notification-center stub

/// No-op UNUserNotificationCenterClient so TimerService can be
/// constructed without real permission requests. Matches the
/// FakeNotificationCenter pattern in CookModeViewModelTests; kept
/// local here to avoid exposing a shared test helper until needed.
@MainActor
private final class FakeVoiceNotificationCenter: UNUserNotificationCenterClient {
    func notificationSettings() async -> UNNotificationSettings {
        fatalError("notificationSettings not reached in CookModeVoiceIntegrationTests")
    }
    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool { false }
    func add(_ request: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}
