// StirNotificationDelegate
//
// UNUserNotificationCenterDelegate implementation. Responsible for:
//   - Presenting notifications in-foreground with banner + sound.
//   - Swapping the default iOS Tri-tone for a softer "Tink" chime when
//     a Cook Mode timer notification fires while the app is foreground.
//   - Emitting `reactivation_notification_opened` when the 7-day cook
//     reminder fires (delivery or tap-through; spec §15 canonical).
//   - Emitting `leftovers_followup_fired` when the +20h leftovers
//     followup fires (delivery only; SCA-65, spec §15 canonical).
//   - Emitting `use_soon_fired` when the use-soon ingredient
//     notification fires (delivery only; SCA-64, spec §15 canonical).
//
// The delegate is installed at launch by StirApp via
// `StirNotificationDelegate.register()`. It's a singleton because
// UNUserNotificationCenter.delegate is a global slot.
//
// SCA-318 hardening:
//   * `@MainActor` (was `@unchecked Sendable`). UN delegate callbacks
//     hop to main automatically since iOS 16; the @unchecked + NSLock
//     pattern was defending against a race that no longer exists. Drop
//     both — the compiler now enforces what the lock was trying to.
//   * Per-kind dedupe set keyed on `(NotificationKind, identifier)`.
//     Old code shared one set across kinds, so a future per-fire
//     identifier (or hypothetical cross-kind identifier collision)
//     would silently suppress the second event. Each kind gets its
//     own bucket with a soft 32-entry cap; today every kind uses a
//     singleton identifier so the cap is essentially unreachable.
//   * Single dispatch via `NotificationKind.from(_:)` instead of three
//     `emitTelemetryIf*` helpers. Adding a new kind is now a one-line
//     enum case + one switch arm — was three call sites.

import AudioToolbox
import Foundation
import UserNotifications

@MainActor
final class StirNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StirNotificationDelegate()

    /// SystemSoundID for the foreground timer chime. 1057 is iOS's
    /// "Tink" — a single-note soft chime that's audible without being
    /// startling, suited to a kitchen-cook context. Hoisted as a named
    /// constant so a future swap to a custom-bundled chime only touches
    /// one place. `AudioServicesPlaySystemSound` respects the device
    /// silent switch, so the cue correctly stays silent when muted.
    /// Marked `nonisolated` so the `willPresent` callback (which is
    /// `nonisolated` to satisfy the protocol's non-isolated requirement)
    /// can reference it without an actor hop.
    nonisolated private static let tinkSoundID: SystemSoundID = 1057

    /// Soft cap per-kind to bound memory growth in case a future
    /// notification kind starts using per-fire identifiers (rather than
    /// the singleton-identifier pattern every current kind uses). Today
    /// each kind has at most one entry in its bucket; the cap exists so
    /// a regression doesn't grow the set unboundedly.
    private static let dedupeCapPerKind = 32

    private let telemetry: PostHogClient

    /// Identifiers we've already emitted a `*_fired` (or
    /// `reactivation_notification_opened`) event for, bucketed per
    /// notification kind. Guards against double-emission when the same
    /// notification triggers BOTH `willPresent` (foreground delivery)
    /// AND `didReceive` (user subsequently taps the banner). Per-kind
    /// bucketing prevents an identifier collision across kinds from
    /// silently suppressing a second kind's event.
    private var emittedReminderIDs: [NotificationKind: Set<String>] = [:]

    init(telemetry: PostHogClient = .shared) {
        self.telemetry = telemetry
        super.init()
    }

    /// Install as the center's delegate. Idempotent — calling twice just
    /// overwrites the global slot with the same object.
    static func register() {
        UNUserNotificationCenter.current().delegate = shared
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Delivery while app is foregrounded. Show banner + play sound so the
    /// user notices, and emit per-kind telemetry once.
    ///
    /// Timer notifications take a custom audio path: the system Tri-tone
    /// is too aggressive for a kitchen-cook chime, so we swap it for the
    /// soft "Tink" SystemSoundID (1057) and suppress the default `.sound`
    /// option. This applies in-foreground only — background / killed
    /// delivery still uses `content.sound = .default` from the original
    /// `UNNotificationRequest` so the user gets a familiar, audible cue
    /// when the app isn't on screen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void,
    ) {
        let userInfo = notification.request.content.userInfo
        let isTimer = TimerNotification.isTimer(from: userInfo)
        // Decide the presentation options up front so we can call the
        // completion handler synchronously — UN expects this within the
        // method body (not from a deferred Task) for foreground banners.
        let options: UNNotificationPresentationOptions = isTimer
            ? [.banner]
            : [.banner, .sound]
        if isTimer {
            // Single-note soft chime. We suppress `.sound` from the
            // presentation options so the system doesn't ALSO fire the
            // default Tri-tone on top of our chime.
            AudioServicesPlaySystemSound(Self.tinkSoundID)
        }
        Task { @MainActor in
            Self.shared.emitTelemetryIfNeeded(notification)
        }
        completionHandler(options)
    }

    /// Delivery when user taps a notification in-background → app foregrounds.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void,
    ) {
        Task { @MainActor in
            Self.shared.emitTelemetryIfNeeded(response.notification)
        }
        completionHandler()
    }

    // MARK: - Telemetry dispatch

    /// Resolve the notification's kind (if recognized) and emit the
    /// matching `*_fired`-class event exactly once per (kind, identifier)
    /// across this process lifetime.
    private func emitTelemetryIfNeeded(_ notification: UNNotification) {
        let userInfo = notification.request.content.userInfo
        guard let kind = NotificationKind.from(userInfo) else { return }

        let identifier = notification.request.identifier
        guard markEmitted(kind: kind, identifier: identifier) else { return }

        switch kind {
        case .reactivation:
            // Route through the typed builder (same pattern as
            // step-5/step-7 telemetry — prevents property-name drift).
            // `triggerKind` is required for this event; absent userInfo
            // = malformed reactivation payload, so skip emission.
            guard let triggerKind = ReactivationNotification.triggerKind(from: userInfo) else { return }
            telemetry.capture(
                .reactivationNotificationOpened,
                properties: StepSevenTelemetry.reactivationNotificationOpened(triggerKind: triggerKind),
            )
        case .leftoversFollowup:
            telemetry.capture(.leftoversFollowupFired, properties: [:])
        case .useSoon:
            telemetry.capture(.useSoonFired, properties: [:])
        }
    }

    /// Insert (kind, identifier) into the dedupe set. Returns `true` on
    /// first sight (caller should emit), `false` when it's already
    /// present (caller should skip). Evicts an arbitrary prior entry
    /// when the bucket exceeds `dedupeCapPerKind` so memory stays bounded
    /// if a future kind adopts per-fire identifiers.
    private func markEmitted(kind: NotificationKind, identifier: String) -> Bool {
        var bucket = emittedReminderIDs[kind] ?? []
        let inserted = bucket.insert(identifier).inserted
        if bucket.count > Self.dedupeCapPerKind {
            // Pop an arbitrary stale entry. Set's removeFirst() is O(n)
            // worst-case but the bucket is bounded at 32, so it's fine.
            bucket.removeFirst()
        }
        emittedReminderIDs[kind] = bucket
        return inserted
    }
}

// MARK: - NotificationKind

/// Single source of truth for the `userInfo["stir_notification_kind"]`
/// values Stir's local notifications carry. Adding a new kind here +
/// adding a switch arm in `emitTelemetryIfNeeded` is the full surface
/// for wiring a new `*_fired`-class event into the delegate.
enum NotificationKind: String, CaseIterable, Sendable {
    case reactivation
    case leftoversFollowup = "leftovers_followup"
    case useSoon = "use_soon"

    static func from(_ userInfo: [AnyHashable: Any]) -> NotificationKind? {
        guard let raw = userInfo["stir_notification_kind"] as? String else { return nil }
        return NotificationKind(rawValue: raw)
    }
}
