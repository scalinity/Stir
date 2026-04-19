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

    // MARK: - Helpers

    private func makeVM(session: CookingSession, source: CookModeViewModel.EntrySource = .solve) -> CookModeViewModel {
        CookModeViewModel(
            session: session,
            recipePlan: recipePlan,
            household: household,
            source: source,
            cookingSessionRepository: CookingSessionRepository(controller: controller),
            cookTimerRepository: CookTimerRepository(controller: controller),
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
