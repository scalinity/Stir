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
            // Tap-to-start-session → .userSpeaking (original path).
            // VAD-driven next turn → .modelSpeaking directly when
            //   server emits audio without iOS seeing a .userSpeaking
            //   transition (hands-free mode: user speaks between turns
            //   while mic stays hot; iOS state at that moment is
            //   .ready and the first server frame is already model
            //   audio).
            // .toolCalling: hands-free path may also land a tool call
            //   between turns while state is .ready (VAD has closed
            //   the user's turn and the very first server frame is a
            //   toolCall). Observed 2026-04-22.
            // .refreshing: cadence + token-volume refresh triggers fire
            //   on the NEXT turn boundary (after finalizeTurn resets
            //   state to .ready), so entering .refreshing from .ready
            //   is the common path (P1-J, 2026-04-23).
            return next == .userSpeaking
                || next == .modelSpeaking
                || next == .toolCalling
                || next == .refreshing
        case .userSpeaking:
            // C.3 → transcribing.
            // C.2 hands-free: server VAD completes the turn server-
            //   side and iOS receives audio chunks while state is
            //   still .userSpeaking. Allow the direct jump to
            //   .modelSpeaking so handleServerContent can advance
            //   without a .thinking pit stop.
            // C.2 tap-to-end: VM advances to .thinking explicitly.
            // .ready is the cancellation / empty-turn fallback.
            // .toolCalling: model can emit advance_step / start_timer /
            //   substitution_check mid-utterance in hands-free mode
            //   before iOS has advanced past .userSpeaking (observed
            //   2026-04-22: model called advance_step while state was
            //   still .userSpeaking; handler dropped it, server sent
            //   toolCallCancellation, screen never advanced).
            return next == .transcribing
                || next == .thinking
                || next == .modelSpeaking
                || next == .ready
                || next == .toolCalling
        case .transcribing:
            return next == .thinking
        case .thinking:
            return next == .modelSpeaking
                || next == .toolCalling
                || next == .ready
                || next == .refreshing
        case .modelSpeaking:
            // Back to ready for the next turn, OR into a refresh (C.2),
            // OR into a tool call (mid-speech: rare but legal — the
            // model can interrupt its own spoken output with a tool
            // invocation).
            return next == .ready
                || next == .refreshing
                || next == .toolCalling
        case .toolCalling:
            // .refreshing added P1-J (2026-04-23): a tool-response that
            // triggers the cadence refresh threshold can fire a refresh
            // before the toolCalling → modelSpeaking transition lands.
            return next == .modelSpeaking
                || next == .refreshing
        case .refreshing:
            // P1-J (2026-04-23): on success, return to .ready uniformly
            // (prior state is captured by the caller if needed). On
            // failure, fallingBack or terminal.
            return next == .ready
                || next == .fallingBack
                || next == .userSpeaking
                || next == .modelSpeaking
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
    ///
    /// Self-transitions (current == next) are treated as idempotent
    /// no-ops rather than illegal — useful for re-entrant handlers like
    /// RealtimeSession.handleToolCall that may receive back-to-back
    /// toolCall frames while already `.toolCalling`. No callback fires;
    /// no log emission; caller sees `true` as if the request succeeded.
    @discardableResult
    func advance(to next: VoiceSessionState) -> Bool {
        let current = state
        if current == next { return true }
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
