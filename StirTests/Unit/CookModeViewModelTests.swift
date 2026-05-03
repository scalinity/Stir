// CookModeViewModelTests
//
// Exercises the step-advance state machine + exit/finish flag semantics
// without hitting the network. Uses an in-memory PersistenceController
// so Core Data saves round-trip correctly through the repositories
// CookModeViewModel constructs internally.

import CoreData
import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class CookModeViewModelTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household, stepTexts: [
            "Preheat oven to 400°F.",
            "Chop onions.",
            "Sauté onions until translucent.",
            "Add sauce and simmer.",
        ])
    }

    // MARK: - Initial state

    func test_initialState_tracksSessionStep() throws {
        let session = try freshSession(currentStepIndex: 1)
        let vm = makeVM(session: session)
        XCTAssertEqual(vm.currentStepIndex, 1)
        XCTAssertEqual(vm.totalSteps, 4)
        XCTAssertFalse(vm.isFirstStep)
        XCTAssertFalse(vm.isLastStep)
    }

    // MARK: - Navigation

    func test_nextStep_advancesAndPersists() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        XCTAssertEqual(vm.currentStepIndex, 0)

        vm.nextStep()
        XCTAssertEqual(vm.currentStepIndex, 1)
        XCTAssertEqual(Int(session.currentStepIndex), 1)

        vm.nextStep()
        XCTAssertEqual(vm.currentStepIndex, 2)
        XCTAssertEqual(Int(session.currentStepIndex), 2)
    }

    func test_previousStep_decrementsButNotBelowZero() throws {
        let session = try freshSession(currentStepIndex: 1)
        let vm = makeVM(session: session)

        vm.previousStep()
        XCTAssertEqual(vm.currentStepIndex, 0)
        XCTAssertEqual(Int(session.currentStepIndex), 0)

        // No underflow on first step
        vm.previousStep()
        XCTAssertEqual(vm.currentStepIndex, 0)
    }

    func test_nextStepOnLastStep_raisesFinishFlag() throws {
        let session = try freshSession(currentStepIndex: 3)  // last step (0-3 of 4)
        let vm = makeVM(session: session)
        XCTAssertTrue(vm.isLastStep)
        XCTAssertFalse(vm.finishPresentationRequested)

        vm.nextStep()
        XCTAssertTrue(vm.finishPresentationRequested)
        // Step didn't advance beyond the last step.
        XCTAssertEqual(vm.currentStepIndex, 3)
    }

    // MARK: - Substitution + Exit flags

    func test_requestSubstitution_raisesFlag() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        XCTAssertFalse(vm.substitutionPresentationRequested)
        vm.requestSubstitution()
        XCTAssertTrue(vm.substitutionPresentationRequested)
    }

    // MARK: - Voice substitution apply + acceptedSwaps projection

    func test_applyVoiceSubstitution_exactMatch_mutatesIngredient() throws {
        let pasta = try addIngredient(named: "dried pasta", amount: "12 oz")
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm.applyVoiceSubstitution(
            subEventID: UUID(),
            missingIngredient: "dried pasta",
            substitutionText: "rice noodles",
            amountConversion: "8 oz",
        )

        XCTAssertEqual(pasta.displayName, "rice noodles")
        XCTAssertEqual(pasta.amountText, "8 oz")
        XCTAssertNil(pasta.canonicalIngredientSlug)
    }

    func test_applyVoiceSubstitution_caseInsensitive_mutatesIngredient() throws {
        let pasta = try addIngredient(named: "Dried Pasta", amount: "12 oz")
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm.applyVoiceSubstitution(
            subEventID: UUID(),
            missingIngredient: "DRIED PASTA",
            substitutionText: "rice noodles",
            amountConversion: nil,
        )

        XCTAssertEqual(pasta.displayName, "rice noodles")
        XCTAssertEqual(pasta.amountText, "12 oz",
                       "amountText must be preserved when no conversion supplied")
    }

    func test_applyVoiceSubstitution_substringMatch_mutatesIngredient() throws {
        // Model says "pasta", recipe says "dried pasta" — substring match
        // resolves to the recipe row.
        let pasta = try addIngredient(named: "dried pasta", amount: "12 oz")
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm.applyVoiceSubstitution(
            subEventID: UUID(),
            missingIngredient: "pasta",
            substitutionText: "rice noodles",
            amountConversion: nil,
        )

        XCTAssertEqual(pasta.displayName, "rice noodles")
    }

    func test_applyVoiceSubstitution_noMatch_recipeUnchanged() throws {
        // User said "I'm out of cilantro" but cilantro isn't in the
        // recipe. Falls through to a free-text SubstitutionEvent — the
        // recipe stays untouched.
        let tomato = try addIngredient(named: "tomato", amount: "2 cups")
        let originalName = tomato.displayName
        let originalAmount = tomato.amountText
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm.applyVoiceSubstitution(
            subEventID: UUID(),
            missingIngredient: "cilantro",
            substitutionText: "parsley",
            amountConversion: nil,
        )

        XCTAssertEqual(tomato.displayName, originalName)
        XCTAssertEqual(tomato.amountText, originalAmount)
        // The free-text SubstitutionEvent IS persisted on the session
        // (audit trail) — it just has no FK to a RecipeIngredient.
        let events = session.substitutionArray
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.recipeIngredient)
        XCTAssertEqual(events.first?.missingIngredientDisplayName, "cilantro")
    }

    func test_acceptedSwaps_projectsFromSession() throws {
        try addIngredient(named: "dried pasta", amount: "12 oz")
        try addIngredient(named: "heavy cream", amount: "1 cup")
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm.applyVoiceSubstitution(
            subEventID: UUID(),
            missingIngredient: "dried pasta",
            substitutionText: "rice noodles",
            amountConversion: nil,
        )
        vm.applyVoiceSubstitution(
            subEventID: UUID(),
            missingIngredient: "heavy cream",
            substitutionText: "coconut cream",
            amountConversion: nil,
        )

        let swaps = vm.acceptedSwaps
        XCTAssertEqual(swaps.count, 2)
        // Order is by event createdAt ascending — first applied first.
        XCTAssertEqual(swaps[0].original, "dried pasta")
        XCTAssertEqual(swaps[0].swap, "rice noodles")
        XCTAssertEqual(swaps[1].original, "heavy cream")
        XCTAssertEqual(swaps[1].swap, "coconut cream")
    }

    func test_acceptedSwaps_originalNameSurvivesIngredientMutation() throws {
        // Regression: missingLabel must read the snapshot, not the FK's
        // post-mutation displayName. Without the snapshot rule (added
        // alongside applyAcceptedSwap), the badge would render
        // "rice noodles (was: rice noodles)" — both halves drift to
        // the swap text.
        try addIngredient(named: "dried pasta", amount: "12 oz")
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm.applyVoiceSubstitution(
            subEventID: UUID(),
            missingIngredient: "dried pasta",
            substitutionText: "rice noodles",
            amountConversion: nil,
        )

        let swap = try XCTUnwrap(vm.acceptedSwaps.first)
        XCTAssertEqual(swap.original, "dried pasta",
                       "original must be the snapshot taken before applyAcceptedSwap mutated displayName")
        XCTAssertEqual(swap.swap, "rice noodles")
    }

    // MARK: - Exit + finish flags

    func test_requestExitConfirm_skipsDialogWhenSessionFresh() async throws {
        let session = try freshSession(currentStepIndex: 0)
        let vm = makeVM(session: session)
        XCTAssertFalse(vm.exitConfirmRequested)
        vm.requestExitConfirm()
        // Step 0, no running timers → silent exit via async Task.
        // Yield once so the spawned Task can run.
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(vm.exitConfirmRequested)
        XCTAssertTrue(vm.shouldDismiss)
        // Regression guard (CA1 finding): silent-exit on a never-started
        // session MUST mark abandoned — otherwise every ProgressView →
        // back-tap leaves a ghost "Resume cooking" session that the user
        // never actually started.
        XCTAssertEqual(session.typedStatus, .abandoned)
        XCTAssertNotNil(session.endedAt)
    }

    func test_requestExitConfirm_raisesDialogAfterAdvancing() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm.nextStep()
        vm.requestExitConfirm()
        XCTAssertTrue(vm.exitConfirmRequested)
        XCTAssertFalse(vm.shouldDismiss)
    }

    func test_exitAbandon_marksSessionAndRaisesDismissFlag() async throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm.nextStep()

        await vm.exit(markAbandoned: true)
        XCTAssertEqual(session.typedStatus, .abandoned)
        XCTAssertNotNil(session.endedAt)
        XCTAssertTrue(vm.shouldDismiss)
    }

    func test_exitPauseAndResumeLater_leavesSessionActive() async throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm.nextStep()

        await vm.exit(markAbandoned: false)
        XCTAssertEqual(session.typedStatus, .active)
        XCTAssertNil(session.endedAt)
        XCTAssertTrue(vm.shouldDismiss)
    }

    // MARK: - Finish

    func test_finish_marksSessionCompletedAndRaisesFlag() throws {
        let session = try freshSession(currentStepIndex: 3)
        let vm = makeVM(session: session)

        vm.finish()
        XCTAssertEqual(session.typedStatus, .completed)
        XCTAssertNotNil(session.endedAt)
        XCTAssertTrue(vm.finishPresentationRequested)
    }

    // MARK: - Exit cancels running timers (CA2-R1 regression)
    //
    // When the user chooses Abandon with a running timer, TimerService
    // must cancel it INLINE inside `exit(markAbandoned:)` before
    // `shouldDismiss` flips — otherwise the detached-task cancel path
    // races with the root's onChange dismissal, leaving orphaned
    // UNNotificationRequests that fire for an abandoned session.
    func test_exit_cancelsRunningTimersBeforeShouldDismiss() async throws {
        // Set the first step's timerSeconds so VM.startTimerForCurrentStep
        // creates a running timer.
        let step = try XCTUnwrap(recipePlan.stepArray.first)
        step.timerSeconds = 60
        try controller.save()

        let session = try freshSession()
        let notifyCenter = PermissiveNotificationCenter()
        let timerRepo = CookTimerRepository(controller: controller)
        let timerSvc = TimerService(
            repository: timerRepo,
            sessionRepository: CookingSessionRepository(controller: controller),
            notificationCenter: notifyCenter,
        )
        let vm = CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: .solve,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: timerRepo,
            timerService: timerSvc,
        )
        await vm.startTimerForCurrentStep()
        XCTAssertEqual(vm.activeTimers.filter { $0.typedState == .running }.count, 1)

        await vm.exit(markAbandoned: true)

        XCTAssertTrue(vm.shouldDismiss)
        XCTAssertEqual(session.typedStatus, .abandoned)
        // Every running timer at entry must have been cancelled; any
        // cancelled timer removes its identifier from the notification
        // center's pending list.
        let runningAfter = timerRepo.timers(for: session).filter { $0.typedState == .running }
        XCTAssertEqual(runningAfter.count, 0, "exit should cancel running timers inline")
        XCTAssertGreaterThan(notifyCenter.removedIdentifiers.count, 0)
    }

    // MARK: - Resume semantics (CA1 regression)
    //
    // When a second CookModeViewModel is constructed against the SAME
    // session object with a mid-session currentStepIndex, the view model
    // picks up the persisted index — i.e. the "Resume cooking" banner in
    // Tonight Home successfully restores position instead of starting over.
    // Pairs with the CookModeRoot `existingSession` wiring fix.
    func test_resume_reusesExistingSessionStepIndex() throws {
        let session = try freshSession(currentStepIndex: 2)
        XCTAssertEqual(Int(session.currentStepIndex), 2)

        // Construct a fresh VM against the persisted session — mirrors
        // the Tonight Home resume path (CookModeRoot reuses existingSession).
        let vm = makeVM(session: session)
        XCTAssertEqual(vm.currentStepIndex, 2)

        // And a resumable session is only counted as resumable while
        // status == active + endedAt == nil.
        XCTAssertTrue(session.isResumable)
    }

    // MARK: - Mic button role (pre-first-turn vs between-turns `.ready`)

    func test_micButtonRole_readyBeforeFirstTurn_isAskWithVoice() throws {
        // Observed 2026-04-22: mapping all `.ready` to `.listening`
        // made Cook Mode entry confusing — button said "Listening"
        // seconds after open but the mic wasn't hot, and the first
        // tap closed the session instead of starting a turn. Fix
        // keys the role off `hasBegunFirstTurn`.
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm._testForceVoiceState(.ready)
        vm._testForceHasBegunFirstTurn(false)

        XCTAssertEqual(vm.micButtonRole, .askWithVoice)
    }

    func test_micButtonRole_readyAfterFirstTurn_isListening() throws {
        // After beginTurn has succeeded at least once, the Audio
        // Engine mic tap is installed, VAD is hot, and `.ready` means
        // "between turns, speak freely". Button reflects that.
        let session = try freshSession()
        let vm = makeVM(session: session)

        vm._testForceVoiceState(.ready)
        vm._testForceHasBegunFirstTurn(true)

        XCTAssertEqual(vm.micButtonRole, .listening)
    }

    func test_micButtonRole_terminalStates_areAskWithVoice() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm._testForceHasBegunFirstTurn(true)

        for s: VoiceSessionState? in [nil, .idle, .error, .closed] {
            vm._testForceVoiceState(s)
            XCTAssertEqual(vm.micButtonRole, .askWithVoice,
                           "state \(String(describing: s)) should route to askWithVoice")
        }
    }

    func test_micButtonRole_userSpeaking_isSubmit() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm._testForceHasBegunFirstTurn(true)
        vm._testForceVoiceState(.userSpeaking)
        XCTAssertEqual(vm.micButtonRole, .submit)
    }

    func test_micButtonRole_thinkingModelSpeakingTranscribing_areBusy() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm._testForceHasBegunFirstTurn(true)

        for s: VoiceSessionState in [.thinking, .modelSpeaking, .transcribing, .connecting, .toolCalling, .refreshing, .fallingBack] {
            vm._testForceVoiceState(s)
            XCTAssertEqual(vm.micButtonRole, .busy,
                           "state \(s) should route to busy")
        }
    }

    // MARK: - Voice timer restart semantics (review-driven, 2026-04-23 device bug)
    //
    // Restart was losing track of duplicate step-scoped timers when a
    // resumed session carried a leftover. The fix cancels ALL active
    // step-scoped timers before starting the replacement, and the start
    // guard was extended from `.running` to `.running || .paused || .pending`
    // so the duplicate never gets created in the first place.

    func test_startTimerFromVoice_noOpWhenPausedTimerExistsOnStep() async throws {
        // Seeds the exact state the 2026-04-23 bug depended on: a
        // paused step-scoped timer slipping past an older guard that
        // only considered `.running`. With the fix, a subsequent voice
        // start_timer on the same step must NOT create a second timer.
        let step = try XCTUnwrap(recipePlan.stepArray.first)
        step.timerSeconds = 60
        try controller.save()

        let session = try freshSession()
        let vm = makeTimerAwareVM(session: session)

        await vm.startTimerForCurrentStep()
        let tm1 = try XCTUnwrap(vm.activeTimers.first)
        XCTAssertEqual(tm1.typedState, .running)
        await vm.pauseTimer(tm1)
        XCTAssertEqual(vm.activeTimers.first?.typedState, .paused)
        XCTAssertEqual(vm.activeTimers.count, 1)

        // Voice says "start_timer" again — should no-op against the
        // paused timer, not create a duplicate.
        await vm.startTimerFromVoice(seconds: 120, label: "should not create")

        XCTAssertEqual(vm.activeTimers.count, 1, "paused timer should block a duplicate start")
        XCTAssertEqual(vm.activeTimers.first?.typedState, .paused)
    }

    func test_restartCurrentTimerFromVoice_cancelsAllStepScopedActiveTimers() async throws {
        // Seeds two active timers on the same step (a state the new
        // guard prevents from recurring, but which the cancel loop
        // must still recover from if it's ever reached via migration,
        // CloudKit sync, or a future code path). After restart, both
        // originals must be .cancelled and exactly one fresh timer
        // should be running on the step.
        let step = try XCTUnwrap(recipePlan.stepArray.first)
        step.timerSeconds = 60
        try controller.save()

        let session = try freshSession()
        let timerRepo = CookTimerRepository(controller: controller)
        let timerSvc = TimerService(
            repository: timerRepo,
            sessionRepository: CookingSessionRepository(controller: controller),
            notificationCenter: PermissiveNotificationCenter(),
        )
        let vm = CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: .solve,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: timerRepo,
            timerService: timerSvc,
        )

        // tm1 via VM (populates vm.activeTimers through internal refresh).
        await vm.startTimerForCurrentStep()
        let tm1 = try XCTUnwrap(vm.activeTimers.first)
        // Pause tm1 so the seeding of tm2 doesn't collide with any
        // "running" state guards.
        await vm.pauseTimer(tm1)

        // tm2 seeded directly via repo + service, bypassing the VM
        // guard — simulates the "duplicate already in state" worst case.
        let tm2 = try timerRepo.createTimer(
            for: session, step: step, label: "seeded tm2", durationSec: 90,
        )
        try await timerSvc.start(tm2, on: session)
        // Force the VM's activeTimers to resync with the seeded row.
        await vm.reconcileTimersOnForeground()
        let stepId = step.id!
        let beforeActive = vm.activeTimers.filter {
            $0.step?.id == stepId
            && ($0.typedState == .running || $0.typedState == .paused || $0.typedState == .pending)
        }
        XCTAssertEqual(beforeActive.count, 2, "seed must produce 2 step-scoped active timers")

        _ = await vm.restartCurrentTimerFromVoice(seconds: 30, label: "restart")

        let afterActive = vm.activeTimers.filter {
            $0.step?.id == stepId
            && ($0.typedState == .running || $0.typedState == .paused || $0.typedState == .pending)
        }
        XCTAssertEqual(afterActive.count, 1, "exactly one active step-scoped timer after restart")
        XCTAssertEqual(afterActive.first?.typedState, .running)
        XCTAssertEqual(Int(afterActive.first?.durationSec ?? 0), 30)

        // Both originals must be cancelled — the fix explicitly loops
        // over `first` + everything after it, instead of `first(where:)`.
        XCTAssertEqual(
            vm.activeTimers.first(where: { $0.objectID == tm1.objectID })?.typedState,
            .cancelled,
        )
        XCTAssertEqual(
            vm.activeTimers.first(where: { $0.objectID == tm2.objectID })?.typedState,
            .cancelled,
        )
    }

    /// VM factory with a real TimerService + PermissiveNotificationCenter
    /// so timer lifecycle (createTimer / start / pause / cancel) actually
    /// executes. The default `makeVM` uses FakeNotificationCenter which
    /// fatalErrors on `notificationSettings()` — fine for non-timer tests
    /// but the voice timer tests above need real notification-center
    /// plumbing.
    private func makeTimerAwareVM(session: CookingSession) -> CookModeViewModel {
        let timerRepo = CookTimerRepository(controller: controller)
        let timerSvc = TimerService(
            repository: timerRepo,
            sessionRepository: CookingSessionRepository(controller: controller),
            notificationCenter: PermissiveNotificationCenter(),
        )
        return CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: .solve,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: timerRepo,
            timerService: timerSvc,
        )
    }

    // MARK: - safeInstructionText (VAL-01 guard for empty step text)

    func test_safeInstructionText_emptyStringReplacedWithPlaceholder() {
        // Zod `text: z.string().min(1)` would reject "" and VAL-01
        // the mint. Coercion produces a placeholder the model can
        // acknowledge rather than hallucinate around.
        XCTAssertEqual(
            CookModeViewModel.safeInstructionText(""),
            "(step instruction unavailable)",
        )
        XCTAssertEqual(
            CookModeViewModel.safeInstructionText(nil),
            "(step instruction unavailable)",
        )
        XCTAssertEqual(
            CookModeViewModel.safeInstructionText("   \n\t  "),
            "(step instruction unavailable)",
        )
    }

    func test_safeInstructionText_realTextPassesThroughTrimmed() {
        XCTAssertEqual(
            CookModeViewModel.safeInstructionText("  Sauté onions.  "),
            "Sauté onions.",
        )
        XCTAssertEqual(
            CookModeViewModel.safeInstructionText("Add kale to boiling water."),
            "Add kale to boiling water.",
        )
    }

    // MARK: - Helpers

    private func makeVM(session: CookingSession, source: CookModeViewModel.EntrySource = .solve) -> CookModeViewModel {
        CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: source,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: CookTimerRepository(controller: controller),
            substitutionRepository: SubstitutionRepository(controller: controller),
            timerService: TimerService(
                repository: CookTimerRepository(controller: controller),
                sessionRepository: CookingSessionRepository(controller: controller),
                notificationCenter: FakeNotificationCenter(),
            ),
        )
    }

    private func freshSession(currentStepIndex: Int = 0) throws -> CookingSession {
        let repo = CookingSessionRepository(controller: controller)
        let session = try repo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        if currentStepIndex != 0 {
            try repo.advanceStep(session, to: currentStepIndex)
        }
        return session
    }

    private func makeRecipePlan(household: HouseholdProfile, stepTexts: [String]) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Test Dish"
        plan.summary = "Test summary"
        plan.servings = 2
        plan.difficulty = 2
        plan.estimatedMinutes = 30
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()

        for (idx, text) in stepTexts.enumerated() {
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

    /// Adds an ingredient to the existing recipePlan. Returns the row so
    /// the caller can assert post-mutation state (applyVoiceSubstitution
    /// rewrites displayName + amountText).
    @discardableResult
    private func addIngredient(named name: String, amount: String) throws -> RecipeIngredient {
        let ing = RecipeIngredient(context: controller.viewContext)
        ing.id = UUID()
        ing.recipePlan = recipePlan
        ing.displayName = name
        ing.amountText = amount
        ing.sortOrder = Int16(recipePlan.ingredientArray.count)
        ing.isOptional = false
        try controller.save()
        return ing
    }
}

/// No-op notification center stub so TimerService can be constructed
/// without requesting real UN permissions during unit tests.
@MainActor
private final class FakeNotificationCenter: UNUserNotificationCenterClient {
    func notificationSettings() async -> UNNotificationSettings {
        // UNNotificationSettings has no public initializer. We never
        // reach the permission-check branch in these tests because we
        // never call requestAuthorizationIfNeeded() — CookModeViewModel
        // tests don't start timers. So this fatalError is defensive.
        fatalError("FakeNotificationCenter.notificationSettings shouldn't be reached in CookModeViewModelTests")
    }
    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool { false }
    func add(_ request: UNNotificationRequest) async throws {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}

/// Notification center stub that tolerates `requestAuthorizationIfNeeded`
/// by going through the real UNUserNotificationCenter's cached settings.
/// The test runner is a fresh process per test target run, so
/// `notificationSettings()` will return `.notDetermined` the first call
/// and the `requestAuthorization` stub below makes that branch a no-op.
/// Records removed identifiers so tests can assert on cancellation
/// behavior (CA2-R1 regression).
@MainActor
private final class PermissiveNotificationCenter: UNUserNotificationCenterClient {
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

    func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }
    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}
