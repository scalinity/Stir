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
//   * `leftovers_followup_scheduled` { fire_at, suppressed }
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
    private let history: HistoryStore
    private let telemetry: PostHogClient

    init(
        center: any UserNotificationCenterClient = UNUserNotificationCenter.current(),
        calendar: Calendar = .current,
        defaults: UserDefaults = .standard,
        telemetry: PostHogClient = .shared,
    ) {
        self.center = center
        self.calendar = calendar
        self.history = HistoryStore(defaults: defaults)
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

        // Suppression checks — emit telemetry on skip so we can size the
        // suppression rate in the funnel.
        if let suppressedUntil = history.suppressedUntil, suppressedUntil > submittedAt {
            telemetry.capture(.leftoversFollowupSuppressed, properties: [
                "reason": "unactioned_streak",
            ])
            Logger.leftoversFollowup.info(
                "suppressed until \(suppressedUntil.ISO8601Format(), privacy: .public) — skipping schedule",
            )
            return
        }
        if history.firesInLastWeek(asOf: submittedAt).count >= 2 {
            telemetry.capture(.leftoversFollowupSuppressed, properties: [
                "reason": "weekly_cap",
            ])
            Logger.leftoversFollowup.info("weekly cap (2/7d) reached — skipping schedule")
            return
        }

        let fireDate = nextFireDate(from: submittedAt)

        let authorized = await requestAuthorizationIfNeeded()
        guard authorized else {
            Logger.leftoversFollowup.info("notification auth denied — skipping schedule")
            return
        }

        let prior = await pendingReminder()
        cancel()

        let content = UNMutableNotificationContent()
        content.title = "Tomorrow's dinner is already in your fridge"
        content.body = "Your leftovers can become tomorrow's dinner in one tap."
        content.sound = .default
        content.userInfo = [
            "stir_notification_kind": "leftovers_followup",
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

        do {
            try await center.add(request)
            history.recordScheduled(fireAt: fireDate)
            telemetry.capture(.leftoversFollowupScheduled, properties: [
                "fire_at": fireDate.ISO8601Format(),
            ])
            Logger.leftoversFollowup.info(
                "scheduled fireDate=\(fireDate.ISO8601Format(), privacy: .public)",
            )
        } catch {
            Logger.leftoversFollowup.warning(
                "add failed: \(error.localizedDescription, privacy: .public) — rolling back",
            )
            if let prior {
                try? await center.add(prior)
            }
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

    // MARK: - Private

    private func pendingReminder() async -> UNNotificationRequest? {
        let pending = await center.pendingNotificationRequests()
        return pending.first { $0.identifier == leftoversFollowupID }
    }

    private func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return false
        }
    }
}

// MARK: - HistoryStore

/// UserDefaults-backed history of fire/action events. Bounded to the
/// last 5 entries so the storage stays trivially small.
@MainActor
final class HistoryStore {
    private let defaults: UserDefaults
    private static let key = "stir.leftovers_followup.history.v1"
    private static let suppressionKey = "stir.leftovers_followup.suppressed_until.v1"
    private static let maxEntries = 5

    struct Entry: Codable, Equatable {
        let fireAt: Date
        var actioned: Bool
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var suppressedUntil: Date? {
        defaults.object(forKey: Self.suppressionKey) as? Date
    }

    /// Returns fire timestamps within the trailing 7-day window from
    /// `asOf`. Used for the 2-per-week cap check.
    func firesInLastWeek(asOf: Date) -> [Date] {
        let cutoff = asOf.addingTimeInterval(-7 * 86_400)
        return load()
            .filter { $0.fireAt >= cutoff }
            .map { $0.fireAt }
    }

    /// Append a scheduled-fire entry. Also evaluates the unactioned
    /// streak — if the prior 2 entries were both unactioned, set the
    /// 14-day suppression starting now.
    func recordScheduled(fireAt: Date) {
        var entries = load()
        let prior = entries.suffix(2)
        if prior.count == 2, prior.allSatisfy({ !$0.actioned }) {
            // Two unactioned in a row → suppress 14 days from now.
            // Don't append the new entry under suppression; the caller
            // shouldn't have reached recordScheduled if suppressed,
            // but defend against an out-of-order call by tagging the
            // suppression first.
            defaults.set(
                Date().addingTimeInterval(14 * 86_400),
                forKey: Self.suppressionKey,
            )
        }
        entries.append(Entry(fireAt: fireAt, actioned: false))
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        save(entries)
    }

    /// Mark the most recent fire as actioned. Also clears any active
    /// suppression — the user just demonstrated engagement.
    func markMostRecentActioned(at _: Date) {
        var entries = load()
        guard let last = entries.indices.last else { return }
        entries[last].actioned = true
        save(entries)
        defaults.removeObject(forKey: Self.suppressionKey)
    }

    /// For tests — clear all state.
    func reset() {
        defaults.removeObject(forKey: Self.key)
        defaults.removeObject(forKey: Self.suppressionKey)
    }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

// MARK: - Payload parsing for telemetry / deep-link routing

/// Inspect a delivered notification's userInfo to decide whether it was
/// the leftovers-followup reminder. Lets `StirNotificationDelegate`
/// emit `leftovers_followup_fired` on delivery and the deep-link
/// handler distinguish source = notification.
enum LeftoversFollowupNotification {
    static func isFollowup(from userInfo: [AnyHashable: Any]) -> Bool {
        (userInfo["stir_notification_kind"] as? String) == "leftovers_followup"
    }
}

// MARK: - Logger

extension Logger {
    static let leftoversFollowup = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "leftovers_followup",
    )
}
