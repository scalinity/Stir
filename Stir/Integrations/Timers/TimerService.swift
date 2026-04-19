// TimerService
//
// Step-4 Cook Mode timer coordination:
//   - Schedules UNUserNotificationRequest at the timer's natural fire
//     date so a backgrounded app still fires the "Step X done" chime.
//   - Records state transitions through CookTimerRepository so
//     CloudKit cross-device sync sees the authoritative Timer row.
//   - Maintains in-memory pause bookkeeping (the spec §4.13 state enum
//     covers pause via a transition; the in-memory log tracks HOW LONG
//     the timer has been paused so resume can advance startedAt by
//     that amount, keeping `startedAt + durationSec == fireDate` the
//     single source of truth).
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

    /// In-memory map of timerId → pauseStartedAt. Populated on pause,
    /// drained on resume. Not persisted — the state machine on disk
    /// captures the WHAT; this captures the pending WHEN needed to
    /// recompute startedAt on resume. Survives the app's active
    /// lifetime; on cold launch, a paused timer just stays paused
    /// (its `startedAt` is the pre-pause baseline, which is the safe
    /// fallback).
    private var pauseStartedAt: [UUID: Date] = [:]

    init(
        repository: CookTimerRepository? = nil,
        sessionRepository: CookingSessionRepository? = nil,
        notificationCenter: UNUserNotificationCenterClient = DefaultUNUserNotificationCenter(),
    ) {
        self.repository = repository ?? CookTimerRepository()
        self.sessionRepository = sessionRepository ?? CookingSessionRepository()
        self.notificationCenter = notificationCenter
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

    /// Start a pending CookTimer. Transitions to running, schedules a
    /// local notification at startedAt + durationSec, and registers the
    /// notification id on the parent CookingSession.
    func start(_ timer: CookTimer, on session: CookingSession) async throws {
        let now = Date()
        try repository.start(timer, at: now)
        try await scheduleNotification(for: timer, on: session)
    }

    /// Pause a running timer. Cancels the scheduled notification (we'll
    /// re-schedule on resume with a new fire date). Records pause start
    /// in memory so `resume` can compute the pause duration.
    func pause(_ timer: CookTimer, on session: CookingSession) async throws {
        guard timer.typedState == .running, let timerId = timer.id else { return }
        pauseStartedAt[timerId] = Date()
        await cancelScheduledNotification(for: timerId)
        try repository.pause(timer)
        // Purge the notification id from the session's list — we'll
        // re-add it on resume. Keeps localNotificationIdsArray consistent
        // with what's actually scheduled in UNUserNotificationCenter.
        removeNotificationId(timerId, from: session)
    }

    /// Resume a paused timer. Advances startedAt by the paused duration
    /// so `startedAt + durationSec == fireDate` remains authoritative,
    /// then re-schedules the local notification.
    func resume(_ timer: CookTimer, on session: CookingSession) async throws {
        guard timer.typedState == .paused, let timerId = timer.id else { return }
        let resumedAt = Date()
        let pausedFor: TimeInterval = pauseStartedAt[timerId].map { resumedAt.timeIntervalSince($0) } ?? 0
        pauseStartedAt.removeValue(forKey: timerId)

        // Shift startedAt forward by pausedFor so the fire date moves
        // forward by the same amount.
        let originalStart = timer.startedAt ?? resumedAt
        let newStart = originalStart.addingTimeInterval(pausedFor)
        try repository.resume(timer, newStartedAt: newStart)
        try await scheduleNotification(for: timer, on: session)
    }

    /// Cancel (user-stopped). Removes scheduled notification, sets
    /// state=cancelled + endedAt=now.
    func cancel(_ timer: CookTimer, on session: CookingSession) async throws {
        if let timerId = timer.id {
            await cancelScheduledNotification(for: timerId)
            removeNotificationId(timerId, from: session)
            pauseStartedAt.removeValue(forKey: timerId)
        }
        try repository.cancel(timer)
    }

    /// Mark naturally complete (timer fired). Also removes any straggler
    /// notification that hadn't fired yet.
    func markCompleted(_ timer: CookTimer, on session: CookingSession) async throws {
        if let timerId = timer.id {
            await cancelScheduledNotification(for: timerId)
            removeNotificationId(timerId, from: session)
            pauseStartedAt.removeValue(forKey: timerId)
        }
        try repository.markCompleted(timer)
    }

    // MARK: - Foreground reconciliation

    /// Called when the app foregrounds / Cook Mode re-appears. For every
    /// running timer whose fire date has passed while backgrounded, mark
    /// it completed. Returns the set of timers that just transitioned so
    /// the view model can flash the "Timer done" indicator.
    @discardableResult
    func reconcileOnForeground(session: CookingSession) async throws -> [CookTimer] {
        let now = Date()
        var transitioned: [CookTimer] = []
        for timer in repository.timers(for: session) {
            guard timer.typedState == .running, let fire = timer.fireDate, fire <= now else { continue }
            try repository.markCompleted(timer, at: fire)
            transitioned.append(timer)
            if let timerId = timer.id {
                removeNotificationId(timerId, from: session)
            }
        }
        if !transitioned.isEmpty {
            // Save again to flush the session's localNotificationIds
            // edits if any transitioned-ids were removed.
            try sessionRepository.advanceStep(session, to: Int(session.currentStepIndex))
        }
        return transitioned
    }

    // MARK: - Private — notifications

    private func scheduleNotification(for timer: CookTimer, on session: CookingSession) async throws {
        guard let timerId = timer.id, let fireDate = timer.fireDate else { return }
        let delay = fireDate.timeIntervalSinceNow
        guard delay > 0 else {
            // Already overdue — skip scheduling, just mark complete
            // on the next reconcile path.
            return
        }
        let label = timer.label ?? ""
        let content = UNMutableNotificationContent()
        content.title = label.isEmpty ? "Timer done" : label
        content.body = "Tap to return to your recipe."
        content.sound = .default
        content.userInfo = [
            "stir_kind": "timer",
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
        } catch {
            Logger.ui.warning("TimerService schedule failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        addNotificationId(timerId, to: session)
    }

    private func cancelScheduledNotification(for timerId: UUID) async {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [timerId.uuidString])
    }

    private func addNotificationId(_ id: UUID, to session: CookingSession) {
        var ids = session.localNotificationIdsArray
        let asString = id.uuidString
        if !ids.contains(asString) {
            ids.append(asString)
            session.localNotificationIdsArray = ids
        }
    }

    private func removeNotificationId(_ id: UUID, from session: CookingSession) {
        let asString = id.uuidString
        let ids = session.localNotificationIdsArray.filter { $0 != asString }
        session.localNotificationIdsArray = ids
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
