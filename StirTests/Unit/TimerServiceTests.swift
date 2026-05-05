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
        let timer = try timerRepo.createTimer(
            for: session,
            step: nil,
            label: "Bake",
            durationSec: 900,
        )
        try await service.start(timer, on: session)
        let originalStart = timer.startedAt!

        // Hold paused for ~0.12s so the assertion can see a non-zero shift
        // without slowing CI significantly.
        try await service.pause(timer, on: session)
        XCTAssertEqual(timer.typedState, .paused)
        try await Task.sleep(for: .milliseconds(120))

        try await service.resume(timer, on: session)
        XCTAssertEqual(timer.typedState, .running)

        let newStart = timer.startedAt!
        let pausedDuration = newStart.timeIntervalSince(originalStart)
        // Pause duration should be roughly 120ms (allow wide tolerance
        // for scheduler jitter — this test asserts the SIGN + rough
        // MAGNITUDE, not microsecond precision).
        XCTAssertGreaterThan(pausedDuration, 0.08)
        XCTAssertLessThan(pausedDuration, 2.0)
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

    func notificationSettings() async -> UNNotificationSettings {
        // Never reached because requestAuthorizationIfNeeded isn't
        // invoked in these tests (start goes directly through add).
        fatalError("RecordingNotificationCenter.notificationSettings shouldn't be reached")
    }

    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        addedRequests.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
    }
}
