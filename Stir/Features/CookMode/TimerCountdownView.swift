// TimerCountdownView
//
// Live countdown rendered with TimelineView(.periodic) ticking at 1s.
// Derives remaining time from `timer.fireDate - now` so the value is
// always authoritative — no separate in-memory counter to drift with
// the UI. When the fire date passes while the view is on-screen, the
// view shows "Done" and the parent view model's reconciliation path
// marks the timer completed on the next tick of the containing state.

import SwiftUI

struct TimerCountdownView: View {
    let timer: CookTimer
    /// Wall-clock time the pause button was tapped, looked up by the
    /// parent from `CookModeViewModel.pauseStartedAt(for:)`. Nil when
    /// the timer isn't paused OR the pause context was lost (app cold-
    /// relaunch while paused — rare, documented limitation). Drives
    /// the static paused-remaining display; without it the paused
    /// label kept ticking down because it was computed from
    /// `fireDate - now` which keeps moving.
    var pauseStartedAt: Date? = nil

    var body: some View {
        // Only install the 1 Hz TimelineView when we're actually
        // counting — `.completed` / `.cancelled` / `.pending` displays
        // are static text, and `.paused` is static by design (the
        // pause-frozen value doesn't change while paused). Skipping
        // the TimelineView in those branches saves 1 Hz redraws when
        // multiple terminal timers stack up.
        Group {
            if timer.typedState == .running {
                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                    content(at: context.date)
                }
            } else {
                content(at: Date())
            }
        }
        // Accessibility: expose the hh:mm:ss as a single element so
        // VoiceOver reads "3 minutes 12 seconds remaining", not each
        // digit individually.
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func content(at now: Date) -> some View {
        switch timer.typedState {
        case .pending:
            label("Ready to start", color: .secondary)
        case .running:
            runningBody(at: now)
        case .paused:
            // Color change (orange) is the pause signal — no "(paused)"
            // suffix, per Daniel's 2026-04-22 request.
            label(frozenDisplayString, color: .orange)
        case .completed:
            label("Done", color: .green)
        case .cancelled:
            label("Cancelled", color: .secondary)
        }
    }

    private func runningBody(at now: Date) -> some View {
        let remaining = secondsRemaining(at: now)
        if remaining <= 0 {
            return label("Done", color: .green)
        }
        return label(formatHHMMSS(remaining), color: .primary)
    }

    private func secondsRemaining(at now: Date) -> Int {
        guard let fire = timer.fireDate else { return 0 }
        return Int(fire.timeIntervalSince(now).rounded())
    }

    /// Static paused-remaining display. Computed as `fireDate -
    /// pauseStartedAt` when the in-memory pause timestamp is
    /// available (same-session pause/resume — the 99% case). Falls
    /// back to `fireDate - now` when pause context was lost (app
    /// cold-relaunched while paused); that fallback keeps ticking but
    /// is the safest approximation TimerService can offer without a
    /// persisted pause timestamp (see CLAUDE.md §"Persisted pause
    /// timestamp for CookTimer" deferral).
    private var frozenDisplayString: String {
        let fire = timer.fireDate ?? Date()
        let reference: Date
        if let pausedAt = pauseStartedAt {
            reference = pausedAt
        } else {
            reference = Date()
        }
        let r = Int(fire.timeIntervalSince(reference).rounded())
        return formatHHMMSS(max(0, r))
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 48, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(color)
    }

    private func formatHHMMSS(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }
}
