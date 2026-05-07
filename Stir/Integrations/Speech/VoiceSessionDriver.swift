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

    /// Backend-minted voice session id, if this driver has one. Set
    /// only on the Live path (RealtimeSession.mintResponse.sessionID)
    /// after preWarm succeeds; nil on the fallback path (cook-turn is
    /// per-turn stateless). CookModeViewModel uses this as the PostHog
    /// `$ai_trace_id` for the close-summary $ai_trace event.
    var voiceSessionID: String? { get }

    /// Prompt version baked into the current voice session. Set on the
    /// Live path after preWarm (RealtimeSession.mintResponse.promptVersion);
    /// nil on fallback. VM includes this in the close-summary $ai_trace's
    /// $ai_input_state so dashboards can attribute session metadata to
    /// a specific prompt rollout.
    var voiceSessionPromptVersion: String? { get }

    /// Current voice-session state. Observed by the view layer to
    /// render mic / waveform / thinking affordances. Changes on every
    /// legal transition per VoiceSessionStateMachine.
    var currentState: VoiceSessionState { get }

    /// Latest audio peak amplitude in [0, 1] from whichever direction
    /// is currently active — mic input while the user is speaking,
    /// model output while Stir is speaking. 0 in idle / connecting /
    /// thinking states. Read by the voice-active Cook Mode UI's
    /// waveform on every TimelineView frame; the UI applies its own
    /// attack/decay smoothing on read so this getter just returns the
    /// freshest raw peak.
    var currentAudioLevel: Float { get }

    /// Pre-warm. Request permissions, load recognizers, open WebSockets.
    /// Caller awaits before the first `beginTurn`. Throws on permission
    /// denial or hardware unavailability; CookModeViewModel surfaces the
    /// failure as an inline toast + a `screen_error_shown` telemetry
    /// event.
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

    /// Interrupt any in-flight speech. Awaits the state-machine
    /// transition back to `.ready` before returning so the caller can
    /// immediately begin a new turn without hitting `.busy`. No-op if
    /// not speaking.
    func cancelSpeaking() async

    /// Teardown. Idempotent — safe to call multiple times. Must
    /// release AVAudioSession so the system mic indicator drops;
    /// failing to do so leaves the indicator stuck on after Cook
    /// Mode exit.
    ///
    /// SCA-76 invariant: `CookModeRoot` invokes the close path TWICE
    /// on the leftovers handoff — once via
    /// `closeVoiceSessionFromHost()` (SCA-57, called from
    /// `handlePostSubmit(.openLeftovers/.openPaywall)`) and once via
    /// `driverTeardown?()` on `.onDisappear`. Implementations MUST
    /// guard against double-close: no thrown errors, no duplicated
    /// telemetry events (e.g. `voice_session_closed`,
    /// `$ai_trace` close-summary), and no double-release of audio
    /// resources. The simplest pattern is a `private var isClosed`
    /// flag that early-returns on the second entry. Breaking this
    /// contract surfaces first as a `.onDisappear`-only crash on
    /// the leftovers handoff path.
    func close()
}

/// Default-nil conformances so test doubles and drivers that don't
/// participate in the PostHog $ai_trace lifecycle (e.g. fallback
/// stubs) don't have to opt in. Live drivers override with real values.
extension VoiceSessionDriver {
    var voiceSessionID: String? { nil }
    var voiceSessionPromptVersion: String? { nil }
    /// Default 0 for drivers that don't surface a real meter (Speech
    /// fallback, test doubles). The UI is robust to a permanently-flat
    /// signal — bars rest at their lowest amplitude. The Live path
    /// overrides this with `audioPipeline`-backed peak tracking.
    var currentAudioLevel: Float { 0 }
}
