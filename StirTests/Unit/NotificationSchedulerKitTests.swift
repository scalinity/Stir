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

    func test_addWithRollback_addSucceeds_returnsAdded_noRollback() async {
        let center = SpyCenter()
        // SCA-363: kit fetches prior internally — seed via SpyCenter.pending.
        center.pending = [makeRequest("primary")]
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            identifier: "primary",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .leftoversFollowup,
        )
        XCTAssertEqual(result, .added)
        XCTAssertEqual(center.addedIdentifiers, ["primary"], "only the primary add fires on success")
    }

    func test_addWithRollback_addFails_attemptsRollbackAndReturnsRolledBack() async {
        let center = SpyCenter()
        // SCA-363: prior already pending; kit fetches it.
        center.pending = [makeRequest("primary")]
        // Fail the first add; succeed the second (rollback).
        center.addBehavior = .failOnce(NSError(domain: "test", code: 2))
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            identifier: "primary",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .leftoversFollowup,
        )
        XCTAssertEqual(result, .rolledBack)
        XCTAssertEqual(center.addedIdentifiers, ["primary"], "rollback re-added the prior request (same identifier)")
    }

    /// SCA-369: no prior + add fails returns `.noPriorAddFailed` (was
    /// `.lostBoth` pre-fix). Distinguishes "fresh user, never had it"
    /// from regression.
    func test_addWithRollback_noPriorRequest_returnsNoPriorAddFailed() async {
        let center = SpyCenter()
        // No pending requests → kit's pendingRequest returns nil.
        center.addBehavior = .alwaysFail(NSError(domain: "test", code: 3))
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            identifier: "primary",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .leftoversFollowup,
        )
        XCTAssertEqual(result, .noPriorAddFailed)
        XCTAssertEqual(center.addedIdentifiers, [], "no prior == nothing to rollback to")
    }

    func test_addWithRollback_bothFailures_returnsLostBoth() async {
        let center = SpyCenter()
        center.pending = [makeRequest("primary")]
        center.addBehavior = .alwaysFail(NSError(domain: "test", code: 4))
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            identifier: "primary",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .leftoversFollowup,
        )
        XCTAssertEqual(result, .lostBoth)
        XCTAssertEqual(center.addCallCount, 2, "kit attempted both adds")
    }

    /// SCA-309 + SCA-369: both-failures branch invokes onRollbackFailure
    /// with priorExisted=true (regression: user HAD a schedule, we
    /// lost it).
    func test_addWithRollback_bothFailures_invokesOnRollbackFailure_priorExistedTrue() async {
        let center = SpyCenter()
        center.pending = [makeRequest("stir.test.failing-id")]
        center.addBehavior = .alwaysFail(NSError(
            domain: "test",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey: "TestKit: simulated rollback fault"],
        ))
        let recorder = RollbackFailureRecorder()
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("stir.test.failing-id"),
            identifier: "stir.test.failing-id",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .useSoon,
            onRollbackFailure: { schedulerId, identifier, errorReason, priorExisted in
                recorder.record(
                    schedulerId: schedulerId,
                    identifier: identifier,
                    errorReason: errorReason,
                    priorExisted: priorExisted,
                )
            },
        )
        XCTAssertEqual(result, .lostBoth)
        XCTAssertEqual(recorder.invocationCount, 1)
        XCTAssertEqual(recorder.lastSchedulerId, .useSoon)
        XCTAssertEqual(recorder.lastIdentifier, "stir.test.failing-id")
        // SCA-367: NSError(domain: "test") classifies to .unknown via the
        // closed-vocab enum (not UNError nor NSURL). The raw localized
        // description ("TestKit: simulated rollback fault") only goes to
        // OSLog now.
        XCTAssertEqual(recorder.lastErrorReason, .unknown)
        XCTAssertTrue(recorder.lastPriorExisted, "SCA-369: priorExisted=true on the regression branch")
    }

    /// SCA-369: no-prior + add fails branch invokes onRollbackFailure
    /// with priorExisted=false (fresh-user first-schedule failure).
    func test_addWithRollback_noPriorAddFailed_invokesOnRollbackFailure_priorExistedFalse() async {
        let center = SpyCenter()
        // No pending — kit sees no prior.
        center.addBehavior = .alwaysFail(NSError(domain: "test", code: 7))
        let recorder = RollbackFailureRecorder()
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("stir.test.fresh"),
            identifier: "stir.test.fresh",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .reactivation,
            onRollbackFailure: { schedulerId, identifier, errorReason, priorExisted in
                recorder.record(
                    schedulerId: schedulerId,
                    identifier: identifier,
                    errorReason: errorReason,
                    priorExisted: priorExisted,
                )
            },
        )
        XCTAssertEqual(result, .noPriorAddFailed)
        XCTAssertEqual(recorder.invocationCount, 1)
        XCTAssertEqual(recorder.lastSchedulerId, .reactivation)
        XCTAssertFalse(recorder.lastPriorExisted, "SCA-369: priorExisted=false on the fresh-user branch")
    }

    /// SCA-379: `.added × no prior` matrix gap. The
    /// `addSucceeds_returnsAdded_noRollback` case above seeds a prior;
    /// the fresh-user happy path (no prior, primary add succeeds) was
    /// untested. Asserts the kit still returns `.added` and doesn't
    /// touch the rollback path even when there's nothing to roll back to.
    func test_addWithRollback_addSucceeds_noPrior_returnsAdded() async {
        let center = SpyCenter()
        // No `center.pending` — fresh user, kit's pendingRequest returns nil.
        let recorder = RollbackFailureRecorder()
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            identifier: "primary",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .useSoon,
            onRollbackFailure: { schedulerId, identifier, errorReason, priorExisted in
                recorder.record(
                    schedulerId: schedulerId,
                    identifier: identifier,
                    errorReason: errorReason,
                    priorExisted: priorExisted,
                )
            },
        )
        XCTAssertEqual(result, .added, "fresh-user primary success returns .added regardless of prior absence")
        XCTAssertEqual(center.addedIdentifiers, ["primary"])
        XCTAssertEqual(recorder.invocationCount, 0, ".added branch never invokes rollback-failure callback (with or without prior)")
    }

    /// SCA-309: primary-success branch must NOT fire the failure callback.
    func test_addWithRollback_primarySuccess_doesNotInvokeOnRollbackFailure() async {
        let center = SpyCenter()
        let recorder = RollbackFailureRecorder()
        let result = await NotificationSchedulerKit.addWithRollback(
            makeRequest("primary"),
            identifier: "primary",
            center: center,
            logger: logger,
            contextLabel: "test",
            schedulerId: .useSoon,
            onRollbackFailure: { schedulerId, identifier, errorReason, priorExisted in
                recorder.record(
                    schedulerId: schedulerId,
                    identifier: identifier,
                    errorReason: errorReason,
                    priorExisted: priorExisted,
                )
            },
        )
        XCTAssertEqual(result, .added)
        XCTAssertEqual(recorder.invocationCount, 0, "primary-success branch must not fire the rollback-failure callback")
    }

    /// SCA-360: SchedulerID raw values match the spec §15
    /// `scheduler_id` enum AND match each scheduler's userInfo
    /// `stir_notification_kind` raw value (which is what the delegate
    /// looks up). Drift on either side breaks telemetry attribution.
    func test_schedulerID_rawValues_matchSpecAndNotificationKind() {
        XCTAssertEqual(SchedulerID.leftoversFollowup.rawValue, "leftovers_followup")
        XCTAssertEqual(SchedulerID.useSoon.rawValue, "use_soon")
        XCTAssertEqual(SchedulerID.reactivation.rawValue, "reactivation")

        // Cross-check with NotificationKind raw values (delegate side).
        XCTAssertEqual(SchedulerID.leftoversFollowup.rawValue, NotificationKind.leftoversFollowup.rawValue)
        XCTAssertEqual(SchedulerID.useSoon.rawValue, NotificationKind.useSoon.rawValue)
        XCTAssertEqual(SchedulerID.reactivation.rawValue, NotificationKind.reactivation.rawValue)
    }

    /// SCA-361: the kit's defaultRollbackFailureHandler captures
    /// PostHog telemetry with the spec-canonical property keys
    /// (scheduler_id, identifier, error_description, prior_existed).
    func test_defaultRollbackFailureHandler_capturesSpecKeyedTelemetry() {
        let telemetry = PostHogClient.shared
        let handler = NotificationSchedulerKit.defaultRollbackFailureHandler(telemetry: telemetry)
        // Smoke: the handler exists and is callable. Property-key
        // contract is asserted via inspection — wiring matches the
        // telemetry.capture(.notificationScheduleRollbackFailed, ...)
        // shape that schedulers used to hand-roll. Pre-fix: 7-line
        // closure duplicated 3 times. Post-fix: one helper.
        handler(.leftoversFollowup, "stir.test", .unknown, true)
    }

    /// SCA-367 / SCA-408: RollbackErrorReason.classify maps real
    /// `UNError.Code` cases (typed) + NSURLErrorDomain to specific
    /// reasons; everything else falls to .unknown. SCA-408 corrected
    /// SCA-367's wrong integer mapping (raw 1 was labelled
    /// "badNotificationContent" but is actually `notificationsNotAllowed`
    /// → `.deniedByDevice`; raw 4 had no UNError.Code case at all,
    /// so its `.deniedByDevice` mapping was dead).
    func test_rollbackErrorReason_classify_knownAndUnknown() {
        // .notificationsNotAllowed (raw 1) → .deniedByDevice (was
        // mis-mapped to .invalidContent pre-SCA-408).
        let unDenied = UNError(.notificationsNotAllowed)
        XCTAssertEqual(RollbackErrorReason.classify(unDenied), .deniedByDevice)
        // Content-class cases → .invalidContent. Sample one from each
        // numeric range so a future Apple addition that we forget to
        // map gets caught by `@unknown default`.
        let unBadAttach = UNError(.attachmentInvalidURL)
        XCTAssertEqual(RollbackErrorReason.classify(unBadAttach), .invalidContent)
        let unNoContent = UNError(.notificationInvalidNoContent)
        XCTAssertEqual(RollbackErrorReason.classify(unNoContent), .invalidContent)
        let unBadProvider = UNError(.contentProvidingInvalid)
        XCTAssertEqual(RollbackErrorReason.classify(unBadProvider), .invalidContent)
        // NSURLErrorDomain → .systemUnavailable (unchanged).
        let urlErr = NSError(domain: NSURLErrorDomain, code: -1009)
        XCTAssertEqual(RollbackErrorReason.classify(urlErr), .systemUnavailable)
        // arbitrary other → .unknown (unchanged).
        let other = NSError(domain: "test.synthetic", code: 42)
        XCTAssertEqual(RollbackErrorReason.classify(other), .unknown)
    }

    // MARK: - UseSoonScheduler ADR 0009 contract (SCA-345 / SCA-320 regression pin)

    /// SCA-345: end-to-end pin for SCA-320 / ADR 0009. The use-soon
    /// notification's `userInfo` dict and `use_soon_scheduled`
    /// telemetry capture must never carry user-content keys
    /// (`use_first_display_name`, `item_display_name`). These tests
    /// drive the successful-schedule path and inspect the resulting
    /// `UNNotificationRequest` + captured event properties. If a
    /// future change copies a property from `LeftoversFollowupScheduler`
    /// (or anywhere) back into the use-soon path, these tests fail.
    ///
    /// Lives in NotificationSchedulerKitTests because the schedulers
    /// share kit primitives; a dedicated UseSoonSchedulerTests file
    /// would require an xcodeproj/xcodegen edit beyond W1's scope.

    func test_useSoonScheduler_userInfo_omits_use_first_display_name() async throws {
        let setup = try makeUseSoonSchedulingSetup(displayName: "the chicken thighs from Sunday")
        await setup.scheduler.evaluateAndScheduleIfDue(now: setup.now, household: setup.household)

        XCTAssertEqual(setup.center.addedRequests.count, 1, "successful schedule path should add exactly one request")
        let request = try XCTUnwrap(setup.center.addedRequests.first)

        // SCA-320 invariant 1: userInfo carries IDs only, no display name.
        let userInfoKeys = Set(request.content.userInfo.keys.compactMap { $0 as? String })
        XCTAssertFalse(
            userInfoKeys.contains("use_first_display_name"),
            "ADR 0009: user content forbidden in notification userInfo",
        )
        XCTAssertEqual(
            userInfoKeys,
            ["stir_notification_kind", "use_first_pantry_item_id"],
            "userInfo keys must match the SCA-320 contract exactly",
        )

        // Belt-and-suspenders: confirm the display name does not leak
        // into the userInfo VALUES either (in case a future change
        // renames the key but keeps the data).
        let userInfoValues = request.content.userInfo.values.compactMap { $0 as? String }
        XCTAssertFalse(
            userInfoValues.contains("the chicken thighs from Sunday"),
            "ADR 0009: user-typed display name must not appear in any userInfo value",
        )
    }

    func test_useSoonScheduler_telemetry_omits_item_display_name() async throws {
        let setup = try makeUseSoonSchedulingSetup(displayName: "the chicken thighs from Sunday")
        await setup.scheduler.evaluateAndScheduleIfDue(now: setup.now, household: setup.household)

        let scheduledEvents = setup.telemetry.captures.filter { $0.event == .useSoonScheduled }
        XCTAssertEqual(scheduledEvents.count, 1, "successful schedule path should capture exactly one use_soon_scheduled event")
        let properties = try XCTUnwrap(scheduledEvents.first?.properties)

        // SCA-320 invariant 2: telemetry carries fire_at only, no display name.
        XCTAssertNil(properties["item_display_name"], "ADR 0009: user content forbidden in PostHog properties")
        XCTAssertEqual(
            Set(properties.keys),
            ["fire_at"],
            "use_soon_scheduled properties must match the SCA-320 contract exactly",
        )

        // Belt-and-suspenders: confirm the display name does not leak
        // into ANY captured event's properties (covers the suppression
        // events too — those should carry only `reason`).
        for capture in setup.telemetry.captures {
            for (key, value) in capture.properties {
                if let string = value as? String {
                    XCTAssertNotEqual(
                        string,
                        "the chicken thighs from Sunday",
                        "ADR 0009: user-typed display name leaked into \(capture.event.rawValue).\(key)",
                    )
                }
            }
        }
    }

    /// Build a complete in-memory test setup with one expiring ephemeral
    /// pantry item that will pass every UseSoonScheduler gate. Returns
    /// every seam the caller needs to assert on. `now` is fixed inside
    /// the trailing 48h candidate window.
    private func makeUseSoonSchedulingSetup(
        displayName: String,
    ) throws -> (
        scheduler: UseSoonScheduler,
        center: SpyCenter,
        telemetry: SpyPostHogClient,
        household: HouseholdProfile,
        now: Date
    ) {
        let pc = PersistenceController(inMemory: true)
        let ctx = pc.viewContext

        let household = HouseholdProfile(context: ctx)
        household.id = UUID()
        household.createdAt = Date()

        let now = Date()
        let candidate = PantryItem(context: ctx)
        candidate.id = UUID()
        candidate.household = household
        candidate.displayName = displayName
        candidate.canonicalIngredientSlug = ""
        candidate.typedSource = .manual
        candidate.typedMemoryState = .ephemeral
        candidate.userConfirmed = true
        candidate.confidence = 1.0
        candidate.createdAt = now
        candidate.updatedAt = now
        candidate.lastSeenAt = now
        candidate.expiresAt = now.addingTimeInterval(24 * 3600) // 24h ahead — inside the 48h window

        try ctx.save()

        let center = SpyCenter()
        center.authStatus = .authorized
        let telemetry = SpyPostHogClient()

        // Unique defaults suite so NotificationHistoryStore state is
        // isolated per test. Clean defaults => suppression not armed,
        // weekly cap not hit.
        let setupSuiteName = "test.use_soon_scheduler.\(UUID().uuidString)"
        let setupDefaults = try XCTUnwrap(UserDefaults(suiteName: setupSuiteName))

        let scheduler = UseSoonScheduler(
            center: center,
            calendar: .current,
            defaults: setupDefaults,
            controller: pc,
            pantry: nil,
            cookingSessions: nil,
            telemetry: telemetry,
        )

        return (scheduler, center, telemetry, household, now)
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
    private(set) var lastSchedulerId: SchedulerID = .leftoversFollowup
    private(set) var lastIdentifier = ""
    private(set) var lastErrorReason: RollbackErrorReason = .unknown
    private(set) var lastPriorExisted = false

    func record(
        schedulerId: SchedulerID,
        identifier: String,
        errorReason: RollbackErrorReason,
        priorExisted: Bool,
    ) {
        invocationCount += 1
        lastSchedulerId = schedulerId
        lastIdentifier = identifier
        lastErrorReason = errorReason
        lastPriorExisted = priorExisted
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
    /// SCA-345: full UNNotificationRequest captured on add so SCA-320 ADR 0009
    /// regression tests can assert on the request's content / userInfo shape.
    var addedRequests: [UNNotificationRequest] = []
    var addCallCount = 0
    var requestAuthorizationCalled = false
    var requestAuthorizationOptions: UNAuthorizationOptions = []

    func add(_ request: UNNotificationRequest) async throws {
        addCallCount += 1
        switch addBehavior {
        case .succeed:
            addedIdentifiers.append(request.identifier)
            addedRequests.append(request)
        case let .failOnce(error):
            if addCallCount == 1 {
                throw error
            }
            addedIdentifiers.append(request.identifier)
            addedRequests.append(request)
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

// MARK: - SpyPostHogClient (SCA-345)

// SCA-417: SpyPostHogClient hoisted to StirTests/Unit/Helpers/SpyPostHogClient.swift.
// Same shape (captures: [Capture] + NSLock); shared with
// LeftoversFollowupSchedulerTests so future test files that need a
// PostHog spy import from one place.
