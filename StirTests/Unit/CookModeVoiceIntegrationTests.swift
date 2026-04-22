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
    private var sentrySpy: SpySentry!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household)
        telemetrySpy = SpyTelemetry()
        sentrySpy = SpySentry()
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

    // MARK: - endVoiceTurn — suggested_action transitions

    func test_endVoiceTurn_advanceStep_callsNextStepWithVoiceLabel() async throws {
        // Spec §15 requires `cook_step_advanced.advanced_by` to
        // discriminate manual vs voice. Review finding #2 fixed the
        // label bug; this test pins it.
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        driver.endTurnResult = .defaultMock(action: .advanceStep)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        await vm.handleMicTap()  // begin
        XCTAssertEqual(driver.beginTurnCallCount, 1)
        await vm.handleMicTap()  // submit → endVoiceTurn

        XCTAssertEqual(driver.endTurnCallCount, 1)
        XCTAssertEqual(driver.speakCallCount, 1, "spoken_response must be played")

        let stepAdvances = telemetrySpy.events.filter { $0.event == .cookStepAdvanced }
        XCTAssertEqual(stepAdvances.count, 1)
        // Property key is `manual_or_voice` per spec §15 (not `advanced_by`).
        XCTAssertEqual(stepAdvances.first?.properties["manual_or_voice"] as? String, "voice",
                       "voice-driven advance must tag manual_or_voice=voice, not manual")
        XCTAssertEqual(vm.currentStepIndex, 1, "step must actually advance")
    }

    func test_endVoiceTurn_noneAction_doesNotAdvanceStep() async throws {
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        driver.endTurnResult = .defaultMock(action: .none, spokenResponse: "reduce heat a little")

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        await vm.handleMicTap()
        await vm.handleMicTap()

        XCTAssertEqual(driver.endTurnCallCount, 1)
        XCTAssertEqual(driver.speakCallCount, 1)
        XCTAssertEqual(driver.speakArgs.first, "reduce heat a little",
                       "spoken_response text must round-trip to the synthesizer")
        XCTAssertEqual(vm.currentStepIndex, 0, "none action must leave step index untouched")
        XCTAssertTrue(telemetrySpy.events.contains { $0.event == .cookTurnResolved },
                      "cook_turn_resolved must fire even for no-action turns")
    }

    func test_endVoiceTurn_recipePlanIdNil_surfacesValidationToast_andTearsDownDriver() async throws {
        // Review finding #3 fix: a nil recipe_plan_id used to silently
        // drop the turn. Must surface a VAL-01 toast + emit
        // screen_error_shown + capture to Sentry. Follow-up review:
        // also must tear down the driver so the user doesn't get stuck
        // in a dead-mic loop (state stays `.userSpeaking` → every tap
        // re-hits the guard).
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        await vm.handleMicTap()  // begin
        // Force the invariant violation after beginTurn so the state
        // machine is actually in userSpeaking when endVoiceTurn runs.
        recipePlan.id = nil
        await vm.handleMicTap()  // submit

        XCTAssertEqual(driver.endTurnCallCount, 0,
                       "endTurn must not be called when recipe_plan.id is nil")
        XCTAssertNotNil(vm.voiceToastMessage,
                        "user-visible toast must surface the validation failure")
        let screenErrors = telemetrySpy.events.filter { $0.event == .screenErrorShown }
        XCTAssertEqual(screenErrors.count, 1)
        XCTAssertEqual(screenErrors.first?.properties["error_code"] as? String, "VAL-01")

        // Sentry capture + driver teardown contract.
        XCTAssertEqual(sentrySpy.captures.count, 1,
                       "nil recipe_plan_id must be captured to Sentry as an error, not just a breadcrumb")
        XCTAssertEqual(driver.closeCallCount, 1,
                       "driver must be torn down to recover from the dead-mic loop trap")
        XCTAssertEqual(vm.voiceState, .closed,
                       "voiceState must reflect the torn-down driver so voiceIsListening flips false")

        // Subsequent tap must route to the "no driver" path (surfaces
        // "Voice isn't available on this device") instead of re-hitting
        // the same nil-recipe guard.
        let screenErrorsBefore = telemetrySpy.events.filter { $0.event == .screenErrorShown }.count
        await vm.handleMicTap()
        let screenErrorsAfter = telemetrySpy.events.filter { $0.event == .screenErrorShown }.count
        XCTAssertEqual(driver.endTurnCallCount, 0, "dropped driver must not receive further endTurn calls")
        XCTAssertEqual(screenErrorsAfter, screenErrorsBefore + 1,
                       "third tap emits a new error (no-driver path), not looping the nil-recipe error")
    }

    // MARK: - endVoiceTurn — startTimer transition

    func test_endVoiceTurn_startTimerAction_triggersTimerForCurrentStep() async throws {
        // Suggestion #2 from re-review: pin the .startTimer suggested
        // action. Current step has a timerSeconds > 0, so the model's
        // start_timer request must result in a real timer being scheduled.
        let session = try freshSession()
        // Give step 0 a timer so startTimerForCurrentStep has something
        // to activate.
        recipePlan.stepArray.first?.timerSeconds = 120
        try controller.save()

        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        driver.endTurnResult = .defaultMock(action: .startTimer, spokenResponse: "Starting a two-minute timer.")

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        await vm.handleMicTap()  // begin
        await vm.handleMicTap()  // submit → endVoiceTurn → startTimer

        XCTAssertEqual(driver.endTurnCallCount, 1)
        XCTAssertEqual(driver.speakCallCount, 1)
        // startTimerForCurrentStep creates + starts a CookTimer for the
        // current step. We assert the VM now tracks one timer attached
        // to the current step.
        XCTAssertEqual(vm.activeTimers.count, 1, ".startTimer must create exactly one timer")
        XCTAssertEqual(vm.activeTimers.first?.step?.id, recipePlan.stepArray.first?.id,
                       "timer must be attached to the current step")
    }

    // MARK: - handleMicTap — tap-while-busy telemetry

    func test_handleMicTap_whileThinking_closesSession_andEmitsVoiceStopped() async throws {
        // Behavior changed 2026-04-22 after the user reported being
        // trapped in voice mode: the mic button was `.disabled` during
        // `.busy` states, so tapping did nothing visible and there was
        // no other way to exit voice mode without leaving Cook Mode
        // entirely. New contract: tap during any non-speaking active
        // state (.thinking / .modelSpeaking / .toolCalling / etc.)
        // closes the voice session, emitting
        // `voice_affordance_tapped(result=voice_stopped)`.
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        // Put the driver (and mirror the VM) into .thinking so the
        // tap hits the non-speaking-active branch.
        driver.stubState(.thinking)
        vm._testForceVoiceState(.thinking)

        await vm.handleMicTap()

        XCTAssertNil(vm.voiceToastMessage,
                     "closing the session should not pop a toast — it's a real teardown, not a soft no-op")
        XCTAssertEqual(vm.voiceState, .closed,
                       "voiceState must reflect the torn-down session so the button returns to .askWithVoice")
        XCTAssertEqual(driver.closeCallCount, 1,
                       "driver.close must fire as part of the teardown")
        let affordances = telemetrySpy.events.filter { $0.event == .voiceAffordanceTapped }
        XCTAssertEqual(affordances.count, 1)
        XCTAssertEqual(affordances.first?.properties["result"] as? String, "voice_stopped",
                       "spec §15 `voice_affordance_tapped.result` gains 'voice_stopped' for the close path")
    }

    // MARK: - presentStirError — typed error routing

    func test_endVoiceTurn_rateLimitedError_routesToProUpsellPaywall() async throws {
        // Suggestion #3 from re-review: pin the StirError routing
        // contract. A RATE-01 surfacing during an in-flight voice turn
        // (Premium hit their monthly voice cap) must route to the
        // voiceCookQuotaExhausted Pro-upsell paywall, not the generic
        // trial one. Must also fire a code-only Sentry breadcrumb
        // (no PII from String(describing:) walking associated values).
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        driver.endTurnErrorToThrow = StirError.rateLimited(resetDate: nil, message: "RATE-01")
        var paywallTriggers: [PaywallTrigger] = []

        let vm = makeVM(
            session: session,
            entitlements: entitlements,
            voiceDriver: driver,
            presentPaywall: { paywallTriggers.append($0) },
        )
        await vm.handleMicTap()  // begin
        await vm.handleMicTap()  // submit → endVoiceTurn → rateLimited

        XCTAssertEqual(paywallTriggers, [.voiceCookQuotaExhausted],
                       "in-flight RATE-01 must route to Pro-upsell, not generic trial paywall")
        // Sentry breadcrumb fires with code-only message (no PII from
        // String(describing:) walking associated values).
        let voiceBreadcrumbs = sentrySpy.breadcrumbs.filter { $0.category == "voice" }
        XCTAssertEqual(voiceBreadcrumbs.count, 1)
        XCTAssertEqual(voiceBreadcrumbs.first?.message, "RATE-01",
                       "breadcrumb message must be the error code only, no associated-value payload")
        XCTAssertEqual(voiceBreadcrumbs.first?.data["code"], "RATE-01")
    }

    func test_endVoiceTurn_networkUnreachable_surfacesNet01Toast() async throws {
        // StirError.networkUnreachable must route to a NET-01 toast,
        // not the generic "voice turn failed" fallback.
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)
        driver.endTurnErrorToThrow = StirError.networkUnreachable(underlying: nil)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        await vm.handleMicTap()
        await vm.handleMicTap()

        let screenErrors = telemetrySpy.events.filter { $0.event == .screenErrorShown }
        XCTAssertEqual(screenErrors.count, 1)
        XCTAssertEqual(screenErrors.first?.properties["error_code"] as? String, "NET-01")
    }

    // MARK: - cook_voice_default_on (auto-engage) — C.5

    func test_autoEngage_simulatesFirstMicTap_andFiresVoiceStartedTelemetry() async throws {
        // C.5 contract: CookModeRoot reads `cook_voice_default_on` and,
        // when true + Premium+ + pre-warmed driver + !killSwitch, calls
        // `vm.handleMicTap()` once on Cook Mode entry. That tap takes
        // the same happy path as a user tap — we pin that the telemetry
        // result matches (`voice_started`) and beginTurn fires exactly
        // once. The flag itself is consumed in CookModeRoot; at this
        // layer we exercise the "simulated first tap" invariant.
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let driver = MockVoiceSessionDriver(path: .geminiFallback)

        let vm = makeVM(session: session, entitlements: entitlements, voiceDriver: driver)
        // Simulate what CookModeRoot.task does post-pre-warm.
        await vm.handleMicTap()

        XCTAssertEqual(driver.beginTurnCallCount, 1,
                       "auto-engage must trigger exactly one beginTurn")
        let affordances = telemetrySpy.events.filter { $0.event == .voiceAffordanceTapped }
        XCTAssertEqual(affordances.count, 1)
        XCTAssertEqual(affordances.first?.properties["result"] as? String, "voice_started",
                       "auto-engage uses the same success result as a user tap")
    }

    func test_autoEngage_freeTierWouldRouteToPaywall_butCookModeRootGatesBeforeThis() async throws {
        // Belt-and-suspenders check: even if CookModeRoot's canVoice
        // check somehow let a Free user through, the VM's paywall
        // routing still fires. Documents the gate ordering so nobody
        // re-adds a Free-tier auto-engage path by mistake.
        let session = try freshSession()
        let entitlements = makeEntitlements(tier: .free, billingState: .none)
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
        XCTAssertEqual(driver.beginTurnCallCount, 0)
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
            sentry: sentrySpy,
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
    private(set) var speakArgs: [String] = []
    private(set) var cancelSpeakingCallCount = 0
    private(set) var closeCallCount = 0

    /// If set, `beginTurn()` throws this error instead of advancing state.
    var beginTurnErrorToThrow: (any Error)?

    /// If set, `endTurn()` throws this error (after incrementing
    /// `endTurnCallCount` + moving state to `.modelSpeaking`) instead of
    /// returning `endTurnResult`. Lets tests pin the `presentStirError`
    /// routing contract for RATE-01 / NET-01 / AI-VOICE-01 / etc.
    var endTurnErrorToThrow: (any Error)?

    /// If set, `endTurn()` returns this result. Defaults to a benign
    /// `.none`-action response so existing tests keep working.
    var endTurnResult: CookTurnResult = .defaultMock()

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
        if let err = endTurnErrorToThrow { throw err }
        return endTurnResult
    }

    func speak(_ text: String) async {
        speakCallCount += 1
        speakArgs.append(text)
        currentState = .ready
    }

    /// Async to match the updated `VoiceSessionDriver` protocol
    /// (post review fix: cancel now awaits state transition so the next
    /// beginTurn can't race into `.busy`).
    func cancelSpeaking() async {
        cancelSpeakingCallCount += 1
    }

    func close() {
        closeCallCount += 1
        currentState = .closed
    }

    /// Test hook: forcibly set the driver state so we can exercise
    /// VM flows that expect a specific mid-session state without
    /// running a full turn to get there (e.g., tap-while-thinking).
    func stubState(_ state: VoiceSessionState) {
        currentState = state
    }
}

private extension CookTurnResult {
    static func defaultMock(
        action: CookTurnResponse.SuggestedAction = .none,
        params: CookTurnResponse.ActionParams? = nil,
        spokenResponse: String = "mocked",
    ) -> CookTurnResult {
        CookTurnResult(
            transcript: "test",
            response: CookTurnResponse(
                spokenResponse: spokenResponse,
                suggestedAction: action,
                actionParams: params,
                promptVersion: "1.0.0",
                latencyMS: 10,
                retryCount: 0,
            ),
            sttLatencyMs: 5,
            backendLatencyMs: 5,
        )
    }
}

// MARK: - Sentry spy

/// Captures every captureError + breadcrumb call so tests can assert on
/// the typed-error + breadcrumb contract in `presentStirError` and the
/// nil-recipe-id recovery path. Pinned here (not per-test) so every VM
/// test exercises the same spy.
final class SpySentry: SentryReporting, @unchecked Sendable {
    struct BreadcrumbCall: Sendable {
        let category: String
        let message: String
        let data: [String: String]
    }
    struct CaptureCall: Sendable {
        let error: any Error
        let context: [String: String]
    }

    private let lock = NSLock()
    private var _breadcrumbs: [BreadcrumbCall] = []
    private var _captures: [CaptureCall] = []

    var breadcrumbs: [BreadcrumbCall] {
        lock.lock(); defer { lock.unlock() }
        return _breadcrumbs
    }
    var captures: [CaptureCall] {
        lock.lock(); defer { lock.unlock() }
        return _captures
    }

    func captureError(_ error: any Error, context: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        _captures.append(CaptureCall(error: error, context: context))
    }

    func breadcrumb(category: String, message: String, data: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        _breadcrumbs.append(BreadcrumbCall(category: category, message: message, data: data))
    }

    func setUserContext(keyHash: String) {}
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

/// UNUserNotificationCenterClient stub for CookModeVoiceIntegrationTests.
/// Delegates `notificationSettings()` to the real UNUserNotificationCenter
/// so timer-starting flows (reached by the .startTimer suggested_action
/// test) don't crash. The test runner returns `.notDetermined` for
/// unconfigured settings, which `requestAuthorization` below stubs
/// truthy — keeps the TimerService path usable without touching real
/// notification infrastructure.
@MainActor
private final class FakeVoiceNotificationCenter: UNUserNotificationCenterClient {
    func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }
    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}
