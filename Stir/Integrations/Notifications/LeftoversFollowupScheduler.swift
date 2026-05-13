// LeftoversFollowupScheduler
//
// Local notification scheduling for the +20h leftovers-followup nudge.
// Fires when the user logged `leftoverCount > 0` after a Premium+ cook
// and hasn't started a leftovers solve in the next ~20 hours.
//
// Spec §8 (SCA-65):
//   * Fires at submitted_at + 20h, clamped to next 10am–7pm local window
//   * Premium+ only (Free has `ENT-LEFTOVERS-01` paywall, can't act)
//   * Max 2 per 7-day rolling window
//   * If the previous 2 fires went unactioned → suppress for 14 days
//   * Tap deep-links to LeftoversRoot via stir://leftovers?source=notification
//
// Contract:
//   * `scheduleAfterFeedback(submittedAt:tier:)` — called from
//     `OutcomeFeedbackView.submit()` (Premium+ + leftoverCount>0 path).
//     Idempotent — re-scheduling cancels the prior request first.
//   * `cancel()` — called when the user actually starts a leftovers
//     solve (LeftoversSessionViewModel.findFollowUpIdea) or any other
//     followup action makes the notification redundant.
//   * `recordAction()` — called from the deep-link handler / leftovers
//     session start so the unactioned-streak suppression accounts for
//     it.
//
// Telemetry (spec §15 + CLAUDE.md):
//   * `leftovers_followup_scheduled` { fire_at }
//   * `leftovers_followup_fired` (delivery; via StirNotificationDelegate)
//   * `leftovers_followup_tapped` (deep-link tap)
//   * `leftovers_followup_suppressed` { reason: "weekly_cap" | "unactioned_streak" }

import Foundation
import OSLog
import UserNotifications

private let leftoversFollowupID = "stir.leftovers.followup.20h"

@MainActor
final class LeftoversFollowupScheduler {
    static let shared = LeftoversFollowupScheduler()

    private let center: any UserNotificationCenterClient
    private let calendar: Calendar
    private let history: NotificationHistoryStore
    private let telemetry: PostHogClient

    init(
        center: any UserNotificationCenterClient = UNUserNotificationCenter.current(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard,
        telemetry: PostHogClient = .shared,
    ) {
        self.center = center
        self.calendar = calendar
        self.history = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.leftovers_followup.history.v1",
            suppressionKey: "stir.leftovers_followup.suppressed_until.v1",
        )
        self.telemetry = telemetry
    }

    // MARK: - Public API

    /// Schedule the +20h followup. Premium+ only — caller (OutcomeFeedbackView)
    /// is expected to gate on `entitlements.effectiveTier ∈ {.premium, .pro}`
    /// before calling, but we double-check here so a future caller drift
    /// doesn't accidentally schedule for Free users.
    func scheduleAfterFeedback(submittedAt: Date = .init(), tier: Tier) async {
        guard tier == .premium || tier == .pro else {
            Logger.leftoversFollowup.info("non-premium tier — skipping schedule")
            return
        }

        // CA1-03: anchor cap + suppression checks on `Date()` (the actual
        // policy clock), not on the caller-supplied `submittedAt`. The
        // submittedAt parameter is for fire-time computation only —
        // backdated submittedAt values (test fixtures, CloudKit replay,
        // future caller refactor) must not bypass the policy.
        let policyNow = Date()

        // Suppression preflight via shared kit — both schedulers share the
        // suppressedUntil + weekly-cap policy; the kit returns the reason
        // and we emit the leftovers-specific telemetry event.
        if let reason = NotificationSchedulerKit.evaluateSuppression(
            history: history,
            now: policyNow,
        ) {
            switch reason {
            case let .unactionedStreak(until):
                telemetry.capture(.leftoversFollowupSuppressed, properties: [
                    "reason": "unactioned_streak",
                ])
                Logger.leftoversFollowup.info(
                    "suppressed until \(until.ISO8601Format(), privacy: .public) — skipping schedule",
                )
            case .weeklyCap:
                telemetry.capture(.leftoversFollowupSuppressed, properties: [
                    "reason": "weekly_cap",
                ])
                Logger.leftoversFollowup.info("weekly cap (2/7d) reached — skipping schedule")
            }
            return
        }

        let fireDate = nextFireDate(from: submittedAt)

        let authorized = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: Logger.leftoversFollowup,
        )
        guard authorized else {
            Logger.leftoversFollowup.info("notification auth denied — skipping schedule")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Tomorrow's dinner is already in your fridge"
        content.body = "Your leftovers can become tomorrow's dinner in one tap."
        content.sound = .default
        content.userInfo = [
            NotificationKind.userInfoKey: NotificationKind.leftoversFollowup.rawValue,
        ]
        content.interruptionLevel = .active

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate,
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: leftoversFollowupID,
            content: content,
            trigger: trigger,
        )

        // SCA-360 / SCA-361 / SCA-363: typed schedulerId, kit-level
        // default rollback handler, identifier-only signature.
        let result = await NotificationSchedulerKit.addWithRollback(
            request,
            identifier: leftoversFollowupID,
            center: center,
            logger: Logger.leftoversFollowup,
            contextLabel: "followup",
            schedulerId: .leftoversFollowup,
            onRollbackFailure: NotificationSchedulerKit.defaultRollbackFailureHandler(telemetry: telemetry),
        )
        switch result {
        case .added:
            history.recordScheduled(fireAt: fireDate)
            telemetry.capture(.leftoversFollowupScheduled, properties: [
                "fire_at": fireDate.ISO8601Format(),
            ])
            Logger.leftoversFollowup.info(
                "scheduled fireDate=\(fireDate.ISO8601Format(), privacy: .public)",
            )
        case .rolledBack, .noPriorAddFailed, .lostBoth:
            // .rolledBack: prior intact, user keeps existing schedule.
            // .noPriorAddFailed / .lostBoth: telemetry already fired
            // via onRollbackFailure. No `*_scheduled` write in any case.
            break
        }
    }

    /// Cancel any pending followup. Called when the user starts a
    /// leftovers solve (the notification's purpose is fulfilled) or
    /// before re-scheduling on a fresh feedback submit.
    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [leftoversFollowupID])
    }

    /// Record that the user acted on a fired notification — either by
    /// tapping it (deep link) or by starting a leftovers session within
    /// the action window. Resets the unactioned-streak suppression.
    func recordAction(at instant: Date = .init()) {
        history.markMostRecentActioned(at: instant)
        telemetry.capture(.leftoversFollowupTapped, properties: [:])
    }

    // MARK: - Internal — visible for tests

    /// Next fire instant for `submittedAt + 20h`, clamped to the next
    /// 10am–7pm local window. Logic:
    ///   * Add 20h.
    ///   * If hour ∈ [10, 19): keep as-is.
    ///   * If hour < 10: bump to 10am same calendar day.
    ///   * If hour ≥ 19: bump to 10am next calendar day.
    func nextFireDate(from submittedAt: Date) -> Date {
        let raw = submittedAt.addingTimeInterval(20 * 3600)
        let hour = calendar.component(.hour, from: raw)
        if (10..<19).contains(hour) {
            return raw
        }
        if hour < 10 {
            // Same calendar day, 10:00 local.
            return calendar.date(
                bySettingHour: 10,
                minute: 0,
                second: 0,
                of: raw,
            ) ?? raw
        }
        // hour >= 19 — next day at 10:00.
        let nextDay = calendar.date(byAdding: .day, value: 1, to: raw) ?? raw
        return calendar.date(
            bySettingHour: 10,
            minute: 0,
            second: 0,
            of: nextDay,
        ) ?? nextDay
    }
}

// MARK: - Payload parsing for telemetry / deep-link routing

/// Inspect a delivered notification's userInfo to decide whether it was
/// the leftovers-followup reminder. Lets `StirNotificationDelegate`
/// emit `leftovers_followup_fired` on delivery and the deep-link
/// handler distinguish source = notification.
enum LeftoversFollowupNotification {
    static func isFollowup(from userInfo: [AnyHashable: Any]) -> Bool {
        NotificationKind.from(userInfo) == .leftoversFollowup
    }
}

// MARK: - Logger

extension Logger {
    static let leftoversFollowup = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "leftovers_followup",
    )
}
