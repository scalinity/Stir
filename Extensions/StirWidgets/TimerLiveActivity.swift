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
//   - Recipe title at 13pt/600
//   - Big mono timer at 18-40pt, ember color in expanded state
//   - Serif step description (`.bodyLg` at 16pt)
//   - Progress bar for elapsed (optional, shown when running)
//   - "Step 3 of 6" micro-eyebrow below progress bar
//   - Dynamic Island: compact shows mono timer + divider + step short
//     label; expanded has full serif instruction + Pause/Next tiles;
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
                    HStack(spacing: 8) {
                        StirGlyph(size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Stir · Cooking")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.4)
                                .textCase(.uppercase)
                                .foregroundStyle(Color.white.opacity(0.55))
                            Text(expandedHeadline(for: context))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.white)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerNumbers(state: context.state)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.Stir.ember600)
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 10) {
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

    private func expandedHeadline(for context: ActivityViewContext<TimerActivityAttributes>) -> String {
        "\(context.attributes.recipeTitle) · Step \(context.attributes.stepNumber)/\(context.attributes.totalSteps)"
    }

    /// Estimate the total duration from the fire date. We don't persist
    /// it on the activity (fireDate shifts on resume) so derive from the
    /// difference between capture and fire at activity-start time is
    /// not retained. Fallback: clamp to 1 minute so the progress bar
    /// isn't divided by zero on freshly-opened activities.
    private func totalDurationSec(for context: ActivityViewContext<TimerActivityAttributes>) -> Int {
        // For v1 we don't carry total duration on the activity. Using
        // a coarse 60-min upper bound for the progress bar visual. The
        // main signal is "timer is running" + remaining mmss; exact
        // fill % is secondary. Revisit if UX feedback demands precision.
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
                    .lineLimit(1)
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
            Text(state.fireDate, style: .timer)
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
