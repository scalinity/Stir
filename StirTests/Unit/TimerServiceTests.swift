// TimerServiceTests
//
// Exercises start/pause/resume/cancel state transitions + the pause-
// duration arithmetic that keeps `startedAt + durationSec == fireDate`
// authoritative after a resume.
//
// Uses an in-memory PersistenceController so transitions round-trip
// through Core Data (mirrors the real production save path). Injects a
// RecordingNotificationCenter so scheduling side-effects are visible to
// the test without hitting the real UN permission prompt.

import CoreData
import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class TimerServiceTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var notificationCenter: RecordingNotificationCenter!
    private var service: TimerService!
    private var timerRepo: CookTimerRepository!
    private var sessionRepo: CookingSessionRepository!
    private var testNow = Date(timeIntervalSince1970: 1_700_000_000)
    private var failNextSave = false

    private enum InjectedFailure: Error { case save }

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household)
        notificationCenter = RecordingNotificationCenter()
        timerRepo = CookTimerRepository(controller: controller) { [unowned self] in
            if failNextSave {
                failNextSave = false
                throw InjectedFailure.save
            }
            try controller.save()
        }
        sessionRepo = CookingSessionRepository(controller: controller)
        service = TimerService(
            repository: timerRepo,
            sessionRepository: sessionRepo,
            notificationCenter: notificationCenter,
            liveActivityManager: nil,
            now: { [unowned self] in testNow },
        )
    }

    // MARK: - Start

    func test_start_transitionsToRunningAndSchedulesNotification() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Simmer",
            durationSec: 600,
        )
        XCTAssertEqual(timer.typedState, .pending)

        try await service.start(timer, on: session)

        XCTAssertEqual(timer.typedState, .running)
        XCTAssertNotNil(timer.startedAt)
        XCTAssertEqual(notificationCenter.addedRequests.count, 1)
        XCTAssertEqual(session.localNotificationIdsArray.count, 1)
    }

    // MARK: - Pause / resume

    func test_pauseThenResume_shiftsStartedAtForwardByPausedDuration() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Bake", durationSec: 900)
        try await service.start(timer, on: session)
        let originalStart = try XCTUnwrap(timer.startedAt)
        testNow.addTimeInterval(120)
        try await service.pause(timer, on: session)
        XCTAssertEqual(timer.pausedRemainingSeconds, 780)

        testNow.addTimeInterval(600)
        try await service.resume(timer, on: session)

        XCTAssertEqual(timer.typedState, .running)
        XCTAssertEqual(try XCTUnwrap(timer.startedAt).timeIntervalSince(originalStart), 600, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(timer.fireDate).timeIntervalSince(testNow), 780, accuracy: 0.001)
        XCTAssertNil(timer.pausedRemainingSeconds)
    }

    func test_resumeAfterServiceRecreation_preservesSavedRemainingTimeAndPausedDisplay() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Boil", durationSec: 600)
        try await service.start(timer, on: session)
        testNow.addTimeInterval(300)
        try await service.pause(timer, on: session)
        controller.viewContext.refresh(timer, mergeChanges: false)
        testNow.addTimeInterval(900) // The original fire date has passed.
        service = TimerService(
            repository: timerRepo,
            sessionRepository: sessionRepo,
            notificationCenter: notificationCenter,
            liveActivityManager: nil,
            now: { [unowned self] in testNow },
        )

        let pausedReference = try XCTUnwrap(service.pauseStartedAt(for: timer))
        XCTAssertEqual(try XCTUnwrap(timer.fireDate).timeIntervalSince(pausedReference), 300, accuracy: 0.001)
        try await service.resume(timer, on: session)

        XCTAssertEqual(timer.typedState, .running)
        XCTAssertEqual(try XCTUnwrap(timer.fireDate).timeIntervalSince(testNow), 300, accuracy: 0.001)
        let request = try XCTUnwrap(notificationCenter.pendingRequests[timer.id!.uuidString])
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, 300, accuracy: 0.001)
        XCTAssertEqual(session.localNotificationIdsArray, [timer.id!.uuidString])
    }

    func test_resumeAtZeroRemaining_completesWithoutAnotherAlarm() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Done", durationSec: 60)
        try await service.start(timer, on: session)
        testNow.addTimeInterval(60)
        try await service.pause(timer, on: session)
        XCTAssertEqual(timer.pausedRemainingSeconds, 0)
        testNow.addTimeInterval(120)

        try await service.resume(timer, on: session)

        XCTAssertEqual(timer.typedState, .completed)
        XCTAssertEqual(notificationCenter.addedRequests.count, 1)
        XCTAssertTrue(notificationCenter.pendingRequests.isEmpty)
        XCTAssertTrue(session.localNotificationIdsArray.isEmpty)
    }

    func test_pauseThenResume_reschedulesNotificationAfterPause() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Boil",
            durationSec: 300,
        )
        try await service.start(timer, on: session)
        XCTAssertEqual(notificationCenter.addedRequests.count, 1)

        try await service.pause(timer, on: session)
        XCTAssertEqual(notificationCenter.removedIdentifiers.count, 1)

        try await service.resume(timer, on: session)
        XCTAssertEqual(notificationCenter.addedRequests.count, 2)  // original + re-scheduled
    }

    // MARK: - Cancel

    func test_cancel_transitionsToCancelledAndRemovesNotification() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Rest",
            durationSec: 180,
        )
        try await service.start(timer, on: session)

        try await service.cancel(timer, on: session)

        XCTAssertEqual(timer.typedState, .cancelled)
        XCTAssertNotNil(timer.endedAt)
        XCTAssertEqual(notificationCenter.removedIdentifiers.count, 1)
        XCTAssertEqual(session.localNotificationIdsArray.count, 0)
    }

    // MARK: - Mark completed

    func test_markCompleted_transitionsToCompletedAndRemovesScheduledNotification() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Toast",
            durationSec: 120,
        )
        try await service.start(timer, on: session)

        try await service.markCompleted(timer, on: session)

        XCTAssertEqual(timer.typedState, .completed)
        XCTAssertNotNil(timer.endedAt)
        XCTAssertEqual(session.localNotificationIdsArray.count, 0)
    }

    // MARK: - Notification and persistence failures

    func test_startNotificationFailure_cancelsTimerWithoutLeavingAnAlarm() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Start", durationSec: 600)
        notificationCenter.failNextAdd = true
        do {
            try await service.start(timer, on: session)
            XCTFail("Expected notification insertion to fail")
        } catch {}

        controller.viewContext.refresh(timer, mergeChanges: false)
        controller.viewContext.refresh(session, mergeChanges: false)
        XCTAssertEqual(timer.typedState, .cancelled)
        XCTAssertTrue(notificationCenter.pendingRequests.isEmpty)
        XCTAssertTrue(session.localNotificationIdsArray.isEmpty)
    }

    func test_startSaveFailure_removesInsertedAlarmAndDoesNotPersistRunningState() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Start", durationSec: 600)
        notificationCenter.onAdd = { [unowned self] in failNextSave = true }
        do {
            try await service.start(timer, on: session)
            XCTFail("Expected the post-add save to fail")
        } catch {}

        controller.viewContext.refresh(timer, mergeChanges: false)
        controller.viewContext.refresh(session, mergeChanges: false)
        XCTAssertEqual(notificationCenter.addedRequests.count, 1)
        XCTAssertEqual(timer.typedState, .cancelled)
        XCTAssertNil(timer.startedAt)
        XCTAssertTrue(notificationCenter.pendingRequests.isEmpty)
        XCTAssertTrue(session.localNotificationIdsArray.isEmpty)
    }

    func test_resumeNotificationFailure_preservesPersistedPauseAndRemainingTime() async throws {
        let (session, timer) = try await makePausedTimer()
        let priorStart = timer.startedAt
        notificationCenter.failNextAdd = true
        testNow.addTimeInterval(900)
        do {
            try await service.resume(timer, on: session)
            XCTFail("Expected notification insertion to fail")
        } catch {}

        controller.viewContext.refresh(timer, mergeChanges: false)
        controller.viewContext.refresh(session, mergeChanges: false)
        XCTAssertEqual(timer.typedState, .paused)
        XCTAssertEqual(timer.startedAt, priorStart)
        XCTAssertEqual(timer.pausedRemainingSeconds, 400)
        XCTAssertTrue(notificationCenter.pendingRequests.isEmpty)
        XCTAssertTrue(session.localNotificationIdsArray.isEmpty)
    }

    func test_resumeSaveFailure_removesInsertedAlarmAndRestoresPersistedPause() async throws {
        let (session, timer) = try await makePausedTimer()
        let priorStart = timer.startedAt
        notificationCenter.onAdd = { [unowned self] in failNextSave = true }
        testNow.addTimeInterval(900)
        do {
            try await service.resume(timer, on: session)
            XCTFail("Expected the post-add save to fail")
        } catch {}

        controller.viewContext.refresh(timer, mergeChanges: false)
        controller.viewContext.refresh(session, mergeChanges: false)
        XCTAssertEqual(notificationCenter.addedRequests.count, 2)
        XCTAssertEqual(timer.typedState, .paused)
        XCTAssertEqual(timer.startedAt, priorStart)
        XCTAssertEqual(timer.pausedRemainingSeconds, 400)
        XCTAssertTrue(notificationCenter.pendingRequests.isEmpty)
        XCTAssertTrue(session.localNotificationIdsArray.isEmpty)
    }

    func test_pauseSaveFailure_preservesRunningTimerAndAlarm() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Pause", durationSec: 600)
        try await service.start(timer, on: session)
        testNow.addTimeInterval(200)
        failNextSave = true
        do {
            try await service.pause(timer, on: session)
            XCTFail("Expected the pause save to fail")
        } catch {}

        controller.viewContext.refresh(timer, mergeChanges: false)
        controller.viewContext.refresh(session, mergeChanges: false)
        XCTAssertEqual(timer.typedState, .running)
        XCTAssertNil(timer.pausedRemainingSeconds)
        XCTAssertNil(service.pauseStartedAt(for: timer))
        XCTAssertNotNil(notificationCenter.pendingRequests[timer.id!.uuidString])
        XCTAssertEqual(session.localNotificationIdsArray, [timer.id!.uuidString])
    }

    func test_cancelSaveFailure_preservesRunningTimerAndAlarm() async throws {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Cancel", durationSec: 600)
        try await service.start(timer, on: session)
        failNextSave = true
        do {
            try await service.cancel(timer, on: session)
            XCTFail("Expected the cancellation save to fail")
        } catch {}

        controller.viewContext.refresh(timer, mergeChanges: false)
        controller.viewContext.refresh(session, mergeChanges: false)
        XCTAssertEqual(timer.typedState, .running)
        XCTAssertNotNil(notificationCenter.pendingRequests[timer.id!.uuidString])
        XCTAssertEqual(session.localNotificationIdsArray, [timer.id!.uuidString])
    }

    private func makePausedTimer() async throws -> (CookingSession, CookTimer) {
        let session = try sessionRepo.createSession(on: household, for: recipePlan, entryPoint: .solve)
        let timer = try timerRepo.createTimer(for: session, step: nil, label: "Resume", durationSec: 600)
        try await service.start(timer, on: session)
        testNow.addTimeInterval(200)
        try await service.pause(timer, on: session)
        return (session, timer)
    }

    // MARK: - Helpers

    private func makeRecipePlan(household: HouseholdProfile) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Timer Test"
        plan.servings = 2
        plan.estimatedMinutes = 30
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        try controller.save()
        return plan
    }
}

/// Records scheduled + removed notifications so tests can assert scheduling
/// behavior without touching the real UNUserNotificationCenter.
@MainActor
private final class RecordingNotificationCenter: UNUserNotificationCenterClient {
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []
    var pendingRequests: [String: UNNotificationRequest] = [:]
    var failNextAdd = false
    var onAdd: (() -> Void)?
    private enum InjectedFailure: Error { case add }

    func notificationSettings() async -> UNNotificationSettings {
        // Never reached because requestAuthorizationIfNeeded isn't
        // invoked in these tests (start goes directly through add).
        fatalError("RecordingNotificationCenter.notificationSettings shouldn't be reached")
    }

    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        if failNextAdd {
            failNextAdd = false
            throw InjectedFailure.add
        }
        addedRequests.append(request)
        pendingRequests[request.identifier] = request
        onAdd?()
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        for id in identifiers { pendingRequests.removeValue(forKey: id) }
    }
}
