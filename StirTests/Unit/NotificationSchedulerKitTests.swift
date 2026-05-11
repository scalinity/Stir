// NotificationSchedulerKitTests
//
// Direct coverage for the shared kit extracted in SCA-173. Both
// `LeftoversFollowupScheduler` and `UseSoonScheduler` delegate to these
// helpers; the integration paths are still covered by the existing
// scheduler tests, but unit-testing the kit catches regressions in the
// shared primitives without spinning up a full scheduler.

import OSLog
import UserNotifications
import XCTest
@testable import Stir

@MainActor
final class NotificationSchedulerKitTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let logger = Logger(subsystem: "test.stir.kit", category: "test")

    override func setUp() {
        super.setUp()
        suiteName = "test.notification_kit.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - evaluateSuppression

    func test_evaluateSuppression_noState_returnsNil() {
        let history = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "kit.test.history",
            suppressionKey: "kit.test.suppression",
        )
        XCTAssertNil(NotificationSchedulerKit.evaluateSuppression(history: history, now: Date()))
    }

    func test_evaluateSuppression_unactionedStreak_returnsReason() {
        let history = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "kit.test.history",
            suppressionKey: "kit.test.suppression",
        )
        // Arm 14d suppression by recording 3 unactioned fires (the 3rd
        // arms when the prior 2 are unactioned per
        // NotificationHistoryStore.recordScheduled).
        history.recordScheduled(fireAt: Date().addingTimeInterval(-2 * 86_400))
        history.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        history.recordScheduled(fireAt: Date())
        XCTAssertNotNil(history.suppressedUntil, "test setup precondition")

        let result = NotificationSchedulerKit.evaluateSuppression(
            history: history,
            now: Date(),
        )
        guard case let .unactionedStreak(until) = result else {
            return XCTFail("expected .unactionedStreak, got \(String(describing: result))")
        }
        XCTAssertEqual(until, history.suppressedUntil)
    }

    func test_evaluateSuppression_weeklyCap_returnsReason() {
        let history = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "kit.test.history",
            suppressionKey: "kit.test.suppression",
        )
        // Two fires inside the 7d window, both actioned (so suppression
        // doesn't arm) — the weekly cap should still trigger.
        history.recordScheduled(fireAt: Date().addingTimeInterval(-3 * 86_400))
        history.markMostRecentActioned(at: Date())
        history.recordScheduled(fireAt: Date().addingTimeInterval(-1 * 86_400))
        history.markMostRecentActioned(at: Date())
        XCTAssertNil(history.suppressedUntil, "test setup: actioned fires shouldn't arm suppression")

        let result = NotificationSchedulerKit.evaluateSuppression(
            history: history,
            now: Date(),
        )
        guard case .weeklyCap = result else {
            return XCTFail("expected .weeklyCap, got \(String(describing: result))")
        }
    }

    func test_evaluateSuppression_suppressionExpired_returnsNil() {
        // Manually plant an EXPIRED suppression date and verify the kit
        // skips it (suppressedUntil > now is the gate; <= now is expired).
        defaults.set(Date().addingTimeInterval(-86_400), forKey: "kit.test.suppression")
        let history = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "kit.test.history",
            suppressionKey: "kit.test.suppression",
        )
        XCTAssertNil(NotificationSchedulerKit.evaluateSuppression(
            history: history,
            now: Date(),
        ))
    }

    // MARK: - pendingRequest

    func test_pendingRequest_noMatch_returnsNil() async {
        let center = SpyCenter()
        let result = await NotificationSchedulerKit.pendingRequest(
            identifier: "missing.id",
            center: center,
        )
        XCTAssertNil(result)
    }

    func test_pendingRequest_matchByIdentifier_returnsRequest() async {
        let center = SpyCenter()
        let request = UNNotificationRequest(
            identifier: "stir.test.id",
            content: UNMutableNotificationContent(),
            trigger: nil,
        )
        center.pending = [request]
        let result = await NotificationSchedulerKit.pendingRequest(
            identifier: "stir.test.id",
            center: center,
        )
        XCTAssertEqual(result?.identifier, "stir.test.id")
    }

    // MARK: - requestAuthorizationIfNeeded

    func test_requestAuthorizationIfNeeded_authorized_returnsTrue() async {
        let center = SpyCenter()
        center.authStatus = .authorized
        let ok = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: logger,
        )
        XCTAssertTrue(ok)
        XCTAssertFalse(center.requestAuthorizationCalled, "shouldn't prompt when already authorized")
    }

    func test_requestAuthorizationIfNeeded_provisional_returnsTrue() async {
        let center = SpyCenter()
        center.authStatus = .provisional
        let ok = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: logger,
        )
        XCTAssertTrue(ok)
    }

    func test_requestAuthorizationIfNeeded_denied_returnsFalse() async {
        let center = SpyCenter()
        center.authStatus = .denied
        let ok = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: logger,
        )
        XCTAssertFalse(ok)
        XCTAssertFalse(center.requestAuthorizationCalled, "denied means no prompt")
    }

    func test_requestAuthorizationIfNeeded_notDetermined_promptsAndReturnsResult() async {
        let center = SpyCenter()
        center.authStatus = .notDetermined
        center.authorizationResult = .success(true)
        let ok = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: logger,
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(center.requestAuthorizationCalled)
        XCTAssertEqual(center.requestAuthorizationOptions, [.alert, .sound])
    }

    func test_requestAuthorizationIfNeeded_notDetermined_throwsRecoversAsFalse() async {
        let center = SpyCenter()
        center.authStatus = .notDetermined
        center.authorizationResult = .failure(NSError(domain: "test", code: 1))
        let ok = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: logger,
        )
        XCTAssertFalse(ok, "throw is logged + returned as false (CA2-09)")
    }

    // MARK: - addWithRollback

    func test_addWithRollback_addSucceeds_returnsTrue_noRollback() async {
        let center = SpyCenter()
        let request = makeRequest("primary")
        let prior = makeRequest("prior")
        let added = await NotificationSchedulerKit.addWithRollback(
            request,
            prior: prior,
            center: center,
            logger: logger,
            contextLabel: "test",
        )
        XCTAssertTrue(added)
        XCTAssertEqual(center.addedIdentifiers, ["primary"], "only the primary add fires on success")
    }

    func test_addWithRollback_addFails_attemptsRollbackAndReturnsFalse() async {
        let center = SpyCenter()
        let request = makeRequest("primary")
        let prior = makeRequest("prior")
        // Fail the first add; succeed the second (rollback).
        center.addBehavior = .failOnce(NSError(domain: "test", code: 2))
        let added = await NotificationSchedulerKit.addWithRollback(
            request,
            prior: prior,
            center: center,
            logger: logger,
            contextLabel: "test",
        )
        XCTAssertFalse(added)
        XCTAssertEqual(center.addedIdentifiers, ["prior"], "rollback re-added the prior request")
    }

    func test_addWithRollback_noPriorRequest_skipsRollback() async {
        let center = SpyCenter()
        center.addBehavior = .alwaysFail(NSError(domain: "test", code: 3))
        let added = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            prior: nil,
            center: center,
            logger: logger,
            contextLabel: "test",
        )
        XCTAssertFalse(added)
        XCTAssertEqual(center.addedIdentifiers, [], "no prior == nothing to rollback to")
    }

    func test_addWithRollback_bothFailures_returnsFalse() async {
        let center = SpyCenter()
        center.addBehavior = .alwaysFail(NSError(domain: "test", code: 4))
        let added = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            prior: makeRequest("prior"),
            center: center,
            logger: logger,
            contextLabel: "test",
        )
        XCTAssertFalse(added)
        // Both attempted, both failed — kit logs the rollback failure
        // (CA2-08) and returns false.
        XCTAssertEqual(center.addCallCount, 2, "kit attempted both adds")
    }

    /// SCA-309: when both the primary add AND the rollback re-add throw,
    /// the kit invokes `onRollbackFailure` with the scheduler-supplied
    /// `schedulerId`, the failing notification `identifier`, and the
    /// rollback error's localized description. Schedulers wire this to
    /// `PostHogClient.capture(.notificationScheduleRollbackFailed, ...)`
    /// — without telemetry the "user has no pending follow-up at all"
    /// outcome was OSLog-only.
    func test_addWithRollback_bothFailures_invokesOnRollbackFailure_withSchedulerProperties() async {
        let center = SpyCenter()
        center.addBehavior = .alwaysFail(NSError(
            domain: "test",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "TestKit: simulated rollback fault"],
        ))
        let recorder = RollbackFailureRecorder()
        let added = await NotificationSchedulerKit.addWithRollback(
            makeRequest("stir.test.failing-id"),
            prior: makeRequest("prior"),
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: "test_scheduler",
            onRollbackFailure: { schedulerId, identifier, errorDescription in
                recorder.record(
                    schedulerId: schedulerId,
                    identifier: identifier,
                    errorDescription: errorDescription,
                )
            },
        )
        XCTAssertFalse(added, "both-failures branch returns false")

        XCTAssertEqual(recorder.invocationCount, 1, "onRollbackFailure fires exactly once on the both-failures branch")
        XCTAssertEqual(recorder.lastSchedulerId, "test_scheduler")
        XCTAssertEqual(recorder.lastIdentifier, "stir.test.failing-id")
        XCTAssertEqual(recorder.lastErrorDescription, "TestKit: simulated rollback fault")
    }

    /// SCA-309: when the primary add succeeds (or the rollback re-add
    /// succeeds), the failure callback must NOT fire — the both-
    /// failures branch is the only emit site.
    func test_addWithRollback_primarySuccess_doesNotInvokeOnRollbackFailure() async {
        let center = SpyCenter()
        let recorder = RollbackFailureRecorder()
        let added = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            prior: nil,
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: "test_scheduler",
            onRollbackFailure: { schedulerId, identifier, errorDescription in
                recorder.record(
                    schedulerId: schedulerId,
                    identifier: identifier,
                    errorDescription: errorDescription,
                )
            },
        )
        XCTAssertTrue(added)
        XCTAssertEqual(recorder.invocationCount, 0, "primary-success branch must not fire the rollback-failure callback")
    }

    // MARK: - Helpers

    private func makeRequest(_ id: String) -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: id,
            content: UNMutableNotificationContent(),
            trigger: nil,
        )
    }
}

/// SCA-309 helper: @MainActor-bound recorder for the rollback-failure
/// telemetry callback. The callback type is `@MainActor @Sendable`,
/// and the kit calls it synchronously from `addWithRollback`'s
/// `@MainActor` enum, so a class holding `var`s in @MainActor is
/// safe and lets the test read recorded data immediately after
/// `await addWithRollback(...)` returns — no Task hop required.
@MainActor
final class RollbackFailureRecorder {
    private(set) var invocationCount = 0
    private(set) var lastSchedulerId = ""
    private(set) var lastIdentifier = ""
    private(set) var lastErrorDescription = ""

    func record(schedulerId: String, identifier: String, errorDescription: String) {
        invocationCount += 1
        lastSchedulerId = schedulerId
        lastIdentifier = identifier
        lastErrorDescription = errorDescription
    }
}

// MARK: - SpyCenter

@MainActor
private final class SpyCenter: UserNotificationCenterClient {
    enum AddBehavior {
        case succeed
        /// Fail the first add, succeed any subsequent adds. Models the
        /// rollback path: primary add throws, rollback re-add succeeds.
        case failOnce(any Error)
        /// Fail every add — models the both-failures branch.
        case alwaysFail(any Error)
    }

    var pending: [UNNotificationRequest] = []
    var authStatus: UNAuthorizationStatus = .authorized
    var authorizationResult: Result<Bool, any Error> = .success(true)
    var addBehavior: AddBehavior = .succeed
    var addedIdentifiers: [String] = []
    var addCallCount = 0
    var requestAuthorizationCalled = false
    var requestAuthorizationOptions: UNAuthorizationOptions = []

    func add(_ request: UNNotificationRequest) async throws {
        addCallCount += 1
        switch addBehavior {
        case .succeed:
            addedIdentifiers.append(request.identifier)
        case let .failOnce(error):
            if addCallCount == 1 {
                throw error
            }
            addedIdentifiers.append(request.identifier)
        case let .alwaysFail(error):
            throw error
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        pending
    }

    func notificationSettings() async -> UNNotificationSettings {
        // We can't construct a real UNNotificationSettings (private init).
        // The kit only reads `.authorizationStatus`; tests that exercise the
        // auth path use a custom subclass below. For tests that don't go
        // through the auth path, this never runs.
        TestSettings(authorizationStatus: authStatus)
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCalled = true
        requestAuthorizationOptions = options
        return try authorizationResult.get()
    }
}

/// Stand-in for `UNNotificationSettings` so tests can drive the
/// `authorizationStatus` switch in the kit. UNNotificationSettings has no
/// public initializer, but its `authorizationStatus` is open-overridable —
/// subclassing here is the standard test pattern (same as TimerService's
/// notification tests).
private final class TestSettings: UNNotificationSettings, @unchecked Sendable {
    private let _authStatus: UNAuthorizationStatus

    init(authorizationStatus: UNAuthorizationStatus) {
        self._authStatus = authorizationStatus
        super.init(coder: NSKeyedUnarchiver(forReadingWith: Data()))!
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var authorizationStatus: UNAuthorizationStatus { _authStatus }
}
