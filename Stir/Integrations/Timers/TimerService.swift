// TimerService
//
// Step-4 Cook Mode timer coordination:
//   - Schedules UNUserNotificationRequest at the timer's natural fire
//     date so a backgrounded app still fires the "Step X done" chime.
//   - Records state transitions through CookTimerRepository so
//     CloudKit cross-device sync sees the authoritative Timer row.
//   - Resumes from persisted paused-remaining seconds, so leaving Cook
//     Mode or relaunching does not consume time while the timer is paused.
//
// Not in step 4 (deferred to step 7 with Widget Extension per Daniel's
// scope confirmation): ActivityKit Live Activities. Without a Widget
// Extension target we can't host the Live Activity UI, and wiring it
// up mid-step-4 blows a day on target plumbing orthogonal to the
// Cook Mode loop.
//
// Notification payload carries the timer UUID; on tap, the app
// deep-links to the corresponding Cook Mode step and marks the timer
// completed. The CookingSession's `localNotificationIdsArray` keeps
// the set of scheduled identifiers so step-7's Live Activity layer
// can correlate them to the same timer without double-scheduling.

import CoreData
import Foundation
import OSLog
import UserNotifications

@MainActor
final class TimerService {
    private let repository: CookTimerRepository
    private let sessionRepository: CookingSessionRepository
    private let notificationCenter: UNUserNotificationCenterClient
    /// Nil in unit tests that don't care about LiveActivity behavior;
    /// production always injects a real manager. Every state transition
    /// below (pause/resume/cancel/markCompleted) fans out so callers
    /// don't need to pair-up VM-side (CR1-18).
    ///
    /// IMPORTANT: must be the SAME instance the caller (CookModeViewModel)
    /// uses to `start(...)` activities. Otherwise pause/resume/cancel/
    /// markCompleted/reconcile fan-outs hit an empty in-memory dict and
    /// silently no-op, leaving the Lock Screen activity stuck on the
    /// original countdown (observed device-side 2026-05-03).
    private let liveActivityManager: LiveActivityManager?
    private let now: () -> Date

    /// Compatibility fallback for legacy paused rows without a persisted
    /// remaining-time snapshot. Current rows always use the saved seconds.
    private var pauseStartedAt: [UUID: Date] = [:]

    /// `liveActivityManager` is REQUIRED (no default value). CA2-9 fix:
    /// the prior default of `nil` made it possible for a caller to construct
    /// a TimerService that silently no-ops every Live Activity fan-out
    /// (pause/resume/cancel/markCompleted/reconcile) — visible only when a
    /// user notices their Lock Screen timer disappeared. Production code
    /// must pass the SAME instance the VM uses, or `nil` deliberately
    /// (unit tests that don't exercise the activity surface). Forcing the
    /// argument at every call site makes the intent reviewable.
    ///
    /// SCA-189 (review-CR2-C1 follow-up): `repository` and `sessionRepository`
    /// are also REQUIRED. The earlier nil-default + `?? Repository(controller: .shared)`
    /// fallback was the SCA-179 footgun — a test that constructed
    /// `TimerService(notificationCenter: …, liveActivityManager: nil)` got
    /// `.shared`-backed repos silently. Forcing explicit injection makes
    /// the controller-routing visible at every callsite; the bug class
    /// becomes a compile error instead of a runtime CoreData crash.
    init(
        repository: CookTimerRepository,
        sessionRepository: CookingSessionRepository,
        notificationCenter: UNUserNotificationCenterClient = DefaultUNUserNotificationCenter(),
        liveActivityManager: LiveActivityManager?,
        now: @escaping () -> Date = Date.init,
    ) {
        self.repository = repository
        self.sessionRepository = sessionRepository
        self.notificationCenter = notificationCenter
        self.liveActivityManager = liveActivityManager
        self.now = now
    }

    /// Frozen reference date for the existing countdown view. Derive it
    /// from the persisted snapshot so it remains valid after recreation.
    func pauseStartedAt(for timer: CookTimer) -> Date? {
        guard timer.typedState == .paused else { return nil }
        if let remaining = timer.pausedRemainingSeconds, let fireDate = timer.fireDate {
            return fireDate.addingTimeInterval(-TimeInterval(remaining))
        }
        guard let id = timer.id else { return nil }
        return pauseStartedAt[id]
    }

    // MARK: - Authorization

    /// Ask for notification permission once. Safe to call repeatedly —
    /// the system coalesces after the first prompt. Returns the
    /// authorization status after the request completes.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> UNAuthorizationStatus {
        let current = await notificationCenter.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return current.authorizationStatus
        case .denied:
            // User already said no — don't re-prompt. iOS silently drops
            // scheduled notifications when denied; timers still work
            // in-app, they just won't fire in the background.
            return .denied
        case .notDetermined:
            let granted = (try? await notificationCenter.requestAuthorization([.alert, .sound, .badge])) ?? false
            let updated = await notificationCenter.notificationSettings()
            Logger.ui.info("TimerService auth requested granted=\(granted, privacy: .public) status=\(updated.authorizationStatus.rawValue, privacy: .public)")
            return updated.authorizationStatus
        @unknown default:
            return current.authorizationStatus
        }
    }

    // MARK: - Timer lifecycle

    /// Start a pending timer. Persist running state and its notification
    /// identifier together, after the alarm has been accepted.
    func start(_ timer: CookTimer, on session: CookingSession) async throws {
        let startedAt = now()
        let fireDate = startedAt.addingTimeInterval(TimeInterval(timer.durationSec))
        do {
            try await scheduleNotification(for: timer, on: session, fireDate: fireDate) {
                try repository.start(timer, at: startedAt)
            }
        } catch {
            // Scheduling/save failure never leaves a running timer without
            // an alarm. A failed cancellation save leaves the original
            // pending state because the running transition was not committed.
            try? repository.cancel(timer, at: startedAt)
            throw error
        }
    }

    /// Persist the paused snapshot and identifier removal before removing
    /// the alarm, so a failed save leaves the running timer's alarm intact.
    func pause(_ timer: CookTimer, on session: CookingSession) async throws {
        guard timer.typedState == .running, let timerId = timer.id else { return }
        let pausedAt = now()
        let pausedRemaining = pausedRemainingSecondsSnapshot(for: timer, at: pausedAt)
        removeNotificationId(timerId, from: session)
        try repository.pause(timer, pausedRemainingSec: pausedRemaining)
        pauseStartedAt[timerId] = pausedAt
        cancelScheduledNotification(for: timerId)
        if let fire = timer.fireDate {
            await liveActivityManager?.update(
                timerId: timerId,
                fireDate: fire,
                pausedRemainingSec: pausedRemaining,
            )
        }
    }

    /// Resume from the saved remaining time, including after Cook Mode or
    /// the process has been recreated. Failed scheduling/save keeps paused
    /// state and its remaining-time snapshot intact.
    func resume(_ timer: CookTimer, on session: CookingSession) async throws {
        guard timer.typedState == .paused, let timerId = timer.id else { return }
        let resumedAt = now()
        let remaining = timer.pausedRemainingSeconds ?? max(
            0,
            Int((timer.fireDate ?? resumedAt).timeIntervalSince(pauseStartedAt[timerId] ?? resumedAt).rounded()),
        )
        let fireDate = resumedAt.addingTimeInterval(TimeInterval(remaining))
        let newStart = fireDate.addingTimeInterval(-TimeInterval(timer.durationSec))
        try await scheduleNotification(for: timer, on: session, fireDate: fireDate) {
            try repository.resume(timer, newStartedAt: newStart)
        }
        pauseStartedAt.removeValue(forKey: timerId)
        if timer.typedState == .completed {
            await liveActivityManager?.end(timerId: timerId, reason: .completed)
        } else {
            await liveActivityManager?.update(
                timerId: timerId,
                fireDate: fireDate,
                pausedRemainingSec: nil,
            )
        }
    }

    /// Cancel the persisted timer before removing its alarm. Notification
    /// removal cannot throw; a failed save therefore preserves both.
    func cancel(_ timer: CookTimer, on session: CookingSession) async throws {
        if let timerId = timer.id {
            removeNotificationId(timerId, from: session)
        }
        try repository.cancel(timer, at: now())
        if let timerId = timer.id {
            cancelScheduledNotification(for: timerId)
            pauseStartedAt.removeValue(forKey: timerId)
            await liveActivityManager?.end(timerId: timerId, reason: .cancelled)
        }
    }

    /// Mark naturally complete and remove any straggling alarm only after
    /// the state and identifier removal have been saved together.
    func markCompleted(_ timer: CookTimer, on session: CookingSession) async throws {
        if let timerId = timer.id {
            removeNotificationId(timerId, from: session)
        }
        try repository.markCompleted(timer, at: now())
        if let timerId = timer.id {
            cancelScheduledNotification(for: timerId)
            pauseStartedAt.removeValue(forKey: timerId)
            await liveActivityManager?.end(timerId: timerId, reason: .completed)
        }
    }

    // MARK: - Foreground reconciliation

    /// Called when the app foregrounds / Cook Mode re-appears. For every
    /// running timer whose fire date has passed while backgrounded, mark
    /// it completed. Returns the set of timers that just transitioned so
    /// the view model can flash the "Timer done" indicator.
    @discardableResult
    func reconcileOnForeground(session: CookingSession) async throws -> [CookTimer] {
        let currentDate = now()
        var transitioned: [CookTimer] = []
        for timer in repository.timers(for: session) {
            guard timer.typedState == .running, let fire = timer.fireDate, fire <= currentDate else { continue }
            if let timerId = timer.id { removeNotificationId(timerId, from: session) }
            try repository.markCompleted(timer, at: fire)
            transitioned.append(timer)
            if let timerId = timer.id {
                cancelScheduledNotification(for: timerId)
                await liveActivityManager?.end(timerId: timerId, reason: .completed)
            }
        }
        return transitioned
    }

    // MARK: - Private — notifications

    private func scheduleNotification(
        for timer: CookTimer,
        on session: CookingSession,
        fireDate: Date,
        persistTransition: () throws -> Void,
    ) async throws {
        guard let timerId = timer.id else { return }
        let delay = fireDate.timeIntervalSince(now())
        guard delay > 0 else {
            // A timer paused at zero completes in one save, without ever
            // committing a running state that has no backing alarm.
            removeNotificationId(timerId, from: session)
            try repository.markCompleted(timer, at: fireDate)
            cancelScheduledNotification(for: timerId)
            return
        }
        let label = timer.label ?? ""
        let content = UNMutableNotificationContent()
        content.title = label.isEmpty ? "Timer done" : label
        content.body = "Tap to return to your recipe."
        content.sound = .default
        content.userInfo = [
            TimerNotification.kindKey: TimerNotification.kindValue,
            "stir_timer_id": timerId.uuidString,
            "stir_session_id": session.id?.uuidString ?? "",
        ]
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(
            identifier: timerId.uuidString,
            content: content,
            trigger: trigger,
        )
        do {
            try await notificationCenter.add(request)
            addNotificationId(timerId, to: session)
            // The repository saves both edits on the same context. On a
            // save failure it rolls back to the pending/paused state and
            // the original session identifiers; remove the inserted alarm.
            try persistTransition()
        } catch {
            cancelScheduledNotification(for: timerId)
            Logger.ui.warning("TimerService schedule failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    private func cancelScheduledNotification(for timerId: UUID) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [timerId.uuidString])
    }

    private func addNotificationId(_ id: UUID, to session: CookingSession) {
        var ids = session.localNotificationIdsArray
        let asString = id.uuidString
        guard !ids.contains(asString) else { return }
        ids.append(asString)
        session.localNotificationIdsArray = ids
    }

    private func removeNotificationId(_ id: UUID, from session: CookingSession) {
        let asString = id.uuidString
        var ids = session.localNotificationIdsArray
        guard let idx = ids.firstIndex(of: asString) else { return }
        ids.remove(at: idx)
        session.localNotificationIdsArray = ids
    }

    /// Paused-remaining snapshot used by pause() to flush the static
    /// "2:14" into the Live Activity ContentState. Returns max(0, …)
    /// so a timer already past its fire date reads as 0, not negative.
    private func pausedRemainingSecondsSnapshot(for timer: CookTimer, at date: Date) -> Int {
        guard timer.typedState == .running,
              let fireDate = timer.fireDate else { return 0 }
        return max(0, Int(fireDate.timeIntervalSince(date).rounded()))
    }
}

// MARK: - Notification center abstraction (test seam)

/// Narrow protocol over UNUserNotificationCenter so tests can inject a
/// fake without touching real system state. Only exposes the methods
/// TimerService calls — adding more is fine, but don't leak the entire
/// UNUserNotificationCenter surface.
@MainActor
protocol UNUserNotificationCenterClient {
    func notificationSettings() async -> UNNotificationSettings
    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

/// Production adapter — forwards to the shared UNUserNotificationCenter.
@MainActor
struct DefaultUNUserNotificationCenter: UNUserNotificationCenterClient {
    func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }

    func requestAuthorization(_ options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

// MARK: - Payload classification

/// Inspect a delivered notification's userInfo to decide whether it was
/// scheduled by `TimerService` (so the foreground delegate can swap the
/// default Tri-tone for a softer in-app chime). The `stir_kind == "timer"`
/// marker is set in `scheduleNotification(for:)` alongside the timer +
/// session UUIDs.
enum TimerNotification {
    /// `userInfo` key on `UNNotificationRequest.content`. Public so the
    /// delegate doesn't duplicate the literal string.
    static let kindKey = "stir_kind"
    static let kindValue = "timer"

    static func isTimer(from userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo[kindKey] as? String) == kindValue
    }
}
