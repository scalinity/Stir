// TimerServiceReconcileTests
//
// Exercises TimerService.reconcileOnForeground — the "app foregrounded
// after a backgrounded timer naturally fired" path. CookModeRoot calls
// this on .task entry and CookModeViewModel surfaces it on resume so any
// timer whose fireDate has passed transitions to .completed without
// waiting for the user to revisit the step.
//
// The pending and freshly-running timer paths are covered in
// TimerServiceTests; this file isolates the reconcile branching.

import CoreData
import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class TimerServiceReconcileTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var notificationCenter: RecordingNotificationCenter!
    private var service: TimerService!
    private var timerRepo: CookTimerRepository!
    private var sessionRepo: CookingSessionRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household)
        notificationCenter = RecordingNotificationCenter()
        timerRepo = CookTimerRepository(controller: controller)
        sessionRepo = CookingSessionRepository(controller: controller)
        service = TimerService(
            repository: timerRepo,
            sessionRepository: sessionRepo,
            notificationCenter: notificationCenter,
            liveActivityManager: nil,
        )
    }

    func test_reconcile_marksOverdueRunningTimerAsCompleted() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Done already",
            durationSec: 60,
        )
        // Manually back-date startedAt so fireDate is already in the past.
        let oneMinuteAgo = Date().addingTimeInterval(-120)
        try timerRepo.start(timer, at: oneMinuteAgo)
        XCTAssertEqual(timer.typedState, .running)

        let transitioned = try await service.reconcileOnForeground(session: session)

        XCTAssertEqual(transitioned.count, 1)
        XCTAssertEqual(timer.typedState, .completed)
        XCTAssertNotNil(timer.endedAt)
    }

    func test_reconcile_leavesNotYetFiredTimerRunning() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Still cooking",
            durationSec: 600,
        )
        try await service.start(timer, on: session)
        XCTAssertEqual(timer.typedState, .running)

        let transitioned = try await service.reconcileOnForeground(session: session)

        XCTAssertTrue(transitioned.isEmpty)
        XCTAssertEqual(timer.typedState, .running)
    }

    func test_reconcile_leavesPausedAndCancelledTimersUntouched() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let paused = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Paused timer",
            durationSec: 300,
        )
        try await service.start(paused, on: session)
        try await service.pause(paused, on: session)
        XCTAssertEqual(paused.typedState, .paused)

        let cancelled = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Cancelled timer",
            durationSec: 300,
        )
        try await service.start(cancelled, on: session)
        try await service.cancel(cancelled, on: session)
        XCTAssertEqual(cancelled.typedState, .cancelled)

        let transitioned = try await service.reconcileOnForeground(session: session)

        XCTAssertTrue(transitioned.isEmpty, "non-running timers must not be reconciled")
        XCTAssertEqual(paused.typedState, .paused)
        XCTAssertEqual(cancelled.typedState, .cancelled)
    }

    func test_reconcile_handlesMixedTimerStatesInOnePass() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)

        // Overdue: should transition.
        let overdue = try timerRepo.createTimer(for: session, step: nil, label: "Overdue", durationSec: 30)
        try timerRepo.start(overdue, at: Date().addingTimeInterval(-90))

        // Running, not yet overdue: should stay running.
        let active = try timerRepo.createTimer(for: session, step: nil, label: "Active", durationSec: 600)
        try await service.start(active, on: session)

        // Already completed: must remain completed without re-marking.
        let alreadyDone = try timerRepo.createTimer(for: session, step: nil, label: "Done", durationSec: 60)
        try await service.start(alreadyDone, on: session)
        try await service.markCompleted(alreadyDone, on: session)
        let originalEndedAt = alreadyDone.endedAt

        let transitioned = try await service.reconcileOnForeground(session: session)
        XCTAssertEqual(transitioned.count, 1, "only the overdue running timer should transition")
        XCTAssertEqual(overdue.typedState, .completed)
        XCTAssertEqual(active.typedState, .running)
        XCTAssertEqual(alreadyDone.typedState, .completed)
        XCTAssertEqual(alreadyDone.endedAt, originalEndedAt, "completed timer's endedAt must not be touched")
    }

    func test_reconcile_purgesNotificationIdForCompletedTimer() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Backgrounded",
            durationSec: 120,
        )
        // Schedule via service.start so the notification id is registered
        // on the session before we back-date it.
        try await service.start(timer, on: session)
        XCTAssertEqual(session.localNotificationIdsArray.count, 1)
        timer.startedAt = Date().addingTimeInterval(-300)

        _ = try await service.reconcileOnForeground(session: session)
        XCTAssertEqual(timer.typedState, .completed)
        XCTAssertEqual(
            session.localNotificationIdsArray.count,
            0,
            "notification id for naturally-completed timer must be purged from the session",
        )
    }

    private func makeRecipePlan(household: HouseholdProfile) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Reconcile Test"
        plan.servings = 2
        plan.estimatedMinutes = 30
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try controller.save()
        return plan
    }
}

@MainActor
private final class RecordingNotificationCenter: UNUserNotificationCenterClient {
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

    func notificationSettings() async -> UNNotificationSettings {
        fatalError("not used in reconcile tests")
    }
    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool { true }
    func add(_ request: UNNotificationRequest) async throws { addedRequests.append(request) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}
