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

    // MARK: - SCA-29 consume hook

    /// Locks the SCA-21 wiring on `performFinish`. The repository-level
    /// consume tests already cover the rule's correctness; this is the
    /// integration test that proves the hook actually fires from the
    /// VM's completion path. Without it, a refactor to performFinish
    /// could silently strip the consume call and the pantry would
    /// stop self-cleaning on cook completion (the original SCA-21 bug
    /// the user reported).
    func test_performFinish_consumesEphemeralMatchedPantryRows() async throws {
        // Pantry: two rows that match recipe ingredients (.ephemeral
        // → should soft-delete), plus one row that DOESN'T match
        // (should survive).
        let pantryRepo = PantryItemRepository(controller: controller)
        let cilantro = try seedPantryItem(name: "Cilantro", slug: "cilantro", memoryState: .ephemeral)
        let salsa = try seedPantryItem(name: "Salsa", slug: "salsa", memoryState: .ephemeral)
        let unrelated = try seedPantryItem(name: "Saffron", slug: "saffron", memoryState: .ephemeral)

        // Add matching ingredients to the recipe plan. Recipe also
        // includes a non-pantry ingredient (no-op match) to verify
        // the hook tolerates partial matches gracefully.
        try addIngredient(named: "Cilantro", amount: "1 bunch")
        try addIngredient(named: "Salsa", amount: "1 cup")
        try addIngredient(named: "Tortilla chips", amount: "1 bag")
        // Sanity: the household's pantry actually has the seeded rows.
        XCTAssertEqual(try pantryRepo.fetchAll(for: household).count, 3)

        let session = try freshSession(currentStepIndex: 3)
        let vm = makeVM(session: session)

        // Await the Task — finish()'s @discardableResult Task<Void, Never>
        // is the SCA-49 plumbing that lets us deterministically wait
        // for performFinish (and the consume call inside it) to land.
        await vm.finish().value

        // Matched ephemerals soft-deleted.
        XCTAssertNotNil(cilantro.deletedAt, "matched ephemeral row must be soft-deleted by consume hook")
        XCTAssertNotNil(salsa.deletedAt, "matched ephemeral row must be soft-deleted by consume hook")
        // Unmatched ephemeral untouched.
        XCTAssertNil(unrelated.deletedAt, "unmatched pantry row must NOT be touched by consume")

        // fetchAll reflects the mutation (hook actually saved).
        let surviving = try pantryRepo.fetchAll(for: household)
        XCTAssertEqual(surviving.count, 1)
        XCTAssertEqual(surviving.first?.displayName, "Saffron")
    }

    /// .remembered rows are bumped (lastSeenAt updated) but NOT
    /// soft-deleted by the consume hook — standing items aren't
    /// depleted by one cook. This pins ADR 0029's memory-state-aware
    /// rule at the integration layer.
    func test_performFinish_bumpsRememberedMatchesWithoutDeleting() async throws {
        let oliveOil = try seedPantryItem(
            name: "olive oil",
            slug: "olive_oil",
            memoryState: .remembered,
            lastSeenAt: Date(timeIntervalSinceNow: -86_400),
        )
        let originalLastSeen = oliveOil.lastSeenAt
        try addIngredient(named: "olive oil", amount: "2 tbsp")

        let session = try freshSession(currentStepIndex: 3)
        let vm = makeVM(session: session)

        await vm.finish().value

        XCTAssertNil(oliveOil.deletedAt, "remembered row must survive — standing pantry, no time-based decay from consume")
        XCTAssertNotEqual(oliveOil.lastSeenAt, originalLastSeen, "lastSeenAt must be bumped on match")
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
            liveActivityManager: nil,
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
            liveActivityManager: nil,
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
            liveActivityManager: nil,
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

    // MARK: - Transcript card (recordTurnTranscript)
    //
    // The voice-active transcript card pulls `lastUserTranscript` /
    // `lastModelTranscript` set by `recordTurnTranscript`. The behavior
    // contract has three branches worth pinning:
    //
    //   1. Both halves non-empty (normal turn) → both populate.
    //   2. Only userText non-empty (tool-call-only turn) → userText
    //      populates AND prior modelText is BLANKED so the card doesn't
    //      pair fresh user input with stale Stir reply (review #1).
    //   3. Only modelText non-empty (rare; e.g., proactive narration) →
    //      modelText populates without disturbing prior userText.

    func test_recordTurnTranscript_normalTurn_populatesBothFields() throws {
        let vm = makeVM(session: try freshSession())
        XCTAssertNil(vm.lastUserTranscript)
        XCTAssertNil(vm.lastModelTranscript)

        vm.recordTurnTranscript(
            LiveTurnTranscript(
                turnIndex: 1,
                userText: "How long should I sear it?",
                modelText: "Four minutes on this side.",
            ),
        )

        XCTAssertEqual(vm.lastUserTranscript, "How long should I sear it?")
        XCTAssertEqual(vm.lastModelTranscript, "Four minutes on this side.")
    }

    func test_recordTurnTranscript_toolCallOnlyTurn_blanksStaleModelReply() throws {
        let vm = makeVM(session: try freshSession())

        // Turn 1: normal exchange — both halves populate.
        vm.recordTurnTranscript(
            LiveTurnTranscript(
                turnIndex: 1,
                userText: "How long?",
                modelText: "Four minutes.",
            ),
        )
        XCTAssertEqual(vm.lastModelTranscript, "Four minutes.")

        // Turn 2: tool-call-only — fresh user input, no spoken reply.
        // The OLD model reply must NOT remain visible alongside the
        // NEW user input — that pairing reads as "Stir replied to my
        // latest utterance with this old reply".
        vm.recordTurnTranscript(
            LiveTurnTranscript(
                turnIndex: 2,
                userText: "Next step",
                modelText: "",
            ),
        )

        XCTAssertEqual(vm.lastUserTranscript, "Next step")
        XCTAssertNil(vm.lastModelTranscript,
            "tool-call-only turn must blank prior model reply so card doesn't show stale STIR text")
    }

    func test_recordTurnTranscript_modelOnlyTurn_preservesUserText() throws {
        let vm = makeVM(session: try freshSession())

        // Seed a prior turn so userText is non-nil.
        vm.recordTurnTranscript(
            LiveTurnTranscript(turnIndex: 1, userText: "How long?", modelText: "Four minutes."),
        )

        // Then a model-only update (rare — e.g., proactive narration).
        // The blank-userText branch must not touch lastUserTranscript.
        vm.recordTurnTranscript(
            LiveTurnTranscript(turnIndex: 2, userText: "", modelText: "About two and a half left."),
        )

        XCTAssertEqual(vm.lastUserTranscript, "How long?")
        XCTAssertEqual(vm.lastModelTranscript, "About two and a half left.")
    }

    /// SCA-52 S3: locks the doc-comment's 4th branch — when the caller
    /// violates the "non-empty text" contract on `onTurnTranscriptFinalized`
    /// and sends both halves empty, the shipped behavior is:
    ///   - lastUserTranscript: preserved (guarded by `!userText.isEmpty`)
    ///   - lastModelTranscript: blanked (the `isEmpty ? nil : modelText`
    ///     ternary fires unconditionally)
    /// The test exists so a future refactor toward an asymmetric
    /// "blank-only-when-userText-changes" rule (a reasonable variant)
    /// gets caught — that variant would PRESERVE lastModelTranscript on
    /// both-empty input, breaking this assertion.
    func test_recordTurnTranscript_bothEmptyTurn_blanksModelPreservesUser() throws {
        let vm = makeVM(session: try freshSession())

        vm.recordTurnTranscript(
            LiveTurnTranscript(turnIndex: 1, userText: "How long?", modelText: "Four minutes."),
        )
        XCTAssertEqual(vm.lastUserTranscript, "How long?")
        XCTAssertEqual(vm.lastModelTranscript, "Four minutes.")

        // Contract-violating turn: the caller normally drops these,
        // but the VM must handle them deterministically anyway.
        vm.recordTurnTranscript(
            LiveTurnTranscript(turnIndex: 2, userText: "", modelText: ""),
        )

        XCTAssertEqual(vm.lastUserTranscript, "How long?",
            "userText must be preserved across a both-empty turn (guarded write)")
        XCTAssertNil(vm.lastModelTranscript,
            "modelText must be blanked on a both-empty turn (unconditional ternary)")
    }

    func test_recordTurnTranscript_attachVoiceDriverNil_clearsBothTranscripts() throws {
        let vm = makeVM(session: try freshSession())

        vm.recordTurnTranscript(
            LiveTurnTranscript(turnIndex: 1, userText: "u", modelText: "m"),
        )
        XCTAssertNotNil(vm.lastUserTranscript)
        XCTAssertNotNil(vm.lastModelTranscript)

        // Detaching the driver (e.g., closeVoiceSession path) must
        // wipe transcripts so the next attach starts with a clean
        // card. Carrying prior content into a fresh session would
        // mislead the user about what they just said.
        vm.attachVoiceDriver(nil)

        XCTAssertNil(vm.lastUserTranscript)
        XCTAssertNil(vm.lastModelTranscript)
    }

    func test_isVoiceActive_falseWhenStateClosedOrIdle() throws {
        let vm = makeVM(session: try freshSession())
        // Force user-intent flag true so the gating reduces to the
        // state check alone — terminal states must STILL return false
        // even when the user has explicitly engaged voice.
        vm._testForceVoiceUIRequested(true)

        // Default state — voiceState is nil; no driver attached.
        XCTAssertFalse(vm.isVoiceActive)

        vm._testForceVoiceState(.idle)
        XCTAssertFalse(vm.isVoiceActive)

        vm._testForceVoiceState(.closed)
        XCTAssertFalse(vm.isVoiceActive)

        vm._testForceVoiceState(.error)
        XCTAssertFalse(vm.isVoiceActive)
    }

    func test_isVoiceActive_trueAcrossLiveStates() throws {
        let vm = makeVM(session: try freshSession())
        // User-intent flag must be set; otherwise live states still
        // return false (the auto-engage prevention guard — see
        // `test_isVoiceActive_falseWhenUIRequestedFalse_preventsAutoEngage`).
        vm._testForceVoiceUIRequested(true)
        let liveStates: [VoiceSessionState] = [
            .connecting, .ready, .userSpeaking, .transcribing,
            .thinking, .modelSpeaking, .toolCalling,
            .refreshing, .fallingBack,
        ]
        for state in liveStates {
            vm._testForceVoiceState(state)
            XCTAssertTrue(vm.isVoiceActive,
                "isVoiceActive should be true for state \(state.rawValue) when user has engaged voice")
        }
    }

    /// Regression: at Cook Mode entry, `CookModeRoot.task` pre-warms
    /// the voice driver, which transitions state through `.connecting`
    /// → `.ready`. Without the user-intent gating, `isVoiceActive`
    /// would return true on `.ready` and the voice-active chrome would
    /// auto-show on entry without the user tapping anything (observed
    /// 2026-04-27 — user reported "automatically starts you in voice
    /// mode"). This test pins the new gating: `.ready` alone is not
    /// enough; `isVoiceUIRequested` must also be true.
    func test_isVoiceActive_falseWhenUIRequestedFalse_preventsAutoEngage() throws {
        let vm = makeVM(session: try freshSession())
        // Simulate post-preWarm state without the user having tapped.
        vm._testForceVoiceUIRequested(false)
        for state: VoiceSessionState in [.connecting, .ready, .userSpeaking, .modelSpeaking] {
            vm._testForceVoiceState(state)
            XCTAssertFalse(vm.isVoiceActive,
                "isVoiceActive must stay false on \(state.rawValue) until user engages voice")
        }
    }

    func test_endVoiceMode_clearsFlagAfterCall() async throws {
        let vm = makeVM(session: try freshSession())
        vm._testForceVoiceUIRequested(true)
        vm._testForceVoiceState(.userSpeaking)
        XCTAssertTrue(vm.isVoiceActive)

        await vm.endVoiceMode()

        XCTAssertFalse(vm.isVoiceActive,
            "endVoiceMode must drop isVoiceUIRequested so chrome reverts")
    }

    /// Verifies the "responsive UI" property: the flag flip happens
    /// in the synchronous prologue of `endVoiceMode`, before any
    /// `await` suspension. We spawn the call into a Task, yield once
    /// so the MainActor scheduler runs the spawned task to its first
    /// suspension (or completion), and then assert the flag is
    /// already false BEFORE awaiting the Task itself. If the flip
    /// were post-await, the assertion would race the close work.
    ///
    /// Caveat: with no driver attached, `closeVoiceSession` short-
    /// circuits at its `guard let driver` and never actually
    /// suspends, so this test can't distinguish "flipped before
    /// await" from "Task ran to completion synchronously" — both
    /// satisfy the assertion. The contract is documented in the
    /// production-code comment + the explicit ordering of
    /// `isVoiceUIRequested = false` before `await closeVoiceSession()`.
    /// A mock-driver harness with an awaitable close would tighten
    /// this further; tracked as future work.
    func test_endVoiceMode_clearsFlagBeforeAsyncWork() async throws {
        let vm = makeVM(session: try freshSession())
        vm._testForceVoiceUIRequested(true)
        vm._testForceVoiceState(.userSpeaking)
        XCTAssertTrue(vm.isVoiceActive)

        let endTask = Task { await vm.endVoiceMode() }
        // Yield current MainActor execution so the spawned Task can
        // run cooperatively up to its first suspension point. After
        // resumption here the synchronous prologue (flag flip) has
        // executed.
        await Task.yield()
        XCTAssertFalse(vm.isVoiceActive,
            "flag must be cleared in the synchronous prologue, before any await")

        await endTask.value
        XCTAssertFalse(vm.isVoiceActive)
    }

    func test_endVoiceMode_skipsTelemetryWhenNoDriverAttached() async throws {
        // Defensive check on Suggestion #3 from the 2026-04-27 review:
        // `endVoiceMode` is theoretically reachable without a driver
        // (the listening pill normally only renders with a live
        // session, but a future state-machine quirk could surface it
        // pill-less). We must not emit `voice_stopped` for a session
        // that never existed. Behavioral pin: flag still clears, no
        // crash, no exception.
        let vm = makeVM(session: try freshSession())
        vm._testForceVoiceUIRequested(true)
        vm._testForceVoiceState(.userSpeaking)
        // No driver attached — `voiceDriver` is nil by default.

        await vm.endVoiceMode()

        XCTAssertFalse(vm.isVoiceActive)
        // Telemetry skip is best-verified by absence; this test
        // documents the behavior contract. A PostHogClient stub that
        // records emissions would let us assert non-emission directly;
        // not yet wired (would require wider PostHog DI).
    }

    func test_handleMicTap_engageFailureClearsFlagSoUserCanRetry() async throws {
        // Regression for Warning #1 from the 2026-04-27 review:
        // `handleMicTap` flips `isVoiceUIRequested = true` synchronously
        // before awaiting `beginVoiceTurnInner()`. When that throws
        // (`recognizerUnavailable` is the path with no driver attached
        // — exact scenario in this unit test), the flag must be
        // cleared so the chrome reverts to tap-mode and the user sees
        // the "Ask with voice" button to retry. Without the cleanup,
        // the voice chrome stayed on screen showing a stuck pill with
        // copy that read "Listening — Tap to talk" but tapping closed
        // voice mode entirely.

        // Premium-active entitlement so the entitlement gate passes
        // and we actually reach the engage path (without this, the
        // gate returns early with a paywall trigger and the test
        // would pass for the wrong reason).
        let entitlements = EntitlementService(keychain: MockKeychain())
        entitlements.hydrate(from: Self.premiumActiveEntitlements())

        let session = try freshSession()
        let vm = CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: .solve,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: CookTimerRepository(controller: controller),
            timerService: TimerService(
                repository: CookTimerRepository(controller: controller),
                sessionRepository: CookingSessionRepository(controller: controller),
                notificationCenter: FakeNotificationCenter(),
                liveActivityManager: nil,
            ),
            entitlements: entitlements,
        )
        XCTAssertFalse(vm.isVoiceActive)

        // No driver attached, no rebuild closure → engage path runs:
        // sets `isVoiceUIRequested = true`, then `beginVoiceTurnInner`
        // throws `recognizerUnavailable` (the `guard let voiceDriver`
        // path). The `defer` cleanup in the catch chain must clear the
        // flag so the chrome reverts.
        await vm.handleMicTap()

        XCTAssertFalse(vm.isVoiceActive,
            "engage-path failure must clear isVoiceUIRequested so chrome reverts to tap-mode")
    }

    // MARK: - Entitlement helpers (for tests that need to bypass the
    //         paywall gate in handleMicTap)

    private static func premiumActiveEntitlements() -> BootstrapResponse.Entitlements {
        BootstrapResponse.Entitlements(
            tier: .premium,
            billingState: .active,
            isTrial: false,
            expiresAt: nil,
            voiceEnabled: true,
            billingRetryBanner: false,
            quotas: [
                BootstrapResponse.Quota(
                    featureKey: .voiceCookSession,
                    used: 0,
                    cap: 13,
                    periodEnd: "2026-05-17",
                ),
                BootstrapResponse.Quota(
                    featureKey: .dinnerSolve,
                    used: 0,
                    cap: 40,
                    periodEnd: "2026-05-17",
                ),
                BootstrapResponse.Quota(
                    featureKey: .recipeImport,
                    used: 0,
                    cap: 100_000,
                    periodEnd: "2026-05-17",
                ),
            ],
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
            pantryItemRepository: PantryItemRepository(controller: controller),
            timerService: TimerService(
                repository: CookTimerRepository(controller: controller),
                sessionRepository: CookingSessionRepository(controller: controller),
                notificationCenter: FakeNotificationCenter(),
                liveActivityManager: nil,
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

    /// Seeds a pantry row scoped to the test household. Mirrors the
    /// seedItem helper in PantryItemRepositoryTests; kept private to
    /// this file so the SCA-29 consume hook tests can stand up
    /// matching pantry data without cross-file fixture coupling.
    @discardableResult
    private func seedPantryItem(
        name: String,
        slug: String? = nil,
        memoryState: PantryItem.MemoryState = .ephemeral,
        lastSeenAt: Date? = nil,
    ) throws -> PantryItem {
        let row = PantryItem(context: controller.viewContext)
        row.id = UUID()
        row.household = household
        row.displayName = name
        row.canonicalIngredientSlug = slug ?? ""
        row.typedSource = .scan
        row.typedMemoryState = memoryState
        row.userConfirmed = true
        row.createdAt = Date()
        row.updatedAt = Date()
        row.lastSeenAt = lastSeenAt ?? Date()
        try controller.save()
        return row
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
