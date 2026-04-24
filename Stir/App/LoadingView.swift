// LoadingView
//
// Launch + session-restore skeleton shown while RootCoordinator.bootstrap()
// runs. Matches mockup 01 "Launch / Session Restore":
//
//   - Centered "Stir." wordmark in New York Semibold, 96pt (§4.1
//     one-off hero size — NOT tokenized). The period is rendered in
//     ember.600 as the app's only mark of visual character (§2
//     "wordmark-only for v1").
//   - 24pt partial-arc spinner below the wordmark (bottom: 96pt from
//     safe-area bottom), 2pt stroke, ink.100 track with ember.600
//     quarter-arc sweeping at 0.9s per revolution.
//   - Optional restore caption "Picking up where you left off…"
//     shown when the coordinator's bootstrap is restoring an in-flight
//     MealSolveRequest or Cook Mode session.
//
// Reduce Motion: the spinner arc animation is dropped; a static
// partial-arc renders instead. Users with Reduce Motion still see the
// wordmark + a non-animated progress indicator.

import SwiftUI

struct LoadingView: View {
    /// Optional caption rendered below the spinner. `nil` means cold
    /// launch (no caption); a non-nil string means session restore.
    let restoreCaption: String?

    init(restoreCaption: String? = nil) {
        self.restoreCaption = restoreCaption
    }

    var body: some View {
        ZStack {
            Color.Stir.paper50
                .ignoresSafeArea()

            StirWordmark(sizePoints: 96)
                .accessibilityLabel("Stir")

            VStack(spacing: CGFloat.Stir.space3) {
                StirSpinner(size: 24)
                if let restoreCaption {
                    Text(restoreCaption)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                        .tracking(0.1)
                        .accessibilityLabel(restoreCaption)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - StirWordmark

/// "Stir." wordmark with ember period. Used on Launch + Welcome.
/// The `.` is the one brand-visual element per §2 "wordmark-only for v1".
private struct StirWordmark: View {
    let sizePoints: CGFloat

    var body: some View {
        // justification: hero wordmark sizes (96pt on Launch, 40pt on
        // Welcome tagline, 22pt on Welcome top-left) are one-off per
        // §4.1 "One-off hero numerals are NOT tokenized"; the wordmark
        // is a bespoke per-screen size.
        let wordmark = Text("Stir")
            .foregroundStyle(Color.Stir.ink900)
            + Text(".")
            .foregroundStyle(Color.Stir.ember600)
        wordmark
            // justification: wordmark sizes are one-off per §4.1 — bespoke per-screen (96pt Launch, 40pt Welcome tagline, 22pt Welcome top-left)
            .font(.system(size: sizePoints, weight: .semibold, design: .serif))
            .tracking(sizePoints * -0.04) // -0.04em tight display tracking
    }
}

// MARK: - StirSpinner

/// 24pt partial-arc spinner. 2pt stroke, ink.100 track, ember.600
/// quarter-arc rotating at 0.9s per revolution. Honors Reduce Motion.
private struct StirSpinner: View {
    let size: CGFloat

    @State private var rotationAngle: Angle = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.Stir.ink100, lineWidth: 2)
            Circle()
                .trim(from: 0.0, to: 0.25)
                .stroke(
                    Color.Stir.ember600,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round),
                )
                .rotationEffect(rotationAngle)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Loading")
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                rotationAngle = .degrees(360)
            }
        }
    }
}

// MARK: - Previews

#Preview("Loading — light") {
    LoadingView()
        .frame(width: 390, height: 844)
        .preferredColorScheme(.light)
}

#Preview("Loading — dark") {
    LoadingView()
        .frame(width: 390, height: 844)
        .preferredColorScheme(.dark)
}

#Preview("Loading — session restore") {
    LoadingView(restoreCaption: "Picking up where you left off…")
        .frame(width: 390, height: 844)
        .preferredColorScheme(.light)
}
