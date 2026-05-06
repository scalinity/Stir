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
            // Full-screen scrim — fixed dark dim, theme-INDEPENDENT.
            // SCA-18: previously used `Color.Stir.ink900.opacity(0.55)`
            // which inverts in dark mode (ink900 dark = 0xF5F0E8 cream),
            // producing a WHITE wash over the dark Stir background. A
            // scrim is by definition a darkening layer regardless of
            // theme, so use a fixed `Color.black` here. If a second
            // scrim site appears, promote to `Color.Stir.scrim`.
            let dim = context.resolve(.color(Color.black.opacity(0.55)))
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
            // **Off-screen-anchor guard (SCA-17 W3):** if the anchor
            // has scrolled out of bounds, `expandedTarget(for: full-
            // screen-bounds)` returns nil (intersection collapses to
            // .null/.isEmpty). Halo MUST honor the same guard or it
            // renders at the off-screen position while the dim layer
            // covers the whole screen — locking the user out of
            // action-gated steps.
            //
            // We compose the halo against the visible-bounds-clamped
            // target so the halo only renders when there's a sane
            // on-screen rect to spotlight.
            GeometryReader { proxy in
                if let target = visibleTarget(in: proxy.size) {
                    halo(target: target)
                }
            }
        }
        .accessibilityHidden(true)
        .onAppear { startPulse() }
        .onChange(of: isPulsing) { _, newValue in
            if newValue {
                startPulse()
            } else {
                // Reset OUTSIDE any animation context so the value
                // commits without a transaction (`withAnimation
                // (.linear(duration: 0))` does NOT cancel a
                // `repeatForever` curve — SwiftUI's implicit-animation
                // API has no stop affordance once `repeatForever` is
                // attached). The visible "stop" is owed to the halo
                // modifier reading `isPulsing` directly (see `halo()`
                // below) and snapping to the static frame when
                // `isPulsing` flips false. SCA-17 W1.
                var txn = Transaction()
                txn.disablesAnimations = true
                withTransaction(txn) {
                    pulse = false
                }
            }
        }
    }

    /// Padded target rect clipped to drawing bounds. Returns nil if
    /// the anchor is fully off-screen (intersection collapses to
    /// `.null` or `.isEmpty`) so callers fall through to the
    /// no-anchor path. Without this guard, an off-screen anchor would
    /// `addRoundedRect(in: .null)` (undefined drawing) and the halo
    /// overlay would render outside the visible area, leaving the dim
    /// layer covering the whole screen with no dismissable target —
    /// locking action-gated tours. SCA-17 W3.
    private func expandedTarget(for bounds: CGRect) -> CGRect? {
        guard let target = targetFrame else { return nil }
        let clipped = target
            .insetBy(dx: -padding, dy: -padding)
            .intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return clipped
    }

    /// Halo-side helper: returns the anchor's expanded rect IFF it's
    /// at least partially on screen. Mirrors `expandedTarget` but
    /// uses the overlay's geometry size (the screen) rather than the
    /// Canvas's drawing bounds.
    private func visibleTarget(in size: CGSize) -> CGRect? {
        guard let target = targetFrame else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let clipped = target
            .insetBy(dx: -padding, dy: -padding)
            .intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return clipped
    }

    /// Ember halo stroked just outside the cutout. Static at 100%, with
    /// an additive pulse-scale ring when `isPulsing`. Reduce-motion
    /// renders the pulse ring static (no scale animation).
    ///
    /// `target` is pre-expanded (passed in from `visibleTarget(in:)`)
    /// so callers and Canvas dim layer agree on the on-screen rect.
    @ViewBuilder
    private func halo(target: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.Stir.ember600, lineWidth: 2)
                .frame(width: target.width, height: target.height)
                .position(x: target.midX, y: target.midY)
            if isPulsing {
                RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
                    .stroke(Color.Stir.ember600.opacity(0.45), lineWidth: 4)
                    .frame(width: target.width, height: target.height)
                    .position(x: target.midX, y: target.midY)
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
