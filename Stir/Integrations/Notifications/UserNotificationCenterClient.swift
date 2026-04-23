// UserNotificationCenterClient
//
// Protocol seam over the narrow slice of `UNUserNotificationCenter` that
// Stir's notification schedulers + delegate actually call. Exists so
// ReactivationScheduler, TrialReminderScheduler, and
// StirNotificationDelegate can inject a mock in tests instead of
// reaching at `UNUserNotificationCenter.current()` (unmockable global).
//
// Production paths keep using `.current()` via the protocol-conforming
// extension below — the seam is zero-cost for non-test callers.
//
// Same pattern as `TimerService`'s `UNUserNotificationCenterClient`
// (TimerService.swift:263-268). If the two pattern-wrappers diverge
// further, unify into one shared helper.

import Foundation
import UserNotifications

/// Narrow slice of UNUserNotificationCenter used by
/// ReactivationScheduler / TrialReminderScheduler /
/// StirNotificationDelegate. Every production callsite funnels through
/// this so tests can inject a spy.
@MainActor
protocol UserNotificationCenterClient: AnyObject {
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func notificationSettings() async -> UNNotificationSettings
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

// Production-path conformance. UNUserNotificationCenter already exposes
// the five methods above with the exact signatures, so the conformance
// is declaration-only.
extension UNUserNotificationCenter: UserNotificationCenterClient {}
