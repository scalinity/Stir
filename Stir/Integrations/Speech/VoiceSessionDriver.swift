// VoiceSessionDriver
//
// Protocol that abstracts a voice cook session driver. Two conformances
// exist in the product:
//   - SpeechFallbackService (C.3) — on-device STT + /v1/ai/cook-turn +
//     AVSpeechSynthesizer. Always available; used as the degraded path.
//   - RealtimeSession (C.2, deferred per ADR 0007) — Gemini Live
//     WebSocket with native audio in + out. Premium+ primary path.
//
// CookModeViewModel holds `any VoiceSessionDriver` — one interface for
// both paths so voice UX isn't branched by driver type in the view layer.
// Path discrimination for telemetry happens via the `pathLabel` property;
// neither driver changes behavior based on it, but the VM and analytics
// layer tag events.
//
// Lifecycle:
//   1. Constructor — cheap; no hardware touched yet.
//   2. `preWarm()` — Cook Mode entry. Request permissions, load
//      recognizers/voices, open WebSocket (C.2). Moves state machine
//      from `.idle` to `.ready`. Caller awaits before first `beginTurn`.
//   3. `beginTurn()` — user tapped the mic. Starts listening.
//   4. `endTurn(...)` — user tapped again / server VAD closed the turn.
//      Persists VoiceTurn rows, returns the model's response.
//   5. `speak(_:)` — render the model's `spoken_response` out loud.
//   6. `cancelSpeaking()` — user interrupted (tap while speaking).
//   7. `close()` — Cook Mode exit. Release AVAudioSession, tear down
//      recognizer + synthesizer + WebSocket. IDEMPOTENT per ADR 0007
//      pre-commit (leaked audio session → mic indicator stuck on).

import Foundation

/// Which voice path a conforming driver represents. Stamped on the
/// `cook_turn_submitted` / `cook_turn_resolved` PostHog events as the
/// spec §15 `path` property. Values match the spec verbatim.
enum VoiceSessionPath: String, Sendable, Equatable {
    case liveAPI = "live_api"
    case geminiFallback = "gemini_fallback"
}

@MainActor
protocol VoiceSessionDriver: AnyObject {
    /// Which voice path this driver implements. Used by the telemetry
    /// layer; drivers themselves don't branch on it.
    var pathLabel: VoiceSessionPath { get }

    /// Current voice-session state. Observed by the view layer to
    /// render mic / waveform / thinking affordances. Changes on every
    /// legal transition per VoiceSessionStateMachine.
    var currentState: VoiceSessionState { get }

    /// Pre-warm. Request permissions, load recognizers, open WebSockets.
    /// Caller awaits before the first `beginTurn`. Throws on permission
    /// denial or hardware unavailability; CookModeViewModel maps the
    /// failure to a `screen_error_shown` event + inline toast.
    func preWarm() async throws

    /// Begin listening for a user turn. Tap-to-speak; caller calls
    /// `endTurn` when the user taps again.
    func beginTurn() async throws

    /// End listening + dispatch to backend + persist user + model
    /// VoiceTurn rows. Returns the model's response so CookModeViewModel
    /// can immediately call `speak(response.spokenResponse)`.
    func endTurn(
        recipeContext: RealtimeRecipeContext,
        householdContext: RealtimeHouseholdContext,
        currentStepNumber: Int,
        recipePlanId: UUID,
    ) async throws -> CookTurnResult

    /// Render the given text via speech synthesis. Async; resolves
    /// when the utterance finishes speaking.
    func speak(_ text: String) async

    /// Interrupt any in-flight speech. No-op if not speaking.
    func cancelSpeaking()

    /// Teardown. Idempotent — safe to call multiple times. Must
    /// release AVAudioSession so the system mic indicator drops;
    /// failing to do so leaves the indicator stuck on after Cook
    /// Mode exit.
    func close()
}
