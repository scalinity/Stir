// CoachMarkController
//
// Per-screen observable controller. Owned by `CoachMarkPresenter` and
// vended into the view tree via `.environment(\.coachMarks, controller)`
// so any descendant can call `controller.completeAction(.shutterTap)`
// without prop-drilling.
//
// Single-active-step semantics: at most one step is presented at a
// time. `advance()` walks forward; `skip()` jumps to the end and marks
// the tutorial completed via the injected `TutorialManager`.
//
// **Lifecycle invariant** (review-5 SCA-5b Critical #1, #2, #5):
//
// `suspend()` is called by the presenter modifier on `.onDisappear`.
// Disappear can fire for transient reasons (tab switch, NavigationStack
// push, intra-screen view-tree swap, system overlay) — none of those
// should mark the tutorial completed. `suspend()` only flips
// `isPresenting = false` so the overlay tears down; the durable
// completion flag remains untouched, and the tutorial re-arms when the
// host re-appears (and the gate is still open).
//
// Only the user-driven terminal actions (`advance` past the last step,
// `skip`) write `manager.markCompleted` and emit a terminal telemetry
// event. That keeps the funnel invariant ("exactly one of completed /
// skipped per started") robust against routine navigation.
//
// `start()` always resets `currentIndex = 0` so Settings replay (which
// resets the manager flag while the host is on-screen, flipping
// `gateOpen` true and re-firing `.task`) walks the user through the
// tour from the beginning rather than wherever the previous session
// left off.

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class CoachMarkController {
    let key: TutorialKey
    private let manager: TutorialManager
    private let posthog: PostHogClient
    private let steps: [CoachMarkStep]
    private(set) var currentIndex: Int = 0

    /// True while the overlay is mounted. Toggled by `start()` /
    /// `suspend()` / `finish()` — never by external callers.
    private(set) var isPresenting: Bool = false

    /// Flips true the first time `start()` fires a `tutorial_started`
    /// event during the current presentation cycle. Reset in
    /// `finish()` so each replay gets a fresh started→completed funnel.
    private var didFireStarted: Bool = false

    /// Snapshot of `manager.resetGeneration` taken at each `start()`.
    /// Used by the SCA-17 C3 "replay during suspend" path: if the
    /// counter advanced between two start() calls (e.g., Settings →
    /// Replay tutorials fired while we were suspended on a different
    /// tab), the next start treats the cycle as a fresh replay
    /// (resets to step 0, re-fires `tutorial_started`).
    private var lastSeenResetGeneration: Int = -1

    init(
        key: TutorialKey,
        steps: [CoachMarkStep],
        manager: TutorialManager = .shared,
        posthog: PostHogClient = .shared,
    ) {
        self.key = key
        self.steps = steps
        self.manager = manager
        self.posthog = posthog
    }

    /// Active step or nil if the overlay is not currently presenting.
    var currentStep: CoachMarkStep? {
        guard isPresenting, currentIndex < steps.count else { return nil }
        return steps[currentIndex]
    }

    var isFinalStep: Bool {
        currentIndex == steps.count - 1
    }

    /// Begin or resume the sequence. Idempotent under concurrent
    /// callers (re-call while presenting is a no-op). Empty `steps`
    /// is a no-op — guards against a sequence accidentally shipping
    /// without any steps.
    ///
    /// Two flow distinctions:
    ///   - **Fresh start / replay**: post-`finish()` (or first call
    ///     ever), `currentIndex` ≥ steps.count or `didFireStarted`
    ///     was reset. Walk the user from step 0 and emit
    ///     `tutorial_started`.
    ///   - **Resume from suspend**: `suspend()` left `currentIndex`
    ///     mid-tour. A transient disappear-reappear cycle (tab
    ///     switch, NavigationStack push/pop) re-arms the controller
    ///     at the same step the user left, with no new
    ///     `tutorial_started` emit (the started event already fired
    ///     at the original entry).
    func start() {
        guard !steps.isEmpty else { return }
        guard !isPresenting else { return }
        // Discriminator: `didFireStarted` is true ONLY between the
        // first fresh start of a presentation cycle and finish() —
        // suspend() doesn't touch it. So:
        //   - false → fresh start or replay (post-finish, post-reset).
        //     Reset to step 0 and fire `tutorial_started`.
        //   - true → resume after a transient suspend. Preserve
        //     currentIndex; don't double-fire the started event.
        //
        // **Replay-while-suspended fix (SCA-17 C3):** if the manager's
        // resetGeneration counter advanced between this start() and
        // the previous one (e.g., Settings → Replay tutorials fired
        // while we were suspended on a different tab), treat the
        // cycle as a fresh replay even though `didFireStarted` is
        // still true from the prior presentation. Without this
        // signal, the user got a tour that resumed mid-step with no
        // `tutorial_started` event paired against the eventual
        // `tutorial_completed` — funnel pair broken. The counter
        // cleanly distinguishes "transient suspend" from "manager
        // mutated under us while suspended" without false-positives
        // on a fresh setUp() (which leaves manager.isCompleted(key)
        // false naturally).
        let currentGeneration = manager.resetGeneration
        let isReplay = didFireStarted
            && currentGeneration != lastSeenResetGeneration
        if !didFireStarted || isReplay {
            currentIndex = 0
            didFireStarted = true
            posthog.capture(.tutorialStarted, properties: [
                "tutorial_id": key.telemetryID,
            ])
        }
        lastSeenResetGeneration = currentGeneration
        isPresenting = true
    }

    /// Tap the Next button. Walks to the next step or, on the final
    /// step, marks the tutorial completed and dismisses.
    func advance() {
        guard isPresenting, let from = currentStep else { return }
        if isFinalStep {
            posthog.capture(.tutorialCompleted, properties: [
                "tutorial_id": key.telemetryID,
            ])
            finish()
        } else {
            let next = steps[currentIndex + 1]
            posthog.capture(.tutorialStepAdvanced, properties: [
                "tutorial_id": key.telemetryID,
                "from_step": from.telemetryID,
                "to_step": next.telemetryID,
            ])
            currentIndex += 1
        }
    }

    /// Tap the Skip button (always available). Marks the tutorial
    /// completed and dismisses.
    func skip() {
        guard isPresenting else { return }
        posthog.capture(.tutorialSkipped, properties: [
            "tutorial_id": key.telemetryID,
        ])
        finish()
    }

    /// Called by feature views when their primary action fires. If the
    /// active step was gated on `action`, advance; otherwise no-op.
    /// In DEBUG, a mismatch logs a breadcrumb so wiring drift between
    /// a sequence's `requiredAction` and the call site is visible
    /// during development.
    func completeAction(_ action: CoachMarkAction) {
        guard isPresenting, let step = currentStep else { return }
        guard step.requiredAction == action else {
            #if DEBUG
            // Visible-in-development signal — never reached in
            // release builds. Catches "we wired up `.shutterTap` but
            // the active step expects `.solveTap`" before it ships.
            if let required = step.requiredAction {
                Logger.ui.debug(
                    "coachmarks_action_mismatch step=\(step.id, privacy: .public) required=\(required.rawValue, privacy: .public) got=\(action.rawValue, privacy: .public)",
                )
            }
            #endif
            return
        }
        advance()
    }

    /// Host view disappeared (tab switch, NavigationStack push,
    /// view-tree swap, system overlay). Tear down the overlay but do
    /// NOT mark the tutorial completed — disappear is not a terminal
    /// signal. The tutorial re-arms when the host re-appears with the
    /// gate still open. Only `advance(past last)` and `skip()` are
    /// terminal.
    func suspend() {
        guard isPresenting else { return }
        isPresenting = false
        // currentIndex left as-is so a brief disappear-reappear cycle
        // resumes mid-tour; `start()` would reset it anyway on a
        // genuine fresh-mount path.
    }

    private func finish() {
        manager.markCompleted(key)
        isPresenting = false
        // Reset so the next `start()` (Settings replay path) emits
        // a fresh `tutorial_started` and the funnel sees a new pair.
        didFireStarted = false
    }
}
