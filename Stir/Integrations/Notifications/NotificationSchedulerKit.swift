// NotificationSchedulerKit
//
// Shared primitives for `LeftoversFollowupScheduler` (SCA-65) and
// `UseSoonScheduler` (SCA-64). Both schedulers previously duplicated four
// byte-identical patterns parameterized only by their notification identifier
// + telemetry event constant:
//
//   1. `pendingReminder()` — look up an existing scheduled request.
//   2. `requestAuthorizationIfNeeded()` — auth-status switch with logged
//      throw recovery (CA2-09).
//   3. Suppression preflight — suppressedUntil OR weekly-cap → emit
//      telemetry → bail. 12 lines, byte-identical.
//   4. Add with rollback — try add; on throw, attempt prior re-add with
//      logged failure when the rollback also fails (CA2-08).
//
// Pulled here so the next policy change (cap bump, new suppression reason,
// auth options swap) lands in one place. Each scheduler stays as a thin
// composition that wires its identifier, telemetry callbacks, repository
// queries, and content shape.
//
// Design notes:
//   * Pure helpers — no actor state of its own, no shared singletons. Each
//     scheduler still owns its own `NotificationHistoryStore` instance
//     (separate UserDefaults keys = isolated state per nudge).
//   * Telemetry stays in the schedulers (they own event names + per-event
//     property maps); the kit returns a typed `SuppressReason` and the
//     scheduler decides which event to fire. Keeps wire shapes unchanged.
//   * Logger is injected so kit logs route to the same OSLog category as
//     the calling scheduler (`leftovers_followup` / `use_soon`) instead of
//     a generic kit category.

import Foundation
import OSLog
import UserNotifications

/// Reasons a scheduling attempt should short-circuit before computing a fire
/// date. Schedulers map these to their own telemetry event names + log lines;
/// the kit only classifies, it doesn't emit.
enum NotificationSuppressReason: Sendable, Equatable {
    /// Active 14-day suppression armed by an unactioned streak. The suppression
    /// `until` date is included so the scheduler can format it for an OSLog
    /// breadcrumb.
    case unactionedStreak(until: Date)

    /// Weekly cap reached — `NotificationHistoryStore.weeklyCap` (currently 2)
    /// fires already in the trailing 7-day window.
    case weeklyCap
}

/// SCA-309: telemetry hook invoked when `addWithRollback` falls into the
/// "primary add threw AND rollback re-add also threw" branch — the
/// "user has no pending follow-up" outcome that OSLog alone hides.
/// Callers wire this to `PostHogClient.shared.capture(
/// .notificationScheduleRollbackFailed, ...)` with their scheduler-
/// specific properties. Sendable so the kit can keep its `@MainActor`
/// constraint without locking the caller in.
typealias NotificationRollbackFailureHandler = @MainActor @Sendable (
    _ schedulerId: String,
    _ identifier: String,
    _ errorDescription: String,
) -> Void

/// Static helpers shared by `LeftoversFollowupScheduler` + `UseSoonScheduler`.
/// All `@MainActor` because the two schedulers are `@MainActor` and the
/// `UNUserNotificationCenter` API surface is too.
@MainActor
enum NotificationSchedulerKit {
    /// Look up the currently-scheduled request for `identifier`, if any.
    /// Used pre-cancel so a rollback path can re-add the prior request.
    static func pendingRequest(
        identifier: String,
        center: any UserNotificationCenterClient,
    ) async -> UNNotificationRequest? {
        let pending = await center.pendingNotificationRequests()
        return pending.first { $0.identifier == identifier }
    }

    /// Resolve the system-level notification authorization. Returns `true` for
    /// authorized / provisional / ephemeral, `false` for denied. For
    /// `notDetermined`, prompts with `[.alert, .sound]` and returns the user's
    /// answer. CA2-09: a throw from `requestAuthorization` is logged at
    /// `warning` (not silently collapsed to `false`) and surfaced as `false` —
    /// the prompt itself counts as denial for the calling scheduler.
    static func requestAuthorizationIfNeeded(
        center: any UserNotificationCenterClient,
        logger: Logger,
    ) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.warning(
                    "requestAuthorization threw: \(error.localizedDescription, privacy: .private)",
                )
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Pure classifier: given the scheduler's history store + a clock instant,
    /// return the reason a fresh schedule should bail (or `nil` to proceed).
    /// Order matches the pre-extraction sequence: suppression first, weekly
    /// cap second. The caller emits its own telemetry + log line and returns.
    static func evaluateSuppression(
        history: NotificationHistoryStore,
        now: Date,
    ) -> NotificationSuppressReason? {
        if let suppressedUntil = history.suppressedUntil, suppressedUntil > now {
            return .unactionedStreak(until: suppressedUntil)
        }
        if history.firesInLastWeek(asOf: now).count >= NotificationHistoryStore.weeklyCap {
            return .weeklyCap
        }
        return nil
    }

    /// Try to add `request`; on throw, attempt to re-add `prior` (if any).
    /// Logs the initial add failure at `warning`; if the rollback re-add also
    /// throws, logs at `error` so the user-has-no-pending-followup case is
    /// observable rather than silently swallowed (CA2-08).
    ///
    /// SCA-309: the both-failures branch ALSO invokes `onRollbackFailure`
    /// (when supplied) so the scheduler can fire
    /// `notification_schedule_rollback_failed` telemetry — turning the
    /// dashboard-blind OSLog signal into an aggregable one. The callback
    /// receives the scheduler-supplied `schedulerId` (the same prefix
    /// used in the scheduler's own telemetry event names, e.g.
    /// `"leftovers_followup"` or `"use_soon"`), the notification
    /// `identifier` that failed to add, and the localized description
    /// of the rollback re-add error. Defaults to `nil` so test callers
    /// don't have to wire it.
    ///
    /// - Returns: `true` when `request` was successfully added; `false` when
    ///   the add threw (rollback may or may not have succeeded — the caller
    ///   doesn't currently branch on rollback success).
    ///
    /// SCA-315 S9: `@discardableResult` intentionally NOT applied. Both
    /// production callers (`UseSoonScheduler`, `LeftoversFollowupScheduler`)
    /// gate the post-add history/telemetry writes on this Bool, so a
    /// future caller that silently dropped the return value would
    /// emit stale `*_scheduled` events for an add that never landed.
    /// Forcing callers to acknowledge the Bool (via `let _ = await ...`
    /// or a branch) keeps the contract honest.
    static func addWithRollback(
        _ request: UNNotificationRequest,
        prior: UNNotificationRequest?,
        center: any UserNotificationCenterClient,
        logger: Logger,
        contextLabel: String,
        schedulerId: String = "",
        onRollbackFailure: NotificationRollbackFailureHandler? = nil,
    ) async -> Bool {
        do {
            try await center.add(request)
            return true
        } catch {
            logger.warning(
                "add failed: \(error.localizedDescription, privacy: .private) — rolling back",
            )
            if let prior {
                do {
                    try await center.add(prior)
                } catch {
                    logger.error(
                        "rollback re-add failed: \(error.localizedDescription, privacy: .private) — user has no pending \(contextLabel, privacy: .public)",
                    )
                    // SCA-309: surface the double-failure to telemetry.
                    // Description is the OS-supplied error string — no
                    // user content, satisfies ADR 0009.
                    onRollbackFailure?(
                        schedulerId,
                        request.identifier,
                        error.localizedDescription,
                    )
                }
            }
            return false
        }
    }
}
