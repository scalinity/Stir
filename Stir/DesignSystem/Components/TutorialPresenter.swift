// TutorialPresenter
//
// Generic first-run-tutorial presenter modifier.
//
// ====================================================================
// CHOOSING A PRESENTER (SCA-17 W10)
// ====================================================================
// Two presenter shapes ship under `Stir/DesignSystem/Components/`:
//
//   • **TutorialPresenter** (this file) — full-screen `fullScreenCover`
//     with multi-step page-dot UI built around `TutorialFlowContainer`
//     + `TutorialStepView`. Used for first-run welcome / orientation
//     tours where the user is NOT mid-task and the tour OWNS the
//     screen. v1: `tonightTour` only.
//
//   • **CoachMarkPresenter** (sibling file) — anchored spotlight +
//     floating card overlaid on the live screen. The user IS mid-task
//     and may be expected to perform the gated action (shutter tap,
//     Solve tap, etc.) AS the tour advances. v1: 8 sequences (scan,
//     dinner, dish, cook, voice, pantry x2 variants, etc.).
//
// Pick by the user's posture, not by step count:
//   - "First-run welcome, before any task" → TutorialPresenter
//   - "Contextual tip on a real surface" → CoachMarkPresenter
//
// Both presenters share `tutorialPresentationSettleDelay` (350ms) and
// observe the same `TutorialManager`; replay surfaces work identically
// across both via `RootCoordinator.replayAllTutorials()` /
// `manager.reset(_:)` and the new per-key `TutorialReplayView`.
// ====================================================================
//
// Replaces the prior `TutorialPresenterModifier` (formerly co-located
// with `TonightWelcomeTutorial.swift`). Rewritten to address the
// review-5 critical findings:
//   - Drops `_TutorialHost` indirection: the tutorial view reads
//     `@Environment(\.dismiss)` directly. (review CR1 W2)
//   - Drops `AnyView` type-erasure by going generic over `Inner: View`.
//     (review CR1 W1, CA1 W1)
//   - Drops `@autoclosure shouldPresent` in favor of a plain `Bool`
//     value parameter, so SwiftUI's normal value-propagation drives
//     re-evaluation rather than a stored closure capturing stale state.
//     (review CR1 #2, DB2 W1, CA1 W3)
//   - Drops the sticky `@State didCheck` latch that broke Settings
//     replay. Presentation is now driven by:
//       * an observable `TutorialManager` (so `reset(_:)` fires
//         `@Observable` invalidation and the modifier re-evaluates);
//       * `.task(id:)` for the 350ms settle delay, so SwiftUI
//         auto-cancels the structured task on view disappearance —
//         no more present-after-disappear races. (review DB1 #1,
//         DB2 #1+#2, DB3 #1)
//
// Resolution flow: the inner tutorial owns its own `@Environment(\.dismiss)`,
// calls `dismiss()` after writing `manager.markCompleted(key)`. The
// modifier observes the manager's completion set; the next gate-check
// reads `true` and the cover stays down.

import SwiftUI

/// Settle delay between "preconditions met" and the cover sliding up.
/// Lets the host view's first frame land before the cover animation
/// starts; without it, the two race and the cover loses an animation
/// tick on slow devices. Named token rather than a magic literal so
/// `grep` finds the usage. (review CR1 W6)
let tutorialPresentationSettleDelay: Duration = .milliseconds(350)

/// Modifier that presents a tutorial cover the first time
/// `manager.isCompleted(key)` is `false` and `shouldPresent` evaluates
/// `true`. Generic over the inner view so SwiftUI's structural diffing
/// is preserved end-to-end.
struct TutorialPresenterModifier<Inner: View>: ViewModifier {
    let key: TutorialKey
    @Bindable var manager: TutorialManager
    let shouldPresent: Bool
    @ViewBuilder let tutorial: () -> Inner

    @State private var isPresenting = false

    /// Single source-of-truth bool for "the cover should be up right
    /// now". Combines durable completion state (manager) + caller-
    /// supplied gating (`shouldPresent`). Computed, not stored — every
    /// view-body re-eval reads the current value and SwiftUI handles
    /// the diff.
    private var gateOpen: Bool {
        !manager.isCompleted(key) && shouldPresent
    }

    func body(content: Content) -> some View {
        content
            // `.task(id:)` re-runs every time `gateOpen` changes and is
            // auto-cancelled on view disappearance. That property
            // simultaneously fixes the Settings-replay flow (manager
            // reset flips `gateOpen` true → task re-fires) AND the
            // present-after-disappear race (task cancels when the host
            // tab leaves the hierarchy).
            .task(id: gateOpen) {
                guard gateOpen, !isPresenting else { return }
                do {
                    try await Task.sleep(for: tutorialPresentationSettleDelay)
                } catch {
                    // Task was cancelled (view disappeared, or
                    // gateOpen flipped back to false). Bail without
                    // mutating presentation state.
                    return
                }
                // Re-check both inputs after the sleep — same belt-
                // and-suspenders the prior implementation had, now
                // backed by a properly cancellable task.
                guard gateOpen, !isPresenting else { return }
                isPresenting = true
            }
            .fullScreenCover(isPresented: $isPresenting) {
                // `fullScreenCover` content is torn down + rebuilt on
                // each present cycle, so the inner tutorial's `@State`
                // resets across presentations — that's how the
                // Settings replay reaches a fresh start each time.
                // Cover cannot be swipe-dismissed (Apple contract on
                // iOS 17+), so resolution always routes through the
                // inner tutorial's Done/Skip path which calls
                // `manager.markCompleted` + `dismiss()`.
                tutorial()
            }
    }
}

extension View {
    /// Present a tutorial the first time this view appears, gated on
    /// completion state in `manager` plus a caller-supplied `Bool`
    /// precondition. Both completion AND skip terminate via
    /// `manager.markCompleted(key)` (the inner tutorial's responsibility);
    /// the modifier itself only observes that flag.
    ///
    /// `shouldPresent` is a plain `Bool` (not an autoclosure) so SwiftUI's
    /// value-propagation handles re-evaluation. Pass any expression that
    /// evaluates to `true` once the host's preconditions are satisfied —
    /// e.g. `phase == .ready && profile?.onboardingCompleted == true`.
    /// Argument order matches `coachMarks(key:steps:shouldPresent:manager:)`
    /// so contributors switching between the two presenters get
    /// uniform muscle memory (SCA-17 W11).
    func tutorial<Inner: View>(
        key: TutorialKey,
        @ViewBuilder content: @escaping () -> Inner,
        shouldPresent: Bool = true,
        manager: TutorialManager = .shared,
    ) -> some View {
        modifier(
            TutorialPresenterModifier(
                key: key,
                manager: manager,
                shouldPresent: shouldPresent,
                tutorial: content,
            ),
        )
    }
}
