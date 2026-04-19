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

    func test_requestExitConfirm_skipsDialogWhenSessionFresh() throws {
        let session = try freshSession(currentStepIndex: 0)
        let vm = makeVM(session: session)
        XCTAssertFalse(vm.exitConfirmRequested)
        vm.requestExitConfirm()
        // Step 0, no running timers → silent exit, no dialog needed.
        XCTAssertFalse(vm.exitConfirmRequested)
        XCTAssertTrue(vm.shouldDismiss)
    }

    func test_requestExitConfirm_raisesDialogAfterAdvancing() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm.nextStep()
        vm.requestExitConfirm()
        XCTAssertTrue(vm.exitConfirmRequested)
        XCTAssertFalse(vm.shouldDismiss)
    }

    func test_exitAbandon_marksSessionAndRaisesDismissFlag() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm.nextStep()

        vm.exit(markAbandoned: true)
        XCTAssertEqual(session.typedStatus, .abandoned)
        XCTAssertNotNil(session.endedAt)
        XCTAssertTrue(vm.shouldDismiss)
    }

    func test_exitPauseAndResumeLater_leavesSessionActive() throws {
        let session = try freshSession()
        let vm = makeVM(session: session)
        vm.nextStep()

        vm.exit(markAbandoned: false)
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
