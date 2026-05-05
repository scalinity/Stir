// CoachMarkSpotlight
//
// Full-screen dim layer with a rounded-rect cutout around the active
// step's anchor frame. Halo glow + reduce-motion-aware pulse signal
// "do this" without obscuring the target.
//
// Drawn with `Canvas` so the cutout is a single composited path —
// avoids the multi-layer mask shenanigans of `BlendMode.destinationOut`
// which break under iOS 17's strict-concurrency-related view tree
// reconciliation.

import SwiftUI

struct CoachMarkSpotlight: View {
    let targetFrame: CGRect?
    let isPulsing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// Inset around the target — gives the cutout breathing room so
    /// the rounded corners don't clip the highlighted control.
    private let padding: CGFloat = 8
    private let cornerRadius: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            // Full-screen dim — ink900 at 55% alpha clears WCAG AAA on
            // paper100 cards above. Resolved at draw time so light /
            // dark trait changes propagate without a State refresh.
            let dim = context.resolve(.color(Color.Stir.ink900.opacity(0.55)))
            let bounds = CGRect(origin: .zero, size: size)
            var dimPath = Path(bounds)
            if let target = expandedTarget(for: bounds) {
                dimPath.addRoundedRect(
                    in: target,
                    cornerSize: CGSize(width: cornerRadius, height: cornerRadius),
                )
                context.fill(dimPath, with: dim, style: FillStyle(eoFill: true))
            } else {
                // No anchor (centered step) — fill the whole screen.
                context.fill(dimPath, with: dim)
            }
        }
        .ignoresSafeArea()
        .overlay {
            if let target = targetFrame {
                halo(target: target)
            }
        }
        .accessibilityHidden(true)
        .onAppear { startPulse() }
        .onChange(of: isPulsing) { _, newValue in
            if newValue {
                startPulse()
            } else {
                // Wrap in a zero-duration animation so SwiftUI cleanly
                // commits the off-state instead of snapping mid-cycle
                // from the prior `repeatForever` keyframe — visible
                // stutter at step transitions otherwise.
                withAnimation(.linear(duration: 0)) {
                    pulse = false
                }
            }
        }
    }

    private func expandedTarget(for bounds: CGRect) -> CGRect? {
        guard let target = targetFrame else { return nil }
        return target
            .insetBy(dx: -padding, dy: -padding)
            .intersection(bounds)
    }

    /// Ember halo stroked just outside the cutout. Static at 100%, with
    /// an additive pulse-scale ring when `isPulsing`. Reduce-motion
    /// renders the pulse ring static (no scale animation).
    @ViewBuilder
    private func halo(target: CGRect) -> some View {
        let expanded = target.insetBy(dx: -padding, dy: -padding)
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.Stir.ember600, lineWidth: 2)
                .frame(width: expanded.width, height: expanded.height)
                .position(x: expanded.midX, y: expanded.midY)
            if isPulsing {
                RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                    .stroke(Color.Stir.ember600.opacity(0.45), lineWidth: 4)
                    .frame(width: expanded.width, height: expanded.height)
                    .position(x: expanded.midX, y: expanded.midY)
                    .scaleEffect(reduceMotion ? 1.0 : (pulse ? 1.06 : 1.0))
                    .opacity(reduceMotion ? 0.7 : (pulse ? 0.0 : 0.7))
            }
        }
        .allowsHitTesting(false)
    }

    private func startPulse() {
        guard isPulsing, !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
            pulse = true
        }
    }
}
