// LoadingView
//
// Launch + session-restore skeleton shown while RootCoordinator.bootstrap()
// runs. Matches mockup 01 "Launch / Session Restore":
//
//   - Centered "Stir." wordmark in New York Regular, 80pt (§4.2
//     one-off hero size — NOT tokenized). The period is rendered in
//     ember.600 as the app's only mark of visual character (§2
//     "wordmark-only for v1"). The mockup HTML specifies Source
//     Serif 4 at 96pt / 600; iOS's system-serif (New York) renders
//     heavier at the same nominal weight, so this implementation
//     compensates with `.regular` at 80pt to match the mockup's
//     visual density. Restore the literal 96pt / `.semibold` if
//     Source Serif 4 is later bundled. Compensation is documented
//     in `Specs/Design-System.md` §4.2.
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

    /// Scales the 80pt launch wordmark with Dynamic Type. Review
    /// finding W-F W25 (FD1) — hero one-offs need `@ScaledMetric`
    /// so xxxLarge / Accessibility text users don't get a launch
    /// screen that ignores their preference.
    @ScaledMetric(relativeTo: .largeTitle) private var launchWordmarkSize: CGFloat = 80

    init(restoreCaption: String? = nil) {
        self.restoreCaption = restoreCaption
    }

    var body: some View {
        ZStack {
            Color.Stir.paper50
                .ignoresSafeArea()

            StirWordmark(sizePoints: launchWordmarkSize)
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
            // justification: wordmark sizes are one-off per §4.2 — bespoke per-screen (80pt Launch, 40pt Welcome tagline, 22pt Welcome top-left). System-serif (New York) renders heavier than Source Serif 4 at matching nominal weight, so `.regular` at 80pt visually matches the mockup's 96pt / SS4 600 reference. Compensation rule documented in `Specs/Design-System.md` §4.2.
            .font(.system(size: sizePoints, weight: .regular, design: .serif))
            // Tracking matches the mockup HTML literal (`letter-spacing: -0.04em`). Verified visually against the user-provided screenshot — `Stir.` reads tight but not collapsed at this size+weight. If a future redesign moves to a heavier weight or larger size, re-evaluate.
            .tracking(sizePoints * -0.04)
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
