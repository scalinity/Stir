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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            content(at: context.date)
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

    /// Last-known display for the paused state. `startedAt` is not
    /// advanced on pause, so without the in-memory pause timestamp we
    /// can only show the remaining relative to the ORIGINAL fire date.
    /// Cross-session pauses will therefore show an inflated "still
    /// remaining" — acceptable for step 4 per the pause-math notes in
    /// TimerService.swift.
    private var frozenDisplayString: String {
        let fire = timer.fireDate ?? Date()
        let r = Int(fire.timeIntervalSinceNow.rounded())
        return formatHHMMSS(max(0, r)) + " (paused)"
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
