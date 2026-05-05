// CookTimer type-safety extensions.
//
// Mirrors spec §4.13 (entity named "Timer" in the spec; renamed to
// CookTimer in Core Data to avoid colliding with Foundation.Timer).
//
// State machine:
//   pending   — created but not yet started
//   running   — startedAt set, no endedAt
//   paused    — startedAt set, endedAt nil, state=paused.
//               `pausedRemainingSec` is persisted (DB1-1 fix) so cold-launch
//               reconcile can show the correct Lock Screen remaining time;
//               `pauseStartedAt` is tracked in-memory by TimerService and
//               only used to advance startedAt on resume.
//   completed — finished naturally; endedAt = startedAt + durationSec
//   cancelled — user-stopped; endedAt set to the cancel time
//
// `pausedRemainingSec` uses sentinel -1 for "not paused / cleared" because
// the Core Data attribute is non-optional Integer 32 (scalar). Helper
// `pausedRemainingSeconds` materialises that as Int? so call sites don't
// need to remember the sentinel.

import CoreData
import Foundation

extension CookTimer {
    enum State: String, CaseIterable, Sendable {
        case pending
        case running
        case paused
        case completed
        case cancelled
    }

    var typedState: State {
        get { state.flatMap(State.init(rawValue:)) ?? .pending }
        set { state = newValue.rawValue }
    }

    /// True when the timer should be counting down from startedAt +
    /// durationSec. Used by the countdown view to decide whether to
    /// tick.
    var isActive: Bool {
        typedState == .running && startedAt != nil && endedAt == nil
    }

    /// Natural-completion fire date: `startedAt + durationSec`. Nil when
    /// the timer hasn't started. Pause time is NOT factored in here —
    /// TimerService adjusts when the user resumes.
    var fireDate: Date? {
        guard let started = startedAt else { return nil }
        return started.addingTimeInterval(TimeInterval(durationSec))
    }

    /// Seconds remaining when running. Negative when overdue (timer
    /// already fired but the app was backgrounded). Zero when paused or
    /// pending. Callers clamp to 0 before display.
    var remainingSeconds: Int {
        guard let fire = fireDate, typedState == .running else { return 0 }
        let delta = fire.timeIntervalSinceNow
        return max(-Int.max, Int(delta.rounded()))
    }

    /// Persisted snapshot of paused-remaining seconds. Nil when the
    /// timer isn't paused (sentinel -1 in storage). Used by
    /// `CookModeViewModel.reconcileTimersOnForeground` so cold-launch
    /// Lock Screen reconcile can show the correct paused remaining
    /// without consulting the in-memory pauseStartedAt map (which is
    /// process-scoped and gone after a force-quit).
    var pausedRemainingSeconds: Int? {
        let raw = Int(pausedRemainingSec)
        return raw >= 0 ? raw : nil
    }
}
