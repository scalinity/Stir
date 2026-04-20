// VoiceSessionState
//
// State machine shared between the C.3 Speech fallback path and the C.2
// Gemini Live path. C.3 exercises the `idle / userSpeaking / transcribing
// / thinking / modelSpeaking / error` subset; C.2 adds the `connecting /
// ready / toolCalling / refreshing / fallingBack / closed` transitions.
//
// Single enum (not separate enums per path) so:
//   - Cook Mode UI reads one `@Observable` property regardless of path
//   - Telemetry emits `from_state` / `to_state` with one vocabulary
//   - C.2's fall-back transition is typed: `fallingBack` moves the
//     shared state forward while the path-switch happens underneath
//
// Transitions are enforced by `VoiceSessionStateMachine.advance(to:)`
// below — illegal transitions crash at debug, log a warning and no-op at
// release. Tight enough to catch protocol bugs; loose enough not to
// crash production on a weird server race.

import Foundation
import OSLog

enum VoiceSessionState: String, Sendable, Equatable, CaseIterable {
    /// Default. No session active. No audio I/O configured.
    case idle

    /// C.2 only — minting token + opening WebSocket to Gemini Live.
    case connecting

    /// Session setup complete, awaiting user input. Both paths.
    case ready

    /// Mic hot, user is mid-utterance. Both paths.
    case userSpeaking

    /// C.3 only — SFSpeechRecognizer producing the transcript locally.
    case transcribing

    /// Awaiting model response (post-user-done, pre-audio). Both paths.
    case thinking

    /// Model is speaking out loud. Both paths.
    case modelSpeaking

    /// C.2 only — model emitted a `toolCall` frame; waiting on the
    /// function result to come back from `/v1/ai/substitution`.
    case toolCalling

    /// C.2 only — mid-session refresh (10 min / 15 turn boundary).
    case refreshing

    /// C.2 only — Live session died; switching to C.3 path. Transient.
    case fallingBack

    /// Terminal transient error; UI should surface a retry or exit CTA.
    case error

    /// Session fully closed; AVAudioSession deactivated. Terminal.
    case closed
}

// MARK: - Legal transitions

extension VoiceSessionState {
    /// True iff transitioning from `self` to `next` is legal per the
    /// state machine grammar. Rules are intentionally permissive to any
    /// terminal state (`error`, `closed`) so cleanup paths don't need
    /// to unwind through every prior state.
    func canTransition(to next: VoiceSessionState) -> Bool {
        if next == .error || next == .closed { return self != next }
        switch self {
        case .idle:
            return next == .connecting || next == .ready
        case .connecting:
            return next == .ready
        case .ready:
            return next == .userSpeaking
        case .userSpeaking:
            // C.3 → transcribing; C.2 → thinking (server VAD completes the turn)
            return next == .transcribing || next == .thinking
        case .transcribing:
            return next == .thinking
        case .thinking:
            return next == .modelSpeaking || next == .toolCalling
        case .modelSpeaking:
            // Back to ready for the next turn, OR into a refresh (C.2).
            return next == .ready || next == .refreshing
        case .toolCalling:
            return next == .modelSpeaking
        case .refreshing:
            return next == .ready || next == .fallingBack
        case .fallingBack:
            return next == .ready || next == .error
        case .error, .closed:
            // Terminal. Re-entry requires a new session.
            return false
        }
    }
}

// MARK: - State machine

/// Thread-safe, main-actor-bound state machine. UI observes via
/// Combine-style publishing through an `@Observable` host (CookModeViewModel).
/// The machine itself doesn't publish — its host does.
@MainActor
final class VoiceSessionStateMachine {
    private(set) var state: VoiceSessionState = .idle

    /// Optional callback fired on every legal transition. CookModeViewModel
    /// uses this to emit PostHog transition events + update its published
    /// state. Runs synchronously before `state` is read back, so the
    /// callback sees both the old and new values.
    var onTransition: ((VoiceSessionState, VoiceSessionState) -> Void)?

    /// Request a transition. Returns true if legal + applied; false if
    /// the transition was illegal (state unchanged, warning logged).
    /// Debug builds assert on illegal transitions so protocol bugs
    /// surface loud.
    @discardableResult
    func advance(to next: VoiceSessionState) -> Bool {
        let current = state
        guard current.canTransition(to: next) else {
            Logger.voice.warning(
                "illegal_state_transition from=\(current.rawValue, privacy: .public) to=\(next.rawValue, privacy: .public)",
            )
            assertionFailure("Illegal voice session transition: \(current) → \(next)")
            return false
        }
        state = next
        onTransition?(current, next)
        Logger.voice.debug(
            "voice_state_transition from=\(current.rawValue, privacy: .public) to=\(next.rawValue, privacy: .public)",
        )
        return true
    }

    /// Force state to terminal without checking the legal-transition
    /// table. Used by error-recovery paths where we want to stop the
    /// machine regardless of where we're stuck.
    func forceClose() {
        let prior = state
        state = .closed
        onTransition?(prior, .closed)
        Logger.voice.info(
            "voice_state_force_closed from=\(prior.rawValue, privacy: .public)",
        )
    }
}
