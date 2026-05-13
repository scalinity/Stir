// UseSoonScheduler
//
// Local notification scheduling for the use-soon ingredient nudge. Fires
// when the user's pantry has at least one ephemeral item with
// `expiresAt <= 48h` AND no Cook Mode session has been completed in the
// trailing 24 hours.
//
// Spec §8 row 944 (SCA-64):
//   * Body: "Use your spinach before it goes — want 3 dinner ideas?"
//     (display name is templated from the soonest-expiring item)
//   * Constraints: opt-in, 8am–8:30pm local, max 2/week
//   * Fallback: "show only widget card" if ignored twice (deferred to
//     the Tonight Home use-soon card follow-up; SCA-86)
//   * Tap deep-links to Tonight + Constraints prefilled with use-first
//
// Spec drift note: §8 says "remembered" item; only `.ephemeral` rows
// carry `expiresAt`. Implemented against ephemeral; spec text is
// approximate.
//
// Contract:
//   * `evaluateAndScheduleIfDue(now:household:)` — call from a
//     foreground sweep (e.g., RootCoordinator post-bootstrap or a
//     scenePhase=.active hook). Idempotent, internally rate-limited.
//   * `cancel()` — call when user starts a solve / cook session, so
//     active users don't receive a "use it soon" message right after
//     they did.
//   * `recordAction()` — fired from the deep-link handler so the
//     unactioned-streak math counts taps.
//
// Telemetry:
//   * `use_soon_scheduled` { fire_at }
//   * `use_soon_fired`     (delivery; via StirNotificationDelegate)
//   * `use_soon_tapped`    (deep-link tap)
//   * `use_soon_suppressed` { reason: "weekly_cap" | "unactioned_streak" |
//                                     "recent_session" | "no_candidate" |
//                                     "no_displayable_candidate" }
//
// SCA-320: `item_display_name` dropped from `use_soon_scheduled` per
// ADR 0009 — pantry labels are user content. The notification body
// still uses the display name (user-facing rendering is fine), but
// telemetry, OSLog, and userInfo carry only the pantry item ID.
// `no_displayable_candidate` was added so a missing/empty displayName
// triggers a clean suppression instead of the prior "Use an
// ingredient before it goes" generic-fallback notification body.

import CoreData
import Foundation
import OSLog
import UserNotifications

private let useSoonReminderID = "stir.use_soon.48h"

@MainActor
final class UseSoonScheduler {
    static let shared = UseSoonScheduler()

    private let center: any UserNotificationCenterClient
    private let calendar: Calendar
    private let history: NotificationHistoryStore
    private let pantry: PantryItemRepository
    private let cookingSessions: CookingSessionRepository
    private let telemetry: PostHogClient

    init(
        center: any UserNotificationCenterClient = UNUserNotificationCenter.current(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard,
        controller: PersistenceController = .shared,
        pantry: PantryItemRepository? = nil,
        cookingSessions: CookingSessionRepository? = nil,
        telemetry: PostHogClient = .shared,
    ) {
        self.center = center
        self.calendar = calendar
        self.history = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.use_soon.history.v1",
            suppressionKey: "stir.use_soon.suppressed_until.v1",
        )
        // SCA-191 W4: nil-default + controller-aware fallback so a
        // test passing a custom controller gets repos wired to the
        // same instance instead of silently falling through to
        // .shared.
        self.pantry = pantry ?? PantryItemRepository(controller: controller)
        self.cookingSessions = cookingSessions ?? CookingSessionRepository(controller: controller)
        self.telemetry = telemetry
    }

    // MARK: - Public API

    /// Run the scheduling decision. Schedules if all gates pass; emits
    /// `use_soon_suppressed` for any short-circuit so we can size the
    /// suppression rate. Caller is expected to filter on
    /// `entitlements.notifications.opted-in` upstream — this scheduler
    /// is tier-agnostic (use-soon is a free-tier feature).
    func evaluateAndScheduleIfDue(
        now: Date = .init(),
        household: HouseholdProfile,
    ) async {
        // 1. Suppression preflight via shared kit. The kit returns the
        // reason; we map it to our telemetry event and bail.
        if let reason = NotificationSchedulerKit.evaluateSuppression(
            history: history,
            now: now,
        ) {
            switch reason {
            case .unactionedStreak:
                telemetry.capture(.useSoonSuppressed, properties: [
                    "reason": "unactioned_streak",
                ])
            case .weeklyCap:
                telemetry.capture(.useSoonSuppressed, properties: [
                    "reason": "weekly_cap",
                ])
            }
            return
        }

        // 2. "No solve in 24h" — actionable trigger condition per spec.
        if recentSessionCutoffViolated(now: now, household: household) {
            telemetry.capture(.useSoonSuppressed, properties: [
                "reason": "recent_session",
            ])
            return
        }

        // 3. Find candidate item.
        let candidates: [PantryItem]
        do {
            candidates = try pantry.fetchExpiringSoon(now: now, for: household)
        } catch {
            Logger.useSoon.warning(
                // SCA-366: error.localizedDescription marked .private to
                // match sibling line at :295 (SCA-313 Core-Data error log).
                // CoreData NSError.localizedDescription can carry entity
                // names + predicate fragments in fault descriptions.
                "fetchExpiringSoon failed: \(error.localizedDescription, privacy: .private) — skipping",
            )
            return
        }
        guard let candidate = candidates.first else {
            telemetry.capture(.useSoonSuppressed, properties: [
                "reason": "no_candidate",
            ])
            return
        }

        // SCA-320: previously the scheduler shipped a fallback notification
        // body of "Use an ingredient before it goes" when displayName was
        // nil — copy that reads as a bug. We now treat a missing
        // displayName as a suppression case so the user never sees the
        // generic copy. The candidate is otherwise valid; if a future
        // upstream fixes the displayName backfill, the next schedule
        // attempt picks it up automatically.
        guard
            let displayName = candidate.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !displayName.isEmpty
        else {
            telemetry.capture(.useSoonSuppressed, properties: [
                "reason": "no_displayable_candidate",
            ])
            return
        }

        let fireDate = nextFireDate(from: now)

        let authorized = await NotificationSchedulerKit.requestAuthorizationIfNeeded(
            center: center,
            logger: Logger.useSoon,
        )
        guard authorized else {
            Logger.useSoon.info("notification auth denied — skipping schedule")
            return
        }

        // `displayName` is the validated, trimmed value from the
        // suppression guard above. Used in the user-facing title only.
        let content = UNMutableNotificationContent()
        content.title = "Use \(displayName) before it goes"
        content.body = "Want 3 dinner ideas built around it?"
        content.sound = .default
        // SCA-320: pantry item ID only — see header. Deep-link refetches
        // displayName from CoreData on tap.
        content.userInfo = [
            "stir_notification_kind": "use_soon",
            "use_first_pantry_item_id": candidate.id?.uuidString ?? "",
        ]
        content.interruptionLevel = .active

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireDate,
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: useSoonReminderID,
            content: content,
            trigger: trigger,
        )

        // SCA-360 / SCA-361 / SCA-363: typed schedulerId, kit-level
        // default rollback handler, identifier-only signature.
        let result = await NotificationSchedulerKit.addWithRollback(
            request,
            identifier: useSoonReminderID,
            center: center,
            logger: Logger.useSoon,
            contextLabel: "use-soon",
            schedulerId: .useSoon,
            onRollbackFailure: NotificationSchedulerKit.defaultRollbackFailureHandler(telemetry: telemetry),
        )
        switch result {
        case .added:
            history.recordScheduled(fireAt: fireDate)
            // SCA-320: `fire_at` only — see header. Hashed OSLog
            // `item=` breadcrumb also dropped (was paired with the
            // removed property).
            telemetry.capture(.useSoonScheduled, properties: [
                "fire_at": fireDate.ISO8601Format(),
            ])
            Logger.useSoon.info(
                "scheduled fireDate=\(fireDate.ISO8601Format(), privacy: .public)",
            )
        case .rolledBack, .noPriorAddFailed, .lostBoth:
            // .rolledBack: prior intact, user keeps existing schedule.
            // .noPriorAddFailed / .lostBoth: telemetry already fired
            // via onRollbackFailure. No `*_scheduled` write in any case.
            break
        }
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [useSoonReminderID])
    }

    func recordAction(at instant: Date = .init()) {
        history.markMostRecentActioned(at: instant)
        telemetry.capture(.useSoonTapped, properties: [:])
    }

    // MARK: - Internal — visible for tests

    /// Fire-time clamp into the next 8am–8:30pm local window from `now`.
    /// If now is mid-window: fire at `now + 5min` (let user finish the
    /// current task before nudging). If now is before 8am: fire today
    /// at 8am. If now is past 8:30pm: fire tomorrow at 8am.
    func nextFireDate(from now: Date) -> Date {
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let isInWindow = hour >= 8 && (hour < 20 || (hour == 20 && minute < 30))
        if isInWindow {
            return now.addingTimeInterval(5 * 60)
        }
        if hour < 8 {
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: now) ?? now
        }
        // hour > 20 OR (hour == 20 && minute >= 30) → tomorrow at 8am.
        let next = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: next) ?? next
    }

    // MARK: - Private

    /// Returns `true` when the user has cooked in the trailing 24h —
    /// in which case the use-soon nudge is redundant.
    private func recentSessionCutoffViolated(
        now: Date,
        household: HouseholdProfile,
    ) -> Bool {
        // SCA-313 S31: prior shape `(try? ...) ?? nil` collapsed both
        // "no recent session" (nil result) AND "Core Data threw" to
        // nil → returned false → notification proceeded. A throw means
        // we don't actually know whether the user just cooked, so the
        // safer default is "assume recent session, suppress the nudge"
        // — better to occasionally skip a use-soon than to wake the
        // user with one we can't justify.
        let lastCompleted: Date?
        do {
            lastCompleted = try cookingSessions.mostRecentCompletedAt(for: household)
        } catch {
            Logger.useSoon.warning(
                "recentSessionCutoffViolated: cookingSessions.mostRecentCompletedAt threw — suppressing nudge as safe default. error=\(error.localizedDescription, privacy: .private)",
            )
            return true
        }
        guard let lastCompleted else { return false }
        return now.timeIntervalSince(lastCompleted) < 24 * 3600
    }
}

// MARK: - Notification payload parsing

enum UseSoonNotification {
    static func isUseSoon(from userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["stir_notification_kind"] as? String) == "use_soon"
    }

    static func useFirstPantryItemId(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard
            isUseSoon(from: userInfo),
            let raw = userInfo["use_first_pantry_item_id"] as? String,
            !raw.isEmpty,
            let uuid = UUID(uuidString: raw)
        else { return nil }
        return uuid
    }
}

// MARK: - Logger

extension Logger {
    static let useSoon = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "use_soon",
    )
}
