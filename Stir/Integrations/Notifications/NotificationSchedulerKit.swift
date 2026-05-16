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

/// SCA-360: typed scheduler identifier. Replaces the prior
/// stringly-typed `schedulerId: String = ""` parameter on
/// `addWithRollback` — the empty default would silently produce a
/// malformed `notification_schedule_rollback_failed` telemetry property
/// if a future caller forgot it. The raw values match the spec §15
/// `scheduler_id` enum AND `NotificationKind`'s rawValues.
///
/// SCA-401: collapse the parallel enum into a typealias to
/// `NotificationKind`. The two enums had identical cases + rawValues
/// but no compile-time enforcement — a future rename of one without
/// the other would silently split dashboards. With the typealias
/// there is exactly one source of truth; the wire-contract literal
/// (`stir_notification_kind` userInfo key, audit_log
/// `scheduler_id` property, spec §15) all derive from
/// `NotificationKind`. Existing `schedulerId: SchedulerID`
/// parameter sites + `.useSoon` / `.leftoversFollowup` /
/// `.reactivation` references keep working — typealias preserves
/// source compatibility.
typealias SchedulerID = NotificationKind

/// SCA-367: closed-vocabulary error code passed to PostHog for the
/// `notification_schedule_rollback_failed` event. Pre-fix the kit
/// passed the raw `error.localizedDescription` (OS-supplied, not
/// contractually constrained by Apple) which would accumulate
/// device-state breadcrumbs in PostHog at indefinite retention. The
/// enum keeps the dashboard groupable + bounded; raw descriptions
/// stay in OSLog (where `.private` already redacts them).
enum RollbackErrorReason: String, Sendable, Equatable, CaseIterable {
    /// UNError.Code 1 (badNotificationContent) — payload was malformed
    /// (title/body too long, invalid trigger, etc.).
    case invalidContent
    /// UNError.Code 4 (notificationsNotAuthorized) — user revoked
    /// permission between the auth-check and the add.
    case deniedByDevice
    /// Network / system unavailable — usually transient. Maps any
    /// `Error` whose `(_ as NSError).domain` is `NSURLErrorDomain`.
    case systemUnavailable
    /// Catch-all: enum unknown to this version of the app. Includes
    /// undocumented UNError codes + any non-UN/NSURL error subclass.
    case unknown

    /// Map an arbitrary `Error` (the `add(_:)` throw) to a closed-
    /// vocab reason. Used at the kit's `addWithRollback` callback
    /// boundary so PostHog never sees raw `localizedDescription`
    /// strings.
    ///
    /// SCA-408: typed cast against `UNError` (Apple's typed enum
    /// wrapper around UNErrorDomain) instead of matching on raw
    /// `nsError.domain == "UNErrorDomain"` + integer codes. Pre-fix:
    /// SCA-367 mapped on `nsError.code == 1 → .invalidContent` and
    /// `nsError.code == 4 → .deniedByDevice`. UNError.Code raw 1 is
    /// actually `notificationsNotAllowed` (denied), and there is no
    /// `Code` case at raw 4 — so the previous mapping was inverted
    /// for code 1 and dead for code 4. The typed switch makes the
    /// real Apple case names visible + flags new cases at compile
    /// time via `@unknown default`.
    static func classify(_ error: Error) -> RollbackErrorReason {
        if let unError = error as? UNError {
            switch unError.code {
            case .notificationsNotAllowed:
                return .deniedByDevice
            case .attachmentInvalidURL,
                 .attachmentUnrecognizedType,
                 .attachmentInvalidFileSize,
                 .attachmentNotInDataStore,
                 .attachmentMoveIntoDataStoreFailed,
                 .attachmentCorrupt,
                 .notificationInvalidNoDate,
                 .notificationInvalidNoContent,
                 .contentProvidingObjectNotAllowed,
                 .contentProvidingInvalid,
                 .badgeInputInvalid:
                return .invalidContent
            @unknown default:
                return .unknown
            }
        }
        // URLSession errors keep the NSError-domain check; URLError isn't
        // tied to a specific framework boundary the kit owns.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .systemUnavailable
        }
        return .unknown
    }
}

/// SCA-309: telemetry hook invoked when `addWithRollback` falls into the
/// "primary add threw AND rollback re-add also threw" branch — the
/// "user has no pending follow-up" outcome that OSLog alone hides.
///
/// SCA-369: includes `priorExisted` so PostHog dashboards can tell apart
/// "fresh user, first-schedule failed" (priorExisted=false) from
/// "user had a schedule, we lost it" (priorExisted=true). Without this,
/// `notification_schedule_rollback_failed` counts the two cases
/// identically and the regression-vs-cold-start distinction is invisible.
///
/// SCA-367: the third arg is now a closed-vocab `RollbackErrorReason`
/// enum (was raw `error.localizedDescription`). Raw descriptions stay
/// in OSLog (where `.private` already redacts).
typealias NotificationRollbackFailureHandler = @MainActor @Sendable (
    _ schedulerId: SchedulerID,
    _ identifier: String,
    _ errorReason: RollbackErrorReason,
    _ priorExisted: Bool,
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
    /// cap second. The caller can emit its own telemetry + log line, OR use
    /// `emitSuppressed` to delegate the standard reason → telemetry mapping.
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

    /// SCA-402: standard suppression-emit. Each scheduler used to inline a
    /// switch over `NotificationSuppressReason` mapping case →
    /// telemetry-property + OSLog breadcrumb (LeftoversFollowupScheduler.swift
    /// + UseSoonScheduler.swift carried byte-identical 14-line blocks; UseSoon
    /// silently dropped the `until` OSLog breadcrumb leftovers wrote, an
    /// asymmetric coverage gap). This helper centralizes the mapping so
    /// (a) `reason` literal strings live in exactly one place, (b) future
    /// `NotificationSuppressReason` cases compile-fail at one switch site,
    /// (c) sibling schedulers get the OSLog breadcrumb for free.
    ///
    /// Caller pattern:
    /// ```swift
    /// if let reason = NotificationSchedulerKit.evaluateSuppression(...) {
    ///     NotificationSchedulerKit.emitSuppressed(
    ///         reason, event: .leftoversFollowupSuppressed,
    ///         telemetry: telemetry, logger: Logger.leftoversFollowup,
    ///     )
    ///     return
    /// }
    /// ```
    static func emitSuppressed(
        _ reason: NotificationSuppressReason,
        event: TelemetryEvent,
        telemetry: PostHogClient,
        logger: Logger,
    ) {
        switch reason {
        case let .unactionedStreak(until):
            telemetry.capture(event, properties: ["reason": "unactioned_streak"])
            logger.info(
                "suppressed until \(until.ISO8601Format(), privacy: .public) — skipping schedule",
            )
        case .weeklyCap:
            telemetry.capture(event, properties: ["reason": "weekly_cap"])
            logger.info("weekly cap (2/7d) reached — skipping schedule")
        }
    }

    /// Outcome of `addWithRollback`. SCA-319 introduced the typed
    /// enum; SCA-369 split `.lostBoth` into the dashboard-distinct
    /// `.noPriorAddFailed` and `.lostBoth` so PostHog can tell apart
    /// "fresh user first-schedule failure" from "user had it, we lost
    /// it" — counts were conflated under the prior single `.lostBoth`.
    enum RollbackResult: Sendable, Equatable {
        /// The new `request` was added successfully. Caller should
        /// proceed with `*_scheduled` history + telemetry writes.
        case added
        /// Primary `add` threw, but the rollback re-add of `prior`
        /// succeeded — the user has the same pending schedule they
        /// had before this attempt. Caller should NOT emit
        /// `*_scheduled` for the new request; the user is not in a
        /// degraded state.
        case rolledBack
        /// Primary `add` threw and there was NO prior to restore —
        /// fresh-user first-schedule failure. User has nothing pending
        /// but never had anything to lose either.
        case noPriorAddFailed
        /// Primary `add` threw AND rollback re-add also threw —
        /// regression: the user HAD a schedule and we lost it. Caller
        /// may surface user-recovery copy; telemetry is already emitted
        /// via `onRollbackFailure` with `priorExisted=true`.
        case lostBoth
    }

    /// Default `onRollbackFailure` handler that captures
    /// `notificationScheduleRollbackFailed` PostHog telemetry — SCA-361.
    /// Callers can pass this as `onRollbackFailure:` instead of
    /// hand-rolling identical closures at every scheduler.
    ///
    /// SCA-367: emits the closed-vocab `error_reason` enum rawValue
    /// rather than the raw `error.localizedDescription` (OS-supplied,
    /// not contractually constrained). Raw descriptions stay in OSLog
    /// only.
    static func defaultRollbackFailureHandler(
        telemetry: PostHogClient,
    ) -> NotificationRollbackFailureHandler {
        return { schedulerId, identifier, errorReason, priorExisted in
            telemetry.capture(.notificationScheduleRollbackFailed, properties: [
                "scheduler_id": schedulerId.rawValue,
                "identifier": identifier,
                "error_reason": errorReason.rawValue,
                // SCA-369: distinguishes regression (true) from cold-start
                // first-schedule failure (false).
                "prior_existed": priorExisted,
            ])
        }
    }

    /// Try to add `request`; on throw, attempt to re-add the previously-
    /// scheduled request for the same `identifier` (if any). Logs the
    /// initial add failure at `warning`; if the rollback re-add also
    /// throws, logs at `error` so the user-has-no-pending case is
    /// observable rather than silently swallowed (CA2-08).
    ///
    /// SCA-363: takes `identifier` rather than a pre-fetched `prior`.
    /// The kit calls `pendingRequest(identifier:)` internally, so
    /// callers no longer need to remember the SCA-319 "do not pre-
    /// cancel" rationale — it lives in this docstring.
    ///
    /// SCA-360: typed `schedulerId: SchedulerID` (was stringly-typed
    /// `String = ""`). The empty default could silently produce
    /// malformed telemetry; the typed enum forces the caller to choose.
    ///
    /// SCA-309 / SCA-369: the both-failures + no-prior branches invoke
    /// `onRollbackFailure` (when supplied) with `priorExisted` so the
    /// telemetry can tell apart regression vs fresh-user first-schedule.
    /// Use `defaultRollbackFailureHandler(telemetry:)` for the standard
    /// PostHog wiring (SCA-361).
    ///
    /// SCA-319: `UNUserNotificationCenter.add(_:)` replaces an existing
    /// request with the same identifier atomically, so a dedicated
    /// cancel step before this call is redundant — and racy when
    /// `pendingRequest` transiently returns `nil` even though one is
    /// pending. Callers MUST NOT pre-`cancel()`.
    ///
    /// - Returns: a typed `RollbackResult` — `.added`, `.rolledBack`,
    ///   `.noPriorAddFailed`, or `.lostBoth`.
    ///
    /// SCA-315 S9: `@discardableResult` intentionally NOT applied —
    /// callers gate post-add writes on the result.
    static func addWithRollback(
        _ request: UNNotificationRequest,
        identifier: String,
        center: any UserNotificationCenterClient,
        logger: Logger,
        contextLabel: String,
        schedulerId: SchedulerID,
        onRollbackFailure: NotificationRollbackFailureHandler? = nil,
    ) async -> RollbackResult {
        // SCA-363: prior fetch is now an internal implementation detail.
        let prior = await pendingRequest(identifier: identifier, center: center)
        do {
            try await center.add(request)
            return .added
        } catch {
            logger.warning(
                "add failed: \(error.localizedDescription, privacy: .private) — rolling back",
            )
            guard let prior else {
                // SCA-369: no prior to restore. Fresh-user first-schedule
                // failure — distinct from the regression case below.
                logger.error(
                    "no prior to roll back to — user has no pending \(contextLabel, privacy: .public)",
                )
                // SCA-367: classify the primary-add error to a closed-
                // vocab enum BEFORE the PostHog hop. Raw description
                // stays in OSLog only (.private above).
                onRollbackFailure?(
                    schedulerId,
                    request.identifier,
                    RollbackErrorReason.classify(error),
                    /* priorExisted */ false,
                )
                return .noPriorAddFailed
            }
            do {
                try await center.add(prior)
                return .rolledBack
            } catch {
                logger.error(
                    "rollback re-add failed: \(error.localizedDescription, privacy: .private) — user has no pending \(contextLabel, privacy: .public)",
                )
                // SCA-309 + SCA-369: regression — user HAD a schedule
                // and we lost it. SCA-367: closed-vocab enum, not raw
                // description.
                onRollbackFailure?(
                    schedulerId,
                    request.identifier,
                    RollbackErrorReason.classify(error),
                    /* priorExisted */ true,
                )
                return .lostBoth
            }
        }
    }
}
