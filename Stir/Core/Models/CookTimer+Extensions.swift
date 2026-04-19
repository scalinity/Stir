// CookTimer type-safety extensions.
//
// Mirrors spec §4.13 (entity named "Timer" in the spec; renamed to
// CookTimer in Core Data to avoid colliding with Foundation.Timer).
//
// State machine:
//   pending   — created but not yet started
//   running   — startedAt set, no endedAt
//   paused    — startedAt set, endedAt nil, state=paused, pauseStartedAt
//               is tracked in-memory by TimerService (not persisted —
//               paused duration is derived from startedAt + current
//               state log, which TimerService owns).
//   completed — finished naturally; endedAt = startedAt + durationSec
//   cancelled — user-stopped; endedAt set to the cancel time
//
// `pausedForSec` from the user's prompt intentionally does NOT land as a
// column — the state machine handles pause arithmetic without needing a
// running-total field (Daniel's confirmation in scope alignment).

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
}
