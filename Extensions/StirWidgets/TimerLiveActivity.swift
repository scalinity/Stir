// TimerLiveActivity
//
// ActivityKit widget for Cook Mode timers. Lock Screen + Dynamic Island
// presentations matching mockup 13 "Live Activity — Lock Screen" +
// "Dynamic Island — three states".
//
// Visual grammar (mockup 13_widgets_liveactivity.html):
//   - Translucent glass on Lock Screen: background rgba(255,255,255,0.12)
//     via `.activityBackgroundTint(ember.tintDark)` with `AccessoryWidget`
//     rendering over user wallpaper
//   - StirGlyph badge (22pt) + "STIR · COOKING" uppercase (10pt/700/0.14em)
//   - Recipe title at 13pt/600, allowed to wrap to 3 lines (with
//     minimumScaleFactor 0.8 fallback for very long titles)
//   - Big mono timer at 18-40pt, ember color in expanded state
//   - "Step N of M" micro-eyebrow (10pt/700/0.12em) above the serif step
//     description and progress bar in the bottom region
//   - Serif step description (15pt regular)
//   - Progress bar for elapsed (shown in expanded + lock screen)
//   - Dynamic Island: compact shows mono timer + glyph; expanded shows
//     glyph + eyebrow + title in leading, ember timer in trailing,
//     step eyebrow + serif instruction + progress bar in bottom;
//     minimal shows just the StirGlyph dot

import ActivityKit
import SwiftUI
import WidgetKit

struct TimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimerActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.12))
                .activitySystemActionForegroundColor(Color.Stir.ember600)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(alignment: .top, spacing: 8) {
                        StirGlyph(size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stir · Cooking")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.4)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.white.opacity(0.55))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(context.attributes.recipeTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .lineLimit(3)
                                .minimumScaleFactor(0.8)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 12)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerNumbers(state: context.state)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.Stir.ember600)
                        .monospacedDigit()
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Step \(context.attributes.stepNumber) of \(context.attributes.totalSteps)")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.2)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.white.opacity(0.55))
                        Text(context.attributes.stepDescription)
                            .font(.system(size: 15, weight: .regular, design: .serif))
                            .foregroundStyle(Color.white)
                            .lineLimit(2)
                        ProgressBar(
                            fireDate: context.state.fireDate,
                            pausedRemainingSec: context.state.pausedRemainingSec,
                            totalDurationSec: totalDurationSec(for: context),
                            tint: Color.Stir.ember600,
                            track: Color.white.opacity(0.15),
                        )
                        .frame(height: 4)
                    }
                }
            } compactLeading: {
                StirGlyph(size: 18)
            } compactTrailing: {
                TimerNumbers(state: context.state)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            } minimal: {
                StirGlyph(size: 16)
            }
            .widgetURL(URL(string: "stir://cook/timer/\(context.attributes.timerId)"))
        }
    }

    /// Total seconds for the progress-bar denominator. Pinned at
    /// activity-start time (on the static attributes), so pause/resume
    /// updates to fireDate don't shift the denominator. Fallback to
    /// current-remaining for any legacy activities that predate the
    /// attributes-level field.
    private func totalDurationSec(for context: ActivityViewContext<TimerActivityAttributes>) -> Int {
        if context.attributes.initialDurationSec > 0 {
            return context.attributes.initialDurationSec
        }
        let remaining = max(0, Int(context.state.fireDate.timeIntervalSinceNow.rounded()))
        return max(remaining, 60)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<TimerActivityAttributes>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StirGlyph(size: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("Stir · Cooking")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.primary.opacity(0.7))
                Text(context.attributes.recipeTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Step \(context.attributes.stepNumber) of \(context.attributes.totalSteps)")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .padding(.top, 6)
                Text(context.attributes.stepDescription)
                    .font(.system(size: 15, weight: .regular, design: .serif))
                    .foregroundStyle(Color.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            TimerNumbers(state: context.state)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(Color.Stir.ember600)
        }
        .padding(14)
    }
}

// MARK: - Shared pieces

private struct TimerNumbers: View {
    let state: TimerActivityAttributes.ContentState

    var body: some View {
        if state.isComplete {
            Text("Done")
        } else if let pausedSec = state.pausedRemainingSec {
            Text(Self.mmss(seconds: pausedSec))
        } else {
            // `Text(timerInterval:)` is system-rendered and clamps to
            // 0:00 once Date.now passes the upper bound — replaces the
            // earlier `Text(state.fireDate, style: .timer)` form, which
            // counted UP positive elapsed-time after fireDate (force-
            // killed app left the activity reading "M:SS" climbing for
            // hours, observed device-side 2026-05-03).
            //
            // Lower bound is shifted -86400s (24h) so any realistic cook
            // timer — including overnight slow-roast, fermentation, or
            // low-and-slow braise scenarios — keeps `lower < Date.now`
            // and the displayed value stays `upper - Date.now`. With a
            // smaller offset (e.g. the 14400s voice clamp), a tap-mode
            // timer started from a >4h `step.timerSeconds` would hit
            // the "Date.now < lower" branch and freeze on the full
            // interval ("240:00") until Date.now caught up — same visual
            // symptom as the pauseTime regression fixed earlier.
            //
            // No `pauseTime:` here. An earlier fix added
            // `pauseTime: state.fireDate` thinking it would force a
            // hard-clamp at the upper bound — but `pauseTime` is for
            // "display as-of this clock moment" (used when surfacing a
            // user-paused timer), and setting it equal to the upper
            // bound produced a static 240:00 (the lower→upper interval
            // duration) instead of a count-down.
            Text(
                timerInterval: state.fireDate.addingTimeInterval(-86400)...state.fireDate,
                countsDown: true,
                showsHours: false,
            )
        }
    }

    static func mmss(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let m = clamped / 60
        let s = clamped % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct ProgressBar: View {
    let fireDate: Date
    let pausedRemainingSec: Int?
    let totalDurationSec: Int
    let tint: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let progress = Self.progress(
                fireDate: fireDate,
                pausedRemainingSec: pausedRemainingSec,
                totalDurationSec: totalDurationSec,
            )
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: max(0, min(width, width * progress)))
            }
        }
    }

    static func progress(
        fireDate: Date,
        pausedRemainingSec: Int?,
        totalDurationSec: Int,
    ) -> Double {
        guard totalDurationSec > 0 else { return 0 }
        let remaining: Int
        if let paused = pausedRemainingSec {
            remaining = paused
        } else {
            remaining = max(0, Int(fireDate.timeIntervalSinceNow.rounded()))
        }
        let elapsed = max(0, totalDurationSec - remaining)
        return Double(elapsed) / Double(totalDurationSec)
    }
}
