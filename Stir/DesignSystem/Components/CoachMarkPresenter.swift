// CoachMarkPresenter
//
// View modifier that owns a `CoachMarkController` and renders the
// active coach-mark step (spotlight + card) above the host content.
//
// Responsibilities:
//   1. Capture per-screen anchor frames into a coordinate-space-named
//      registry the spotlight can read.
//   2. Auto-start the sequence on first appear when the gate is open
//      (manager not completed AND `shouldPresent` true). A 350ms
//      settle delay matches the `TutorialPresenter` modifier so the
//      first frame paints before the overlay slides in.
//   3. Re-arm when the manager's completion set flips (Settings
//      replay path resets the key, the host re-appears, the gate
//      re-opens, the sequence restarts).
//   4. Gracefully cancel on disappear via
//      `controller.cancelDueToDisappear()` so a navigated-away tour
//      writes its terminal flag rather than resurrecting next visit.
//   5. Inject `controller` into the environment so feature views can
//      call `coachMarks.completeAction(.shutterTap)` from real-action
//      handlers without prop-drilling.
//
// Re-uses the same observable manager + telemetry plumbing as the
// existing `TutorialPresenter`, so a fully resolved coach-mark walks
// through the standard `tutorial_started → step_advanced* → completed`
// funnel.

import SwiftUI

// MARK: - Layout constants

/// Vertical distance from the anchor's matching edge to the card's
/// CENTER point. 120pt clears the spotlight halo on iPhone 15-class
/// screens without leaving the card visually disconnected from its
/// anchor.
private let cardCenterOffset: CGFloat = 120

/// Minimum distance from a screen edge to the card's CENTER. Keeps
/// the card clear of status-bar and home-indicator safe areas at
/// roughly the card's half-height.
private let cardEdgeClamp: CGFloat = 140

/// Maximum card width. Caps line-length on iPad widths and keeps the
/// card visually contained on iPhone Plus-class screens.
private let cardMaxWidth: CGFloat = 360

/// Environment key that vends the active screen's `CoachMarkController`.
/// Default-nil means "no coach-mark presenter in this subtree" — calls
/// like `controller.completeAction(...)` no-op safely.
private struct CoachMarkControllerKey: EnvironmentKey {
    static let defaultValue: CoachMarkController? = nil
}

extension EnvironmentValues {
    /// Active screen's coach-mark controller, or nil if no presenter
    /// is wrapping this view tree.
    var coachMarks: CoachMarkController? {
        get { self[CoachMarkControllerKey.self] }
        set { self[CoachMarkControllerKey.self] = newValue }
    }
}

struct CoachMarkPresenterModifier: ViewModifier {
    let key: TutorialKey
    let steps: [CoachMarkStep]
    let shouldPresent: Bool
    @Bindable var manager: TutorialManager

    @State private var controller: CoachMarkController
    @State private var anchorFrames: [CoachMarkAnchorID: CGRect] = [:]

    init(
        key: TutorialKey,
        steps: [CoachMarkStep],
        shouldPresent: Bool,
        manager: TutorialManager,
    ) {
        self.key = key
        self.steps = steps
        self.shouldPresent = shouldPresent
        _manager = Bindable(manager)
        _controller = State(
            initialValue: CoachMarkController(key: key, steps: steps, manager: manager),
        )
    }

    /// Open while the gate allows AND the controller hasn't yet
    /// terminated this presentation cycle. Composed so any change in
    /// the manager's completed set OR the host's `shouldPresent`
    /// re-evaluates without an extra @State flag.
    private var gateOpen: Bool {
        !manager.isCompleted(key) && shouldPresent
    }

    func body(content: Content) -> some View {
        let spaceName = coachMarkCoordinateSpace(for: key)
        content
            .environment(\.coachMarks, controller)
            // Per-key coordinate-space name eliminates collisions when
            // two presenters end up nested in the view tree (e.g. tab
            // root + detail screen both with active tutorials).
            .coordinateSpace(name: spaceName)
            .environment(\.coachMarkCoordinateSpaceName, spaceName)
            .onCoachMarkAnchorsChanged { frames in
                anchorFrames = frames
            }
            .overlay {
                if controller.isPresenting, let step = controller.currentStep {
                    overlayContent(step: step)
                }
            }
            // `.task(id: gateOpen)` re-fires whenever the gate flips.
            // Open → settle delay → start() (replay path: manager.reset
            // flips completedKeys → gateOpen flips true → re-fire).
            // Closed → cancellation propagates (Task.sleep throws) AND
            // we explicitly suspend the controller so a stale overlay
            // pinned to last-known geometry doesn't linger when the
            // host's `shouldPresent` predicate flips false mid-tour.
            // Suspend serializes against `.task` cancellation in a
            // separate `.onChange` so the SwiftUI mutation order is
            // deterministic (SCA-17 W7). The earlier "suspend inside
            // the task body" path could interleave with the new task's
            // start under fast gate flips, leaving isPresenting=false
            // even though the gate was open.
            .onChange(of: gateOpen) { _, newValue in
                if !newValue {
                    controller.suspend()
                }
            }
            .task(id: gateOpen) {
                guard gateOpen else { return }
                do {
                    try await Task.sleep(for: tutorialPresentationSettleDelay)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                guard gateOpen else { return }
                controller.start()
            }
            .onDisappear {
                // Disappear is non-terminal — see CoachMarkController's
                // lifecycle invariant. `suspend()` tears down the
                // overlay without writing the durable completion flag,
                // so the tutorial re-arms on re-appear.
                controller.suspend()
            }
    }

    @ViewBuilder
    private func overlayContent(step: CoachMarkStep) -> some View {
        let target = step.anchor.flatMap { anchorFrames[$0] }
        let isActionGated = step.requiredAction != nil
        ZStack {
            CoachMarkSpotlight(
                targetFrame: target,
                isPulsing: isActionGated,
            )
            .transition(.opacity)
            // Required-action steps must let the real control receive
            // the user's tap (shutter, Solve, Next, etc.) — disabling
            // hit-testing on the spotlight allows the spotlit control
            // beneath to receive both touch AND VoiceOver focus.
            // Info-only steps trap the tap so anywhere on the dim
            // advances the tutorial.
            .allowsHitTesting(!isActionGated)
            .onTapGesture {
                // Only reachable on info-only steps (action-gated path
                // has hit-testing disabled above).
                controller.advance()
            }
            cardLayer(step: step, targetFrame: target)
                .transition(.opacity)
                // SCA-17 W15 — card reads first so the user hears the
                // step instructions before VoiceOver lands on the
                // spotlit control (action-gated steps make the
                // underlying control focusable via the spotlight's
                // `.allowsHitTesting(false)`).
                .accessibilitySortPriority(2)
        }
        .animation(.easeInOut(duration: 0.2), value: controller.currentIndex)
        // SCA-17 W14 — flag the overlay as modal so VoiceOver
        // communicates the modal scope to assistive-tech users.
        // (Action-gated steps still let the spotlit control receive
        // focus via `.allowsHitTesting(false)` on the spotlight.)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func cardLayer(step: CoachMarkStep, targetFrame: CGRect?) -> some View {
        GeometryReader { proxy in
            // The CoachMarkCard MUST be the closure's trailing expression
            // — a `let card = …` binding here renders nothing because
            // ViewBuilder/GeometryReader content emits only the last
            // expression in the block, never a discarded binding. SCA-15
            // shipped with `let card =` and showed dim+spotlight only.
            CoachMarkCard(
                step: step,
                stepNumber: controller.currentIndex + 1,
                totalSteps: steps.count,
                isFinalStep: controller.isFinalStep,
                onSkip: { controller.skip() },
                onAdvance: { controller.advance() },
            )
            .frame(maxWidth: cardMaxWidth)
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .position(
                cardPosition(
                    in: proxy.size,
                    targetFrame: targetFrame,
                    placement: step.placement,
                ),
            )
        }
    }

    /// Place the card above, below, or centered relative to the anchor.
    /// `.auto` chooses below if the anchor is in the upper third of the
    /// screen and above otherwise.
    ///
    /// Layout constants:
    ///   - 120pt: vertical offset of the card's CENTER point from the
    ///     anchor's matching edge. Sized so the card visually clears
    ///     the spotlight halo on iPhone 15-class devices.
    ///   - 140pt: minimum distance from screen edge to the card's
    ///     CENTER, so the card itself stays clear of the
    ///     status / home-indicator safe areas.
    private func cardPosition(
        in screenSize: CGSize,
        targetFrame: CGRect?,
        placement: CoachMarkPlacement,
    ) -> CGPoint {
        let center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
        guard let target = targetFrame else { return center }
        let resolved = ResolvedPlacement.resolve(placement, target: target, screenSize: screenSize)

        switch resolved {
        case .center:
            return center
        case .below:
            let proposedY = target.maxY + cardCenterOffset
            let clampedY = min(proposedY, screenSize.height - cardEdgeClamp)
            // **Behind-anchor fallback (SCA-17 W2):** if the safe-area
            // clamp pulled the card up INTO its own spotlight target
            // (typical on tall anchors near the bottom of the screen),
            // flip to .above placement instead. Without this, the
            // card overlays its own spotlight — bites
            // `populated_edit_remove` and `dishMeta` on shorter
            // devices.
            if clampedY < target.maxY + cardEdgeClamp / 2 {
                return positionAbove(target: target, screenSize: screenSize)
            }
            return CGPoint(x: screenSize.width / 2, y: clampedY)
        case .above:
            let proposedY = target.minY - cardCenterOffset
            let clampedY = max(proposedY, cardEdgeClamp)
            // Symmetric: if the top-edge clamp pulled the card down
            // into its anchor, flip to .below.
            if clampedY > target.minY - cardEdgeClamp / 2 {
                return positionBelow(target: target, screenSize: screenSize)
            }
            return CGPoint(x: screenSize.width / 2, y: clampedY)
        }
    }

    /// Direct .below positioning without the W2 fallback recursion —
    /// used as the .above-failed escape hatch. Clamps to safe area
    /// but does NOT re-check for behind-anchor (we already know
    /// .above failed; .below is best-effort).
    private func positionBelow(target: CGRect, screenSize: CGSize) -> CGPoint {
        let proposedY = target.maxY + cardCenterOffset
        let clampedY = min(proposedY, screenSize.height - cardEdgeClamp)
        return CGPoint(x: screenSize.width / 2, y: clampedY)
    }

    private func positionAbove(target: CGRect, screenSize: CGSize) -> CGPoint {
        let proposedY = target.minY - cardCenterOffset
        let clampedY = max(proposedY, cardEdgeClamp)
        return CGPoint(x: screenSize.width / 2, y: clampedY)
    }

    /// Auto-resolved placement. Distinct enum from `CoachMarkPlacement`
    /// so the second `switch` can be exhaustive without a dead `.auto`
    /// arm — Swift's exhaustiveness check on a 4-case enum was forcing
    /// an unreachable arm, which read like there was a third branch
    /// to maintain. (Review S4.)
    private enum ResolvedPlacement {
        case above, below, center

        static func resolve(
            _ placement: CoachMarkPlacement,
            target: CGRect,
            screenSize: CGSize,
        ) -> ResolvedPlacement {
            switch placement {
            case .center: return .center
            case .above:  return .above
            case .below:  return .below
            case .auto:
                return target.midY < screenSize.height / 3 ? .below : .above
            }
        }
    }
}

extension View {
    /// Attach a coach-mark sequence to this view. Auto-presents on
    /// first appear when the gate is open; persists completion via
    /// `TutorialManager`. Pass a `Bool` (not an autoclosure) so
    /// SwiftUI's value-propagation drives re-evaluation when host
    /// state changes — same lesson as `TutorialPresenter`.
    func coachMarks(
        key: TutorialKey,
        steps: [CoachMarkStep],
        shouldPresent: Bool = true,
        manager: TutorialManager = .shared,
    ) -> some View {
        modifier(
            CoachMarkPresenterModifier(
                key: key,
                steps: steps,
                shouldPresent: shouldPresent,
                manager: manager,
            ),
        )
    }
}
