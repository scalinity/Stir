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
//   * `use_soon_scheduled` { fire_at, item_display_name }
//   * `use_soon_fired`     (delivery; via StirNotificationDelegate)
//   * `use_soon_tapped`    (deep-link tap)
//   * `use_soon_suppressed` { reason: "weekly_cap" | "unactioned_streak" |
//                                     "recent_session" | "no_candidate" }

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
        pantry: PantryItemRepository = PantryItemRepository(controller: .shared),
        cookingSessions: CookingSessionRepository = CookingSessionRepository(controller: .shared),
        telemetry: PostHogClient = .shared,
    ) {
        self.center = center
        self.calendar = calendar
        self.history = NotificationHistoryStore(
            defaults: defaults,
            stateKey: "stir.use_soon.history.v1",
            suppressionKey: "stir.use_soon.suppressed_until.v1",
        )
        self.pantry = pantry
        self.cookingSessions = cookingSessions
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
        // 1. Suppression check first — cheapest.
        if let suppressedUntil = history.suppressedUntil, suppressedUntil > now {
            telemetry.capture(.useSoonSuppressed, properties: [
                "reason": "unactioned_streak",
            ])
            return
        }
        if history.firesInLastWeek(asOf: now).count >= NotificationHistoryStore.weeklyCap {
            telemetry.capture(.useSoonSuppressed, properties: [
                "reason": "weekly_cap",
            ])
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
                "fetchExpiringSoon failed: \(error.localizedDescription, privacy: .public) — skipping",
            )
            return
        }
        guard let candidate = candidates.first else {
            telemetry.capture(.useSoonSuppressed, properties: [
                "reason": "no_candidate",
            ])
            return
        }

        let fireDate = nextFireDate(from: now)

        let authorized = await requestAuthorizationIfNeeded()
        guard authorized else {
            Logger.useSoon.info("notification auth denied — skipping schedule")
            return
        }

        let prior = await pendingReminder()
        cancel()

        let displayName = candidate.displayName ?? "an ingredient"
        let content = UNMutableNotificationContent()
        content.title = "Use \(displayName) before it goes"
        content.body = "Want 3 dinner ideas built around it?"
        content.sound = .default
        content.userInfo = [
            "stir_notification_kind": "use_soon",
            "use_first_pantry_item_id": candidate.id?.uuidString ?? "",
            "use_first_display_name": displayName,
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

        do {
            try await center.add(request)
            history.recordScheduled(fireAt: fireDate)
            telemetry.capture(.useSoonScheduled, properties: [
                "fire_at": fireDate.ISO8601Format(),
                "item_display_name": displayName,
            ])
            Logger.useSoon.info(
                "scheduled fireDate=\(fireDate.ISO8601Format(), privacy: .public) item=\(displayName, privacy: .private(mask: .hash))",
            )
        } catch {
            Logger.useSoon.warning(
                "add failed: \(error.localizedDescription, privacy: .private) — rolling back",
            )
            // CA2-08: log rollback re-add failure rather than silently
            // discarding via `try?` — leaves the user with no pending
            // use-soon at all and we need a signal.
            if let prior {
                do {
                    try await center.add(prior)
                } catch {
                    Logger.useSoon.error(
                        "rollback re-add failed: \(error.localizedDescription, privacy: .private) — user has no pending use-soon",
                    )
                }
            }
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
        let lastCompleted = (try? cookingSessions.mostRecentCompletedAt(for: household)) ?? nil
        guard let lastCompleted else { return false }
        return now.timeIntervalSince(lastCompleted) < 24 * 3600
    }

    private func pendingReminder() async -> UNNotificationRequest? {
        let pending = await center.pendingNotificationRequests()
        return pending.first { $0.identifier == useSoonReminderID }
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            // CA2-09: don't silently collapse a thrown auth error to "denied".
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Logger.useSoon.warning(
                    "requestAuthorization threw: \(error.localizedDescription, privacy: .private)",
                )
                return false
            }
        @unknown default:
            return false
        }
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
