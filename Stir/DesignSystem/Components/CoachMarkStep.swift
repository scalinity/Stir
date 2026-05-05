// CoachMarkStep
//
// Value type for one tutorial step. Sequences are arrays of these.
//
// Two flavors:
//   - `.spot(anchorID, copy, action?)` — anchored spotlight with an
//     attached card; optional required action.
//   - `.center(copy)` — full-bleed centered card with no spotlight.
//     Used for opening / closing context steps and for the voice-
//     command list which has no single anchor target.
//
// `requiredAction` lets a step gate advance on a real user action
// (e.g. tap the shutter) rather than the Next button. The presenter
// hides Next on those steps and waits for `controller.complete(action)`
// from the relevant view's handler. Skip is always available.

import SwiftUI

/// Discrete user action that can advance an action-gated coach-mark
/// step. The view that owns the action calls
/// `controller.completeAction(.shutterTap)` from its real-action
/// handler; the presenter advances if the active step was gated on it.
///
/// Cases here MUST have a corresponding `requiredAction:` step in some
/// sequence, otherwise the action is dead code. Add a case only when a
/// new step's required-action contract needs the symbol; remove it when
/// the contract goes away. The DEBUG-only mismatch breadcrumb in
/// `CoachMarkController.completeAction(_:)` flags wiring drift during
/// development — this enum's RawValue == String exists for that log.
enum CoachMarkAction: String, Hashable {
    case shutterTap
    case solveTap
    case cardTap
    case nextStepTap
    case startCookingTap
}

/// Where to place the card relative to the spotlight. `.auto` chooses
/// `.below` if the anchor's top sits in the upper third of the screen,
/// `.above` otherwise. `.center` ignores the anchor and centers the
/// card vertically.
enum CoachMarkPlacement: Hashable {
    case auto
    case above
    case below
    case center
}

/// One tutorial step.
struct CoachMarkStep: Identifiable, Hashable {
    /// Stable step identifier. Doubles as the telemetry token for
    /// `tutorial_step_advanced.from_step`/`to_step` — keeping the two
    /// in lock-step removes a parameter and prevents drift.
    let id: String
    let anchor: CoachMarkAnchorID?
    let placement: CoachMarkPlacement
    let title: String
    let message: String
    /// Optional inline list of voice command examples shown beneath
    /// the message — the voice tutorial uses this to enumerate the
    /// hands-free commands.
    let voiceExamples: [VoiceExample]
    /// If non-nil, the step waits for this action before advancing.
    /// The Next button is hidden and the spotlight halo pulses to
    /// signal "do this".
    let requiredAction: CoachMarkAction?

    init(
        id: String,
        anchor: CoachMarkAnchorID? = nil,
        placement: CoachMarkPlacement = .auto,
        title: String,
        message: String,
        voiceExamples: [VoiceExample] = [],
        requiredAction: CoachMarkAction? = nil,
    ) {
        self.id = id
        self.anchor = anchor
        self.placement = placement
        self.title = title
        self.message = message
        self.voiceExamples = voiceExamples
        self.requiredAction = requiredAction
    }

    /// Backward-compatible alias for callers / tests reading
    /// `step.telemetryID`. Identical to `id` — see init doc.
    var telemetryID: String { id }

    struct VoiceExample: Identifiable, Hashable {
        // `id = UUID()` is safe because every consumer of
        // `voiceExamples` is built from a `static let` sequence array
        // (e.g. `VoiceModeCoachMarks.steps`). Examples are constructed
        // once per process; `ForEach` diffing stays stable. Do NOT
        // refactor `static let` → computed property without
        // re-anchoring `id` to a stable derivation (e.g. `phrase`).
        let id = UUID()
        /// Quoted command the user can speak verbatim.
        let phrase: String
        /// Plain-language description of what it does.
        let does: String

        init(_ phrase: String, _ does: String) {
            self.phrase = phrase
            self.does = does
        }
    }
}
