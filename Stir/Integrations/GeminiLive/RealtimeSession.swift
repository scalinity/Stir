// RealtimeSession
//
// OpenAI Realtime (gpt-realtime-2.1-mini) driver. Conforms to
// VoiceSessionDriver so CookModeViewModel can hold `any VoiceSessionDriver`
// without branching on path type — telemetry keys off `pathLabel`.
//
// Lifecycle mirrors SpeechFallbackService:
//   preWarm  → mint client secret (via /v1/ai/realtime-session) + open WS +
//              send session.update + wait for session.updated + prepare
//              AudioPipeline. Throws on mint failure or setup timeout — VM
//              downgrades to C.3 on any preWarm error.
//   beginTurn → start mic capture, frames stream to WS as
//               input_audio_buffer.append.
//   endTurn   → flush mic, wait for the turn-completing response.done + any
//               tool-call round-trip, persist VoiceTurn, return result.
//   speak     → no-op on Live (audio already streamed during endTurn).
//   cancelSpeaking → stop audio player; user is about to begin a new turn.
//   close     → tear down WS + audio + audio session. Idempotent.
//
// Session refresh (ADR 0014, ADR 0038 decision 4): triggered when the
// current WebSocket has been open ≥ `LiveSessionBudget.refreshAtSessionAgeSec`
// (OpenAI caps a session at 60 minutes), with a pre-mint one turn boundary
// earlier. Per-turn context growth is bounded server-side by truncation,
// so there is no turn-count or token trigger: a refresh discards the
// provider's prompt cache, which is the main voice cost lever, and is
// worth paying only to outrun the session cap. The same machinery serves
// transport-error recovery.

import AVFoundation
import Foundation
import OSLog
import UIKit

/// Numeric budgets for the Live driver. Keeping them here (scoped to the
/// Live path) rather than in a global struct because every value is
/// Live-specific. Values tuned from device measurements + the
/// ADR 0010 / 0012 / 0014 / 0038 trigger re-checks documented inline.
///
/// P2-G (2026-04-23): `@MainActor` annotation dropped — the enum holds
/// only `Sendable` primitive `static let` values and needs no isolation.
/// The prior annotation forced every reader (including nonisolated
/// tests and the backend-shared constants file) to hop the MainActor
/// to read a pure constant, which is a footgun for future
/// Swift 6 strict-concurrency cleanups.
enum LiveSessionBudget {
    /// Seconds to wait for the server's `session.updated` handshake
    /// before failing `preWarm()`. Observed p95 is ~300 ms; 5 s is a
    /// generous upper bound.
    static let setupHandshakeSec: Double = 5
    /// Seconds to wait for the turn-completing `response.done` after
    /// user audio closes. 2× the observed ~15 s p95 for a long
    /// multi-sentence response.
    static let turnCompleteSec: Double = 30
    /// Age of the current WebSocket at which the next turn boundary
    /// triggers a session refresh. OpenAI's session maximum is 60
    /// minutes; 55 leaves five minutes for the refresh to land at a turn
    /// boundary (a long turn or a pause can delay it) before the server
    /// closes the socket. This is the only proactive refresh trigger
    /// (ADR 0038 decision 4): the earlier turn-count and prompt-token
    /// triggers existed to bound per-turn context growth, which
    /// server-side truncation now does, and each refresh throws away the
    /// provider's prompt cache.
    static let refreshAtSessionAgeSec: TimeInterval = 55 * 60
    /// Age at which a turn boundary kicks off the refresh's token mint in
    /// the background, one minute ahead of `refreshAtSessionAgeSec`, so
    /// the handoff doesn't pay the ~1.5-1.9 s mint round-trip.
    static let preMintAtSessionAgeSec: TimeInterval = 54 * 60
    /// Upper bound on how long we wait for `usageMetadata` to arrive
    /// after `turnComplete` before firing the voice-turn-usage POST
    /// with whatever tokens we have (zero if nothing arrived). Usage
    /// rides in the same `response.done` as the turn completion and is
    /// emitted ahead of it, so this is a defensive backstop; 2 s keeps
    /// dashboards from lagging if a response ever ends without usage.
    static let pendingReportTimeoutSec: Double = 2

    /// P2-F (2026-04-23): consolidated the three per-class tunable
    /// timings that used to live as `private static let` scattered
    /// through `RealtimeSession`. Keeping them on the budget enum
    /// makes the "where do I tune Live-path timings" question have
    /// one answer.
    ///
    /// How long a turn may sit in `.modelSpeaking` with no inbound
    /// audio chunks before the watchdog force-advances. Raised from
    /// 8 s → 15 s on 2026-04-23 (P1-E) because the 8 s threshold
    /// fired on legitimate multi-pass tool-call gaps (the model
    /// preparing the next audio pass after a tool response —
    /// measured ~11 s worst case). Still needed on OpenAI: the client
    /// owns every transition the server is supposed to drive, so a
    /// dropped or failed `response.done` must not pin `.modelSpeaking`.
    static let turnStuckWatchdogSec: TimeInterval = 15
    /// AEC + room-reverb cooldown after playback ends, before we
    /// re-open the mic. Tuned from a 2026-04-22 observation that
    /// server-side VAD fired on a -30 dB residual inside the
    /// cooldown window.
    static let echoCooldownSec: TimeInterval = 0.5
    /// Pre-mint Task staleness window, judged from when the mint was
    /// kicked off because the response (and its `expires_at`) isn't
    /// visible until the Task resolves. The client secret can open a
    /// connection for 120 s after mint; 90 s leaves 30 s of headroom for
    /// the WS open and setup handshake on the refresh side. Unlike the
    /// previous 60 s provider window, a pre-mint made at the 54-minute
    /// mark routinely survives to the refresh at 55 minutes unless the
    /// user is silent in between. A resolved pre-mint is additionally
    /// checked against its own `expires_at` (see `clientSecretMinRemainingSec`).
    static let preMintStalenessSec: TimeInterval = 90
    /// Minimum time a minted client secret must have left before
    /// `expires_at` for refresh to use it. Covers the WS open; the secret
    /// is only needed to open the connection.
    static let clientSecretMinRemainingSec: TimeInterval = 15
}

/// Running totals of usage observed during a single turn. OpenAI reports
/// usage once per response, in `response.done`. A turn that calls a tool
/// has TWO responses (the tool call, then the spoken reply), each billed
/// separately, so the turn's usage is the sum of the frames.
///
/// An earlier version (written for a provider that streamed usage as
/// per-chunk deltas plus an empty trailing frame) stored the LAST frame's
/// usage and reported 0 tokens on every turn (40+ zero-token events in
/// prod before the fix). Accumulating is correct for both shapes.
struct TurnUsageAccumulator: Sendable, Equatable {
    /// SUM across frames — each frame is a SEPARATE response billed on
    /// its own. A tool-call turn produces TWO such frames (first
    /// response = tool call, second = spoken reply after the tool
    /// result); both must be summed to capture true input cost.
    ///
    /// An earlier version used `max()` which under-reported tool-call
    /// turns by the first response's prompt token count.
    var sumPromptTokens: Int = 0
    /// SUM across frames, same reasoning as `sumPromptTokens`.
    var sumResponseTokens: Int = 0
    /// Per-modality breakdown — both prompt AND response take SUM.
    /// Prompt-side sum matches the reasoning for `sumPromptTokens`
    /// (each frame is a fresh response).
    var sumPromptAudioTokens: Int = 0
    var sumPromptTextTokens: Int = 0
    var sumResponseAudioTokens: Int = 0
    var sumResponseTextTokens: Int = 0
    /// Cached TEXT input tokens (discounted billing). Sum across
    /// responses for the same reason as prompt: each response incurs its
    /// own cache lookup. Forwarded to backend so ops can track cache-hit
    /// ratio as a cost lever.
    var sumCachedContentTokens: Int = 0
    /// Cached AUDIO input tokens. Tracked apart from text because the
    /// two are cached at different rates.
    var sumCachedAudioTokens: Int = 0
    /// True once any non-zero usage frame has been observed. Drives
    /// the finalizeTurn short-circuit path and the nil/populated
    /// distinction that dashboards use to differentiate "this turn's
    /// bill" from "this turn had no usage data at all".
    var hasAnyData: Bool = false

    mutating func accumulate(_ usage: LiveUsageMetadata) {
        sumPromptTokens += usage.promptTokenCount
        sumResponseTokens += usage.responseTokenCount
        if let pAudio = usage.promptAudioTokens {
            sumPromptAudioTokens += pAudio
        }
        if let pText = usage.promptTextTokens {
            sumPromptTextTokens += pText
        }
        if let rAudio = usage.responseAudioTokens {
            sumResponseAudioTokens += rAudio
        }
        if let rText = usage.responseTextTokens {
            sumResponseTextTokens += rText
        }
        if let cached = usage.cachedContentTokenCount {
            sumCachedContentTokens += cached
        }
        if let cachedAudio = usage.cachedAudioTokens {
            sumCachedAudioTokens += cachedAudio
        }
        if usage.promptTokenCount > 0 || usage.responseTokenCount > 0 {
            hasAnyData = true
        }
    }

    mutating func reset() { self = TurnUsageAccumulator() }

    /// Snapshot as a `LiveUsageMetadata` for the reporting code path.
    /// Returns `nil` if no non-zero usage frame was ever observed — the
    /// turn completed with no usage data, which ops classifies as
    /// `usage_metadata_never_arrived`. `totalTokenCount` is derived
    /// (not accumulated) — summing per-frame totalTokenCount
    /// double-counts on tool-call turns.
    func snapshot() -> LiveUsageMetadata? {
        guard hasAnyData else { return nil }
        return LiveUsageMetadata(
            promptTokenCount: sumPromptTokens,
            responseTokenCount: sumResponseTokens,
            totalTokenCount: sumPromptTokens + sumResponseTokens,
            promptAudioTokens: sumPromptAudioTokens > 0 ? sumPromptAudioTokens : nil,
            promptTextTokens: sumPromptTextTokens > 0 ? sumPromptTextTokens : nil,
            responseAudioTokens: sumResponseAudioTokens > 0 ? sumResponseAudioTokens : nil,
            responseTextTokens: sumResponseTextTokens > 0 ? sumResponseTextTokens : nil,
            cachedContentTokenCount: sumCachedContentTokens > 0 ? sumCachedContentTokens : nil,
            cachedAudioTokens: sumCachedAudioTokens > 0 ? sumCachedAudioTokens : nil,
        )
    }
}

/// Per-turn summary forwarded to CookModeViewModel on every `turnComplete`.
/// VM accumulates these into the close-summary `$ai_trace` output_state.
/// Carries the same token counts iOS POSTed to /v1/ai/voice-turn-usage —
/// so the VM's aggregated totals match backend ai_request_log SUMs.
///
/// `promptTokensTotal` / `responseTokensTotal` are the provider's raw
/// `input_tokens` / `output_tokens` (summed across the turn's responses).
/// They can EXCEED `text + audio` if the provider reports tokens it does
/// not attribute to either modality (image tokens, in principle).
/// Dashboards join on totals; cost math uses the breakdown plus any
/// remainder priced at audio rate (backend voice-turn-usage handler).
struct LiveTurnSummary: Sendable, Equatable {
    let turnIndex: Int
    let promptTokensText: Int
    let promptTokensAudio: Int
    let promptTokensTotal: Int
    let responseTokensText: Int
    let responseTokensAudio: Int
    let responseTokensTotal: Int
    /// P2-A (2026-04-23): turn begin anchor captured at the moment
    /// `finalizeTurn` measured its `startedAt`. Consumed by the VM as
    /// the `submittedAt` timestamp for `cook_turn_resolved` telemetry
    /// so the VM doesn't have to reconstruct it via
    /// `endedAt - latencyMs` wall-clock subtraction (NTP drift mid-
    /// session produced occasional negative latencies that polluted
    /// PostHog p95 dashboards).
    let submittedAt: Date
    /// Full turn duration: from turn begin (previous turn's finalize,
    /// or session start for turn 1) to `turnComplete` server frame.
    /// Surfaces as `cook_turn_resolved.latency_total_ms`.
    let latencyMs: Int
    /// Time-to-first-audio: from the server's
    /// `input_audio_buffer.speech_stopped` to the first model audio
    /// chunk. Zero when either anchor was missing for this turn
    /// (tool-call-only turns, or no speech-stopped event). Surfaces as
    /// `cook_turn_resolved.latency_ttfa_ms` and gates ADR 0012's split
    /// validation (amended 2026-04-22 PM): normal-turn p95 < 500 ms,
    /// tool_call-turn p95 < 1500 ms. Dashboard filters zeros so
    /// unmeasurable turns don't skew the p95.
    let latencyTtfaMs: Int
    /// True if the turn invoked any tool call (substitution_check,
    /// start_timer, advance_step, set_step, etc.). VM uses this to tag
    /// `cook_turn_resolved.result_type` = "tool_call" vs "normal"
    /// (ADR 0012 TTFA gate split: tool_call p95 < 1500 ms vs normal
    /// p95 < 500 ms).
    let containedToolCall: Bool
    let endedReason: VoiceTurnUsageRequest.TurnUsage.EndedReason
    let endedAt: Date
}

/// Snapshot of the textual exchange for a single Live turn, fired
/// alongside `LiveTurnSummary` on `turnComplete`. Used by the voice-
/// active Cook Mode UI to render the YOU SAID / STIR transcript card.
///
/// `userText`  — the server-side input transcript(s) for the turn (full
///                utterances, joined with a space). Empty when the server
///                emitted no transcription before the turn finalized (the
///                transcript arrives asynchronously and can lag the
///                response) or transcription is disabled.
/// `modelText` — concatenation of every output transcript delta. Empty
///                for tool-call-only turns where the model produced no
///                spoken response.
///
/// Either field can be empty independently; the consumer decides
/// whether to render with one-sided content. Distinct from
/// `LiveTurnSummary` so token / latency aggregation stays separate
/// from the UI-facing transcript display path.
struct LiveTurnTranscript: Sendable, Equatable {
    let turnIndex: Int
    let userText: String
    let modelText: String
}

@MainActor
// SCA-159 (review of SCA-79 split): stored properties on this class
// declaration are intentionally non-private to permit cross-file
// extension access from RealtimeSessionAudioIO/Transport/StateMachine.swift
// (Swift extensions in separate files cannot reach `private`/`fileprivate`
// declarations on the host type). They are NOT a broadened API surface —
// treat them as `private` to non-extension callers in the Stir module.
// Mutation discipline: every property is mutated only by methods on
// this class or its dedicated extension files. New cross-bucket
// callers should add a `// SCA-159 non-private` marker if they widen
// access further.
final class RealtimeSession: VoiceSessionDriver {

    // MARK: - VoiceSessionDriver conformance

    let pathLabel: VoiceSessionPath = .liveAPI

    var currentState: VoiceSessionState { stateMachine.state }

    /// Latest peak amplitude from either the mic capture or the
    /// playback path, whichever is hotter right now. Half-duplex (the
    /// mic is muted during model speech and vice versa per the state
    /// machine), so `max` cleanly picks the active direction without
    /// branching on state. Returns 0 before `preWarm()` and after
    /// `close()` (audio pipeline gone). UI reads at TimelineView tick
    /// rate and applies its own attack/decay smoothing.
    var currentAudioLevel: Float {
        guard let pipeline = audioPipeline else { return 0 }
        return max(pipeline.currentMicLevel, pipeline.currentOutputLevel)
    }

    /// Backend-minted session id. Set at preWarm success; nil before
    /// preWarm and after close. VM uses this as the PostHog $ai_trace_id
    /// for the close-summary $ai_trace event.
    var voiceSessionID: String? { mintResponse?.sessionID }

    /// Prompt version baked into the mint. Same lifetime as voiceSessionID.
    /// VM reads this to build $ai_input_state on the close-summary trace.
    var voiceSessionPromptVersion: String? { mintResponse?.promptVersion }

    // MARK: - Deps

    let aiDispatch: AIDispatch
    let voiceTurnRepository: VoiceTurnRepository
    let cookingSession: CookingSession
    let now: @Sendable () -> Date
    let stateMachine = VoiceSessionStateMachine()

    // Transport + audio
    var transport: (any LiveTransporting)?  // SCA-159 non-private: refresh swap in StateMachine, open in main file
    var audioPipeline: LiveAudioPipeline?  // SCA-159 non-private: read by AudioIO mic forwarder
    /// P0-D (2026-04-23): observes AVAudioSession interruption /
    /// route-change / media-services-reset events and forwards them to
    /// `handleAudioInterruption(_:)` so we can tear down cleanly on
    /// phone-call / Siri / AirPods-yank / OS-media-graph-reset.
    var audioInterruptionObserver: AudioInterruptionObserver?
    /// P0-F (2026-04-23): observer for `UIApplication.willEnterForegroundNotification`
    /// so we can re-check mic permission. If the user revoked mic access
    /// in Settings while backgrounded, the engine happily returns all-
    /// zero buffers indefinitely — we need to detect + fast-fail.
    var foregroundObserver: NSObjectProtocol?
    /// Monotonic counter bumped every time `startReceiveDispatcher()`
    /// starts a new receive loop. Each dispatcher Task captures its own
    /// generation at spawn. When the dispatcher's for-try-await exits
    /// (via cancellation, transport close, or real error), the catch
    /// block compares its captured generation against the CURRENT value:
    ///   - equal → this is the session's live dispatcher; the error is
    ///             real and should call `handleTransportError`.
    ///   - differs → this dispatcher was torn down by a refreshSession
    ///               swap; its error is noise from an intentional close
    ///               and must NOT advance state to .error.
    /// Replaces the earlier `intentionalTransportSwap` flag, which had a
    /// race window where the flag could be cleared before the stale
    /// dispatcher's error handler ran (review 2026-04-22 Critical #2).
    /// Generation-based suppression is flag-state-independent. ADR 0014.
    var dispatcherGeneration: Int = 0  // SCA-159 non-private: bumped by Transport.startReceiveDispatcher

    /// Wall-clock timestamp of the most recent inbound server audio
    /// chunk. Used by `startMicForwarding` to extend the post-speech playback tail + room-reverb
    /// window. Without this, mic frames resume the moment state
    /// flips `.modelSpeaking → .ready`, which is before the speaker
    /// has finished playing buffered audio and before AEC has fully
    /// adapted — observed 2026-04-22 producing garbage `transcription.user`
    /// frames ("자", "la", "in") that were transcriptions of the model's
    /// own echo.
    var lastInboundAudioAt: Date?

    /// Seconds to continue muting the mic AFTER playback has finished
    /// draining (pendingPlaybackBuffers reaches 0). Now that the
    /// playback-end signal comes from `.dataPlayedBack` completion
    /// callbacks (see LiveAudioPipeline.pendingPlaybackBuffers) we
    /// know precisely when the speaker stopped — the cooldown only
    /// needs to cover AEC adapt time + mild room reverb tail, which
    /// is ~500ms on iPhone. Previously 2.5s because the gate was
    /// keyed off the less-accurate `playerNode.isPlaying` which
    /// flipped late. Tightening to 500ms makes the mic responsive
    /// enough for natural follow-up speech right after the model
    /// stops (observed 2026-04-22: 2.5s felt like a long awkward
    /// pause before the user could barge back in).
    // echoCooldownSec moved to LiveSessionBudget.echoCooldownSec (P2-F).

    // Session state
    var mintResponse: RealtimeSessionResponse?  // SCA-159 non-private: carries setupFrameJSON; never log raw frame
    var turnCount: Int = 0

    // Mic forwarding task — reads mic frames from pipeline and sends
    // to the WebSocket. Started at beginTurn, cancelled at endTurn.
    var micForwardTask: Task<Void, Never>?

    // Receive dispatcher task — reads inbound frames from transport
    // and updates state / plays audio / handles tool calls. Started
    // after preWarm succeeds.
    var receiveDispatcherTask: Task<Void, Never>?

    // Per-turn accumulator. Reset at `flushPendingReport()`. so hands-free
    // turns (which never re-enter beginTurn) get clean slate per turn.
    var currentTurnInlineText: String?
    /// Per-turn accumulator for what the SERVER heard the user say —
    /// the full-utterance input transcript(s) delivered during the turn,
    /// space-joined. They arrive asynchronously and can land after the
    /// turn has finalized, in which case they are attributed to the next
    /// turn. Reset alongside `currentTurnInlineText`. Drained
    /// into the `onTurnTranscriptFinalized` callback when the turn
    /// finalizes; UI uses it to render the YOU SAID side of the
    /// voice-active transcript card.
    var currentTurnUserTranscript: String?
    var turnCompleteContinuation: CheckedContinuation<Void, Error>?  // SCA-159 non-private: nil-clear BEFORE resume — double-resume of CheckedContinuation crashes
    /// Accumulates per-chunk `usageMetadata` deltas across the current
    /// turn. Reset at `flushPendingReport()`. See `TurnUsageAccumulator`
    /// docstring for why usage is summed across a turn's responses.
    var turnUsageAccumulator = TurnUsageAccumulator()
    // `lastUsageMetadata` was replaced by `turnUsageAccumulator` above —
    // the single-value design overwrote real token counts. See the
    // TurnUsageAccumulator docstring and the 2026-04-22 prod regression.
    /// Wall-clock when the CURRENT turn began processing server-side.
    /// Set at beginTurn (first turn) and at each `finalizeTurn()` (next
    /// turn starts implicitly after previous finalizes). Used to stamp
    /// backendLatencyMs in the CookTurnResult — approximate; the
    /// server's speech-start VAD event is not used to anchor turns.
    var turnStartedAt: Date?
    /// Snapshot of the most recently finalized turn. Published by
    /// `finalizeTurn()` so `endTurn()` (when the VM's tap-to-end path
    /// lands after the hands-free auto-loop already resolved the turn)
    /// has something concrete to return. Nil before the first turn
    /// completes.
    var lastTurnResult: CookTurnResult?
    /// Wall-clock of the server's `input_audio_buffer.speech_stopped` for
    /// the CURRENT turn (server VAD detected end-of-utterance). Paired
    /// with `firstModelAudioAt` below to compute per-turn TTFA — time from
    /// "user stopped talking" to "model started responding with audio".
    /// This is the ONLY anchor: the input transcript arrives later and
    /// asynchronously, so anchoring on it would under-report TTFA.
    /// Reset on every `finalizeTurn()`. Nil for turns with no
    /// speech-stopped event (e.g. text-injected turns) — TTFA is zeroed
    /// in that case and the turn shows up on the dashboard as
    /// "unmeasurable" rather than a fake 0 s.
    var userTurnEndAt: Date?
    /// Wall-clock of the first non-empty `audioChunks` arrival within
    /// the current turn. Set once per turn (subsequent chunks don't
    /// overwrite) so TTFA captures the model-first-byte moment, not the
    /// streaming-steady-state arrival. Reset on every `finalizeTurn()`.
    var firstModelAudioAt: Date?
    /// True if the current turn invoked any tool call (substitution_check,
    /// start_timer, advance_step, set_step, etc.). Set in `handleToolCall`,
    /// latched into `PendingTurnReport.containedToolCall` by `finalizeTurn()`
    /// before the per-turn reset. Drives `cook_turn_resolved.result_type`
    /// downstream, which gates ADR 0012's split TTFA thresholds
    /// (normal p95 < 500 ms vs tool_call p95 < 1500 ms).
    var turnContainedToolCall: Bool = false
    /// Name of the most recent tool call in the current turn
    /// ("start_timer", "advance_step", "substitution_check", "set_step",
    /// "restart_timer"). Set by `handleToolCall`; latched into the
    /// stuck-watchdog PostHog payload so ops can correlate incidence
    /// rate with tool-call type. Tool calls are handled one at a time
    /// and Stir's prompt calls one tool per turn, so "most recent" =
    /// "only one this turn" in practice. Reset on every
    /// `finalizeTurn()` + close.
    var lastToolCallName: String?

    /// True when the current `finalizeTurn()` is running as a watchdog
    /// synthetic-turnComplete. Changes the model-turn persist path to
    /// `resultType: .error, errorCode: "turnComplete_timeout"` so the
    /// session history audit trail reflects the stuck recovery per
    /// spec §4.12. Reset at the end of finalizeTurn + close.
    var finalizeWasWatchdogFire: Bool = false

    /// Outcome of a `refreshSession` call. Returned so callers (in
    /// particular `handleTransportError`) can distinguish "refresh
    /// succeeded — session recovered" from "refresh failed before the
    /// swap — old transport still live (but caller may know it's dead)"
    /// from "refresh failed after the swap — state is already `.error`,
    /// old transport has been closed by this call."
    ///
    /// Review finding P0-A (2026-04-23): prior code had `handleTransportError`
    /// unconditionally advance state to `.error` after refresh, which
    /// demoted successfully-recovered sessions into text fallback. A
    /// typed outcome makes the recovery path unambiguous.
    enum RefreshOutcome: Sendable {
        /// Guard at top of refresh short-circuited (already refreshing,
        /// or state was `.closed` / `.error`). Caller got no work done.
        case skipped
        /// Full refresh succeeded: new transport in place, setup-complete
        /// received, mic forwarder swapped through. State machine is
        /// whatever the caller left it; `handleTransportError` decides
        /// whether to settle back to `.ready`.
        case success
        /// Refresh failed BEFORE the transport swap committed. Old
        /// transport is still `self.transport`. In a happy "proactive
        /// refresh" context the caller stays on the old session; in a
        /// `transport_error` context the caller already knows the old
        /// transport is dead and must advance to `.error` itself.
        case preCommitFailure
        /// Refresh failed AFTER the transport swap committed (setup
        /// handshake or later step threw). State has been advanced to
        /// `.error` by this method and the old transport has been
        /// closed (P0-B: prior code leaked it until the server's session cap).
        case postCommitFailure
    }

    /// Watchdog Task that force-advances state when the turn-completing
    /// server event never arrives. Observed 2026-04-23 device test (on
    /// the previous provider): on a multi-pass tool-call turn
    /// (start_timer with post-tool narration) the server finished
    /// speaking but never sent `turnComplete`, pinning the state machine
    /// in `.modelSpeaking` for 35+s until the user manually tapped to
    /// close. Kept on OpenAI because the client still owns every
    /// transition the server is supposed to drive (a failed or dropped
    /// `response.done`, a lost `response.create` after a tool result).
    ///
    /// Contract:
    ///   - Armed on transition INTO `.modelSpeaking` and rearmed on every
    ///     inbound audio chunk (the normal "model is still talking"
    ///     signal). Between-chunk gaps at steady state are ~100ms, so
    ///     `turnStuckWatchdogSec` leaves a wide margin.
    ///   - Cancelled on transition OUT of `.modelSpeaking` (turnComplete
    ///     happy-path, refresh handoff, user interruption, close).
    ///   - On fire: synthesizes turnComplete behavior (advance to
    ///     .ready + finalizeTurn) with a warning log so ops can track
    ///     how often turnComplete goes missing. Uses a dedicated
    ///     `ended_reason: .watchdog` downstream.
    var turnStuckWatchdog: Task<Void, Never>?
    // turnStuckWatchdogSec moved to LiveSessionBudget.turnStuckWatchdogSec (P2-F).
    /// Wall-clock when the CURRENT transport's WebSocket was opened:
    /// set in `preWarm` and again at each successful refresh swap. The
    /// refresh trigger in `finalizeTurn` compares its age against
    /// `LiveSessionBudget.refreshAtSessionAgeSec` /
    /// `preMintAtSessionAgeSec`, because OpenAI caps a session at 60
    /// minutes from connection. Nil before the first open.
    var transportOpenedAt: Date?
    /// True while a refresh is in flight (mint → new WS open → handshake
    /// → swap → old close). Guards re-entry — mid-refresh turn boundaries
    /// shouldn't trigger a second refresh. Cleared in the refresh path's
    /// defer block so a failed refresh doesn't wedge the session.
    var isRefreshing: Bool = false  // SCA-159 non-private: read by AudioIO mic-mute gate, StateMachine refresh trigger, finalizeTurn

    /// Pre-minted refresh token, kicked off at the first turn boundary
    /// past `preMintAtSessionAgeSec`. When refresh triggers at a later
    /// turn boundary, this Task is awaited instead of kicking off a
    /// fresh mint — saving the ~1.5-1.9s mint round-trip on the
    /// handoff's critical path. If the Task has
    /// already completed, `.value` returns instantly. If still running
    /// (rare — user talked fast), we await the same in-flight work we
    /// would have started anyway. If it fails, we fall back to sync
    /// mint. Cleared after consumption or after staleness (see
    /// `pendingPreMintStartedAt`).
    var pendingPreMintTask: Task<RealtimeSessionResponse, Error>?
    /// Wall-clock when `pendingPreMintTask` was kicked off. The client
    /// secret's connect window is 120s from mint, so a pre-minted token
    /// older than `preMintStalenessSec` is discarded in favor of a fresh
    /// sync mint. Typical gap between pre-mint and refresh is one to a
    /// few turns, i.e. well under a minute.
    var pendingPreMintStartedAt: Date?
    // Conversation-history ring buffers REMOVED 2026-04-22 PM.
    // Rationale: Daniel observed the model isn't referencing prior-turn
    // context post-refresh anyway ("conversation is moving forward, not
    // really recalling back things that have been previously said"). The
    // compact recap now carries step position only — the model continues
    // from the current step rather than reconstructing dialogue. ADR 0014
    // amendment. `sanitizeForRecap()` static helper is retained as
    // defense-in-depth in case user text is ever reintroduced to recap.

    /// Snapshot of a turn that's waiting for `usageMetadata` to arrive
    /// before it fires the voice-turn-usage POST + onTurnFinalized
    /// callback. Populated by `finalizeTurn()` on `turnComplete`;
    /// drained by either (a) the next inbound `.usageMetadata` frame
    /// (early-fire path — typical), or (b) `pendingReportTimeoutSec`
    /// timer expiry (defensive fallback — fires with zero tokens,
    /// possibly an empty accumulator).
    ///
    /// Why the delay exists: with OpenAI, usage rides in the same
    /// `response.done` as the turn completion and `parseAll` emits it
    /// first, so the common case flushes immediately in `finalizeTurn`.
    /// The deferred path is the backstop for a usage frame that arrives
    /// after `turnComplete` (the previous provider did this routinely:
    /// 40+ prod events with $ai_input_tokens=0 on 2026-04-22) and for a
    /// response that ends with no usage at all.
    struct PendingTurnReport: Sendable {
        let turnIndex: Int
        let latencyMs: Int
        /// TTFA computed by `finalizeTurn()` at the moment of
        /// turn-complete. Latched here (not read from `lastTurnResult`
        /// at flush time) so subsequent turns can't overwrite the
        /// value we're about to report.
        let latencyTtfaMs: Int
        /// True if this turn invoked any tool call. Latched by
        /// `finalizeTurn()` before the per-turn reset so the VM can
        /// tag `cook_turn_resolved.result_type` = "tool_call" vs
        /// "normal" (ADR 0012 TTFA gate split).
        let containedToolCall: Bool
        /// P2-A (2026-04-23): captured at turn begin so
        /// `cook_turn_resolved.latency_total_ms` in the VM doesn't have
        /// to reconstruct it via `endedAt - latencyMs` wall-clock
        /// subtraction (susceptible to NTP drift mid-session producing
        /// negative latencies that pollute PostHog p95 dashboards).
        let submittedAt: Date
        let endedAt: Date
        let nonce: UUID
        /// Textual exchange for this turn, latched at finalizeTurn
        /// time (pre-reset). nil iff both user and model transcripts
        /// were empty for the turn — consumers (`onTurnTranscriptFinalized`)
        /// don't fire callbacks on empty content. Independent of the
        /// token / latency aggregation contract — text is best-effort
        /// observability, summary numbers gate cap math.
        let transcript: LiveTurnTranscript?
    }
    var pendingReport: PendingTurnReport?


    // Tool-call side-effect callbacks. Set by CookModeViewModel at
    // Cook Mode entry so this actor can route step navigation /
    // start_timer without direct VM coupling. substitution_check is
    // handled internally (dispatches to /v1/ai/substitution).
    var onAdvanceStepRequested: (() -> Void)?
    /// Called when the model invokes `set_step` — lets the user
    /// navigate to any step forward or backward. `step1Indexed` is
    /// 1-indexed (matches the recipe's displayed step numbers).
    var onGoToStepRequested: ((_ step1Indexed: Int) -> Void)?
    /// Fire-and-forget start callback was racy — it kicked off an
    /// async task and returned immediately, so the `get_timer_status`
    /// follow-up query saw the pre-start state (no running timer) and
    /// the tool response told the model "timer didn't start". Making
    /// this async + returning the post-start snapshot means the model
    /// gets the true running state to narrate.
    var onStartTimerRequested: ((_ seconds: Int, _ label: String?) async -> CookModeViewModel.VoiceTimerSnapshot)?

    /// Voice-initiated timer control. Each closure returns a snapshot
    /// of the resulting timer state so the tool handler can include it
    /// in the tool response — the model uses that to speak accurate
    /// state ("timer is paused at 3:12", not a guess).
    var onTimerQueryRequested: (() -> CookModeViewModel.VoiceTimerSnapshot)?
    var onTimerPauseRequested: (() async -> CookModeViewModel.VoiceTimerSnapshot)?
    var onTimerResumeRequested: (() async -> CookModeViewModel.VoiceTimerSnapshot)?
    var onTimerCancelRequested: (() async -> CookModeViewModel.VoiceTimerSnapshot)?

    /// Atomic cancel-then-start callback for the `restart_timer` tool
    /// (added 2026-04-22 PM — prompt v1.6.0). `seconds` is optional; when
    /// nil, the VM reuses the existing timer's total duration. Callback
    /// returns the post-restart snapshot. Returns a `.none`/`.cancelled`
    /// snapshot when there's no timer to restart AND no seconds given —
    /// the tool handler maps that to `ok=false, error=no_existing_timer`.
    var onTimerRestartRequested: ((_ seconds: Int?, _ label: String?) async -> CookModeViewModel.VoiceTimerSnapshot)?

    /// Notifies the VM on every state-machine advance. Critical for
    /// hands-free UX: the driver auto-transitions userSpeaking →
    /// modelSpeaking → ready internally (VAD-driven), and without this
    /// callback the VM's `voiceState` mirror goes stale — mic button
    /// label reads "Listening…" while Stir is actually speaking,
    /// "Thinking…" persists after turn-complete, etc. Set by
    /// CookModeRoot when wiring up the driver; always invoked on
    /// MainActor.
    var onVoiceStateChange: (@MainActor (VoiceSessionState) -> Void)?

    /// Notifies the VM when a voice turn finalizes. Carries the per-turn
    /// summary (tokens + latency + ended_reason) so VM can accumulate
    /// session totals for the close-summary $ai_trace. Fires AFTER the
    /// fire-and-forget POST to /v1/ai/voice-turn-usage — VM's aggregation
    /// and the backend PostHog capture are independent observability
    /// paths. Always invoked on MainActor.
    var onTurnFinalized: (@MainActor (LiveTurnSummary) -> Void)?

    /// Fires alongside `onTurnFinalized` on every `turnComplete`,
    /// carrying the textual exchange so the voice-active Cook Mode UI
    /// can render the YOU SAID / STIR card. Distinct from
    /// `onTurnFinalized` because the transcript display path doesn't
    /// share the token/latency aggregation contract — text is
    /// best-effort observability, summary numbers gate cap math.
    /// Always invoked on MainActor.
    var onTurnTranscriptFinalized: (@MainActor (LiveTurnTranscript) -> Void)?

    /// Fires when `refreshSession()` RESOLVES — success OR failure. Wired
    /// to CookModeViewModel.recordVoiceSessionRefresh which emits the
    /// spec §15 `voice_session_refreshed` PostHog event with a `success:
    /// bool` property so the Voice session health dashboard can compute
    /// refresh success rate = count(success=true) / count(*).
    ///
    /// Payload:
    ///   reason           — what triggered the refresh (see below)
    ///   turnsAtRefresh   — turnCount at the attempt moment
    ///   sessionID        — on success: NEW session id (swap committed).
    ///                      on failure: attributed to the session that
    ///                      OWNED the failure — OLD id for pre-commit
    ///                      failures (mint / WS open threw before the
    ///                      transport swap), NEW id for post-commit
    ///                      failures (swap assigned but handshake threw).
    ///   success          — true if the swap committed; false if any step
    ///                      threw (mint / WS open / setup handshake /
    ///                      post-swap cleanup)
    ///
    /// refreshReason values align with spec §15:
    ///   "minutes"          — transport age crossed `refreshAtSessionAgeSec`
    ///   "transport_error"  — WS transport errored mid-session; refresh as recovery
    /// ("turns", "tokens" and "goaway" are no longer emitted: the
    /// cadence and token triggers were retired by ADR 0038 and OpenAI
    /// has no goAway frame.)
    var onVoiceSessionRefreshResolved:
        (@MainActor (_ reason: String, _ turnsAtRefresh: Int, _ sessionID: String, _ success: Bool) -> Void)?

    /// Fires when the Live session is unrecoverable for this Cook Mode
    /// entry and the caller should pin C.3 (SpeechFallback) for any
    /// subsequent voice driver rebuilds within the same Cook Mode
    /// session. Post-commit refresh failure is the current trigger: the
    /// mint + transport swap succeeded but setup handshake timed out or
    /// returned an unexpected frame — a fresh Live preWarm will likely
    /// hit the same class of failure, so retrying Live ping-pongs the
    /// user through ~2 s of wasted handshake latency per tap before
    /// landing in C.3 anyway.
    ///
    /// VM response: set a "pin fallback" flag that persists until Cook
    /// Mode exit; `CookModeRoot.onRequestNewVoiceSession` reads it and
    /// passes `forceFallback: true` into `buildVoiceDriver`, bypassing
    /// Live preWarm. Review finding P1-K / CA2-H3 (2026-04-23).
    var onVoiceFallbackRequired: (@MainActor (_ reason: String) -> Void)?

    /// Fires when the model invokes `substitution_check` — before the
    /// dispatch fans out to /v1/ai/substitution. VM emits spec §15
    /// `substitution_requested` with `invocation: "realtime_function_call"`
    /// to match the sheet path's `invocation: "sheet"`, so the rescue-
    /// usage dashboard can attribute voice vs manual routes. Payload
    /// carries the generated `subEventID` so the funnel can join the
    /// request to the paired `substitution_accepted` event via
    /// `onSubstitutionResolvedFromVoice`.
    var onSubstitutionRequestedFromVoice: (@MainActor (_ subEventID: String) -> Void)?

    /// Fires after the backend returns a substitution result on the
    /// voice path. VM emits `substitution_accepted` with
    /// `invocation: realtime_function_call` so the funnel has a
    /// symmetric paired event with the sheet path. Voice has no user
    /// confirm step — safe results are auto-applied (accepted=true,
    /// reason=auto_applied), unsafe results are refused by the system
    /// (accepted=false, reason=unsafe_refused). Payload carries
    /// `constraintSafe` + `subEventID` so the accepted event can be
    /// joined back to the requested event.
    var onSubstitutionResolvedFromVoice: (@MainActor (_ constraintSafe: Bool, _ subEventID: String) -> Void)?

    /// Fires after the backend returns a SAFE substitution on the voice
    /// path with the data needed to persist a SubstitutionEvent and
    /// mutate the linked RecipeIngredient. The existing
    /// `onSubstitutionResolvedFromVoice` fires telemetry only; this
    /// callback carries the swap payload.
    ///
    /// Without this, voice substitutions are auto-applied at the model-
    /// narration level ("I'd swap the dried pasta for rice noodles") but
    /// invisible to every downstream consumer — the substitution picker
    /// keeps showing the original ingredient, the next voice turn's
    /// `remainingIngredients` still references the swapped-out
    /// ingredient, and any later grocery export lists the wrong item.
    /// Same root cause + fix as the sheet path's accept handler.
    ///
    /// Payload:
    ///   subEventID         — UUID generated at request time; same id
    ///                        the requested/resolved telemetry events
    ///                        already carry, so the persisted
    ///                        SubstitutionEvent's `id` joins back to
    ///                        the funnel cleanly.
    ///   missingIngredient  — the ingredient name the model identified
    ///                        as missing (free-form string from the
    ///                        tool call, e.g. "dried pasta").
    ///                        Host resolves to a RecipeIngredient by
    ///                        case-insensitive displayName match; falls
    ///                        through to a free-text SubstitutionEvent
    ///                        when no match (e.g. user said
    ///                        "I'm out of cilantro" but cilantro isn't
    ///                        in the recipe).
    ///   substitutionText   — accepted alternative ("rice noodles")
    ///   amountConversion   — optional amount conversion ("8 oz");
    ///                        nil when the model declined a conversion
    ///                        (substitute at the same amount).
    var onSubstitutionAppliedFromVoice: (@MainActor (
        _ subEventID: UUID,
        _ missingIngredient: String,
        _ substitutionText: String,
        _ amountConversion: String?
    ) -> Void)?

    /// Fires when the stuck-modelSpeaking watchdog force-advances after
    /// the turn-completing server event goes missing (observed
    /// 2026-04-23 on multi-pass tool-call turns). VM emits the PostHog
    /// `voice_turn_stuck_watchdog_fired` event so ops can track the
    /// incidence rate of the underlying protocol problem.
    ///
    /// Payload:
    ///   sessionID          — voice session id (current mint). In
    ///                        practice always a real session id — watchdog
    ///                        only arms on `.modelSpeaking` which implies
    ///                        setup completed and `mintResponse` is populated.
    ///                        Typed `String` (not `String?`) to match
    ///                        `onVoiceSessionRefreshResolved`'s shape; call
    ///                        site falls back to `"unknown"` if the invariant
    ///                        ever breaks.
    ///   turnIndex          — `turnCount + 1` (the turn we're synthesizing
    ///                        turnComplete for; will be incremented inside
    ///                        the finalizeTurn that follows)
    ///   toolCallType       — name of the most recent tool call in this
    ///                        turn ("start_timer" / "advance_step" /
    ///                        "substitution_check" / etc.), nil if the
    ///                        watchdog fired on a non-tool-call turn
    ///   elapsedStuckMs     — ms since last inbound audio chunk; the
    ///                        "dead air" window that triggered the watchdog
    ///   turnLengthAtStuck  — ms since this turn began (turnStartedAt),
    ///                        useful for distinguishing "stuck halfway"
    ///                        vs "stuck after a long response"
    var onVoiceTurnStuckWatchdogFired:
        (@MainActor (_ sessionID: String, _ turnIndex: Int, _ toolCallType: String?, _ elapsedStuckMs: Int, _ turnLengthAtStuck: Int) -> Void)?

    // MARK: - Init

    init(
        aiDispatch: AIDispatch,
        voiceTurnRepository: VoiceTurnRepository,
        cookingSession: CookingSession,
        now: @escaping @Sendable () -> Date = Date.init,
    ) {
        self.aiDispatch = aiDispatch
        self.voiceTurnRepository = voiceTurnRepository
        self.cookingSession = cookingSession
        self.now = now
    }

    #if DEBUG
    /// Test-only init that pre-populates `mintResponse` so tests can
    /// verify the `voiceSessionID` / `voiceSessionPromptVersion` computed
    /// properties without running a real WebSocket mint. Guards against
    /// a regression where the property overrides are removed and the
    /// protocol default impls silently nil the close-summary trace.
    init(
        testingOnlyMintResponse: RealtimeSessionResponse,
        aiDispatch: AIDispatch,
        voiceTurnRepository: VoiceTurnRepository,
        cookingSession: CookingSession,
        now: @escaping @Sendable () -> Date = Date.init,
    ) {
        self.aiDispatch = aiDispatch
        self.voiceTurnRepository = voiceTurnRepository
        self.cookingSession = cookingSession
        self.now = now
        self.mintResponse = testingOnlyMintResponse
    }
    #endif

    // MARK: - Errors

    enum RealtimeSessionError: Error, Equatable, Sendable {
        /// Mint failed (backend 5xx or network error). VM → fall back to C.3.
        case mintFailed(message: String)
        /// WebSocket open failed (DNS, TLS, token rejected). VM → fall back.
        case openFailed(message: String)
        /// Didn't receive setupComplete within the handshake budget.
        case setupTimeout
        /// A turn ended without a turnComplete signal and without a
        /// connection drop — indicates a protocol bug. VM → fall back.
        case turnDrained
        /// User tapped mic while already in a conflicting state. Mirrors
        /// SpeechFallbackError.busy — VM branches on the typed error.
        case busy(state: VoiceSessionState)
        /// Caller invoked a method that requires an open session.
        case notOpen
    }

    // MARK: - preWarm

    /// Mint + open + handshake. Three network operations in sequence;
    /// any failure throws and the VM downgrades to C.3.
    ///
    /// Caller must have already activated AVAudioSession for Cook Mode
    /// (same precondition as SpeechFallbackService.preWarm).
    func preWarm() async throws {
        guard stateMachine.state == .idle else {
            throw RealtimeSessionError.busy(state: stateMachine.state)
        }
        #if DEBUG
        VoiceSessionLog.sessionStart()
        #endif
        // Wire the state machine's transition hook to drive BOTH the
        // DEBUG console log (so D.1 has the unified timeline) AND the
        // VM's `onVoiceStateChange` subscription (so the mic button
        // label reflects reality during hands-free auto-advances —
        // userSpeaking → modelSpeaking → ready cycles without any
        // VM method call). `[weak self]` because the state machine
        // holds the closure and would otherwise retain the session
        // past its natural lifetime.
        //
        // SCA-168 S12 (CA2): `rearmTurnStuckWatchdog` /
        // `cancelTurnStuckWatchdog` referenced inside the closure live
        // on the StateMachine extension (RealtimeSessionStateMachine.swift) —
        // they are NOT in this file even though the call site is. Same
        // pattern as `onVoiceStateChange?(to)` (a callback declared on
        // this class but typically wired from the VM in CookModeRoot).
        stateMachine.onTransition = { [weak self] from, to in
            #if DEBUG
            VoiceSessionLog.log("state.advance", [
                "from": from.rawValue,
                "to": to.rawValue,
            ])
            #endif
            // Watchdog lifecycle: arm on entry to .modelSpeaking, cancel
            // on exit. Transitions WITHIN .modelSpeaking can't happen
            // (state machine treats same-state as idempotent no-op), so
            // this correctly tracks "model is currently speaking" windows.
            if to == .modelSpeaking, from != .modelSpeaking {
                self?.rearmTurnStuckWatchdog()
            } else if from == .modelSpeaking, to != .modelSpeaking {
                self?.cancelTurnStuckWatchdog()
            }
            self?.onVoiceStateChange?(to)
        }
        stateMachine.advance(to: .connecting)

        do {
            // 1. Mint
            #if DEBUG
            VoiceSessionLog.log("mint.start")
            #endif
            let mintRequest = try buildMintRequest()
            let response = try await aiDispatch.realtimeSession(request: mintRequest)
            self.mintResponse = response
            #if DEBUG
            VoiceSessionLog.log("mint.complete", [
                "session_id": response.sessionID,
                "prompt_version": response.promptVersion,
            ])
            #endif

            // 2. Open WebSocket. The client secret authenticates it as a
            //    bearer header; the transport pins scheme + host.
            guard let wsURL = URL(string: response.wsURL) else {
                #if DEBUG
                VoiceSessionLog.log("mint.invalid_ws_url")
                #endif
                throw RealtimeSessionError.openFailed(message: "invalid ws_url")
            }
            let transport = LiveWebSocketTransport()
            self.transport = transport
            try transport.open(url: wsURL, authToken: response.authToken)
            // OpenAI's 60-minute session cap runs from connection, so
            // this is the clock the refresh trigger measures against.
            transportOpenedAt = now()
            #if DEBUG
            VoiceSessionLog.log("ws.open")
            #endif

            // 3. Prepare audio pipeline (mic converter + playback node)
            let pipeline = LiveAudioPipeline()
            try pipeline.prepare()
            self.audioPipeline = pipeline
            #if DEBUG
            VoiceSessionLog.log("audio.prepared")
            #endif

            // 4. Start inbound receive dispatcher
            startReceiveDispatcher()

            // 5. Send the `session.update` frame that configures the
            //    session. The server first sends `session.created`
            //    (ignored by the parser) and emits `session.updated`
            //    — our `.setupComplete` — only after it receives this.
            //    Without this send, `awaitSetupComplete` times out at 5s
            //    and preWarm falls through to C.3.
            //
            //    Backend pre-serializes the payload so iOS forwards a
            //    single JSON blob — no shape drift possible between
            //    what the client secret was minted for and what the
            //    client sends. Sent via `setupRawJSON` so the transport
            //    skips the JSONSerialization round-trip.
            try await transport.send(.setupRawJSON(response.setupFrameJSON))
            #if DEBUG
            VoiceSessionLog.log("ws.setup_sent")
            #endif

            // 6. Wait for setupComplete (budget named in
            //    LiveSessionBudget — server normally emits this within
            //    200-400 ms after receiving our setup frame).
            try await awaitSetupComplete(timeoutSec: LiveSessionBudget.setupHandshakeSec)
            #if DEBUG
            VoiceSessionLog.log("ws.setup_complete")
            #endif

            stateMachine.advance(to: .ready)
            // P0-D (2026-04-23): observe AVAudioSession interruptions +
            // route changes + media-services-reset so phone-call / Siri /
            // AirPods-yank / OS-audio-graph-teardown recovers cleanly
            // instead of silently wedging the session.
            startAudioInterruptionObserver()
            Logger.voice.info("live_session_ready session_id=\(response.sessionID, privacy: .public)")
            #if DEBUG
            VoiceSessionLog.log("session.ready")
            #endif
        } catch {
            // Any preWarm failure tears down what we started and
            // surfaces the typed error. State machine moves to error.
            #if DEBUG
            VoiceSessionLog.logError("prewarm.failed", error: error)
            #endif
            stateMachine.advance(to: .error)
            close()
            throw error
        }
    }

    // MARK: - beginTurn

    func beginTurn() async throws {
        guard stateMachine.state == .ready else {
            #if DEBUG
            VoiceSessionLog.log("begin_turn.busy", ["state": stateMachine.state.rawValue])
            #endif
            throw RealtimeSessionError.busy(state: stateMachine.state)
        }
        guard let pipeline = audioPipeline else {
            throw RealtimeSessionError.notOpen
        }

        // Reset per-turn accumulators for the first turn; subsequent
        // hands-free turns get the same reset via `flushPendingReport()`.
        currentTurnInlineText = nil
        currentTurnUserTranscript = nil
        turnUsageAccumulator.reset()
        turnStartedAt = now()

        stateMachine.advance(to: .userSpeaking)
        try pipeline.startCapture()
        startMicForwarding()
        #if DEBUG
        // `turn = turnCount + 1`: the turn about to run. Matches the
        // value `turn.end_submitted` emits for the same turn, so a
        // grep for `turn=5` finds every event in turn 5.
        VoiceSessionLog.log("turn.begin", ["turn": turnCount + 1])
        #endif
    }

    // MARK: - endTurn

    func endTurn(
        recipeContext: RealtimeRecipeContext,
        householdContext: RealtimeHouseholdContext,
        currentStepNumber: Int,
        recipePlanId: UUID,
    ) async throws -> CookTurnResult {
        // Re-entry guard. Repeat taps (user impatient, tapping the
        // "end" button several times) used to create a new
        // `turnCompleteContinuation` per call, overwriting the prior
        // one without resuming — tripping Swift's "continuation
        // leaked" runtime warning AND leaving previous awaiters
        // suspended forever. Observed 2026-04-22: 8 rapid taps in
        // `.thinking` produced 8 leak warnings in 15 s. If a turn is
        // already in flight, return the running snapshot without
        // spinning up a second wait.
        if turnCompleteContinuation != nil {
            #if DEBUG
            VoiceSessionLog.log("end_turn.reentry_ignored", [
                "state": stateMachine.state.rawValue,
            ])
            #endif
            return lastTurnResult ?? makeEmptyTurnResult()
        }
        // Hands-free tolerance: VAD may have auto-advanced us past
        // .userSpeaking before the VM's endTurn landed. Accept any
        // live turn state — handleServerContent and the turnComplete
        // path already drive state correctly, endTurn just awaits
        // the completion signal.
        switch stateMachine.state {
        case .userSpeaking, .thinking, .modelSpeaking:
            break
        case .ready:
            // turnComplete already arrived before endTurn was called
            // (common when VAD is fast and the VM's tap-end is slow).
            // Return the most recently finalized turn snapshot, or an
            // empty result if somehow no turn ever completed. VM's
            // post-processing is a no-op in Live mode anyway
            // (response already played during the turn).
            return lastTurnResult ?? makeEmptyTurnResult()
        default:
            throw RealtimeSessionError.busy(state: stateMachine.state)
        }
        // Hands-free model: mic stays hot continuously across the
        // session. VAD (server-side, configured in the setup frame)
        // drives turn boundaries — iOS never stops the mic mid-session
        // and never commits the input buffer itself.
        //
        // Lessons from the earlier attempts (on the previous provider,
        // but the reasoning carries):
        //   1. Abruptly stopping the mic on tap-to-end leaves VAD with no
        //      trailing silence — it sits waiting for more audio and the
        //      turn never completes (30s `turnDrained` observed
        //      2026-04-20).
        //   2. Signalling "audio stream done" to the server is a
        //      session-terminal signal there, not a turn-end signal —
        //      not usable for a multi-turn cook session.
        //
        // So: endTurn's job is just UI/state coordination. Advance
        // state to `.thinking` ONLY if we're still in .userSpeaking —
        // VAD may already have auto-advanced us through
        // .modelSpeaking (via handleServerContent). Mic stays hot
        // either way. Then await the server-driven turn completion.
        // If the user is still talking past the tap, VAD processes
        // their audio normally and closes the turn on natural silence.
        // If the user stopped before tapping, VAD already saw the
        // silence and the turn may complete near-instantly.
        if stateMachine.state == .userSpeaking {
            stateMachine.advance(to: .thinking)
        }
        #if DEBUG
        VoiceSessionLog.log("turn.end_submitted", ["turn": turnCount + 1])
        #endif

        // Wait for the turn-completing response.done — handleServerContent
        // advances state AND calls `finalizeTurn()` before resuming
        // the continuation, so when we wake up the snapshot is ready.
        do {
            try await awaitTurnComplete()
        } catch {
            #if DEBUG
            VoiceSessionLog.logError("turn.timeout_or_error", error: error)
            #endif
            throw error
        }

        // handleServerContent's turnComplete handler already advances
        // to .ready in the hands-free auto-loop path. Defensive
        // catch-up if we're still at .modelSpeaking (extreme race
        // where continuation fired before the advance sequence, which
        // shouldn't happen on the MainActor but costs nothing to
        // guard).
        if stateMachine.state == .modelSpeaking {
            stateMachine.advance(to: .ready)
        }
        return lastTurnResult ?? makeEmptyTurnResult()
    }

    /// Zero-valued CookTurnResult used when endTurn is called before
    /// any turn has finalized (edge case) OR when the hands-free loop
    /// processed the turn without populating a snapshot (also shouldn't
    /// happen — finalizeTurn always sets lastTurnResult).
    private func makeEmptyTurnResult() -> CookTurnResult {
        CookTurnResult(
            transcript: "",
            response: CookTurnResponse(
                spokenResponse: "",
                suggestedAction: .none,
                actionParams: nil,
                promptVersion: mintResponse?.promptVersion ?? "",
                latencyMS: 0,
                retryCount: 0,
            ),
            sttLatencyMs: 0,
            backendLatencyMs: 0,
        )
    }

    // MARK: - speak (no-op on Live)

    /// No-op on the Live path: the model's audio was already streamed
    /// out during endTurn and played through AVAudioPlayerNode. Present
    /// only to satisfy VoiceSessionDriver — C.3 needs it because the
    /// fallback dispatches text then synthesizes after.
    func speak(_ text: String) async {
        // Intentionally empty. `text` is logged at debug so Sentry
        // triage can confirm VM called through, but nothing plays.
        Logger.voice.debug("live_speak_noop text_len=\(text.count, privacy: .public)")
    }

    // MARK: - cancelSpeaking

    func cancelSpeaking() async {
        #if DEBUG
        // Distinguish user-barge-in (this path) from natural
        // end-of-turn (.modelSpeaking → .ready via turnComplete).
        // Both produce the same state transition in the transcript,
        // but only the former carries this tag.
        VoiceSessionLog.log("user.interrupted", ["state": stateMachine.state.rawValue])
        #endif
        audioPipeline?.cancelPlayback()
        // If we were mid-modelSpeaking, snap back to ready so the next
        // beginTurn doesn't hit the state guard. Legal transition per
        // VoiceSessionStateMachine (.modelSpeaking → .ready).
        if stateMachine.state == .modelSpeaking {
            stateMachine.advance(to: .ready)
        }
    }

    // MARK: - close

    /// SCA-76: invariant pinned at the protocol level — `CookModeRoot`
    /// invokes the close path TWICE on the leftovers handoff (once via
    /// `closeVoiceSessionFromHost()` per SCA-57, once via
    /// `driverTeardown?()` on `.onDisappear`). This implementation must
    /// not throw, must not double-emit `voice_session_closed_*` /
    /// `$ai_trace` close-summary, and must not double-release audio
    /// resources. Re-entry is gated below by checking individual
    /// resource state (e.g. `pendingReport != nil`,
    /// `audioEngine.isRunning`) — each guard is the per-resource
    /// idempotency point. If you refactor any of those guards out,
    /// add an explicit `if isClosed { return }` flag instead so the
    /// SCA-76 contract holds at the entry boundary.
    func close() {
        #if DEBUG
        VoiceSessionLog.log("close.begin", ["turn_count": turnCount])
        #endif
        // Drain any pending turn-usage report so a mid-turn close doesn't
        // lose the last turn's observability. Uses whatever `turnUsageAccumulator`
        // holds at this moment; if the turn finished cleanly but usage
        // never arrived before close, the report fires with zeros +
        // `usage_metadata_never_arrived` warning.
        if pendingReport != nil {
            flushPendingReport(dueTo: .sessionClosed)
        }
        // Cancel any in-flight pre-mint Task. Its result would be a
        // minted ephemeral token we're never going to use now that the
        // session is closing — leaving it running wastes backend work
        // and (harmlessly) leaves a client secret unused until it
        // expires. Extracted to `cancelAndClearPreMintSlot()` so
        // the P1-P `_testTearDownPreMintSlot` hook exercises the same
        // production symbol, not a test-only copy.
        cancelAndClearPreMintSlot()
        // Cancel the stuck-modelSpeaking watchdog. If the session is
        // closing, we don't want a late fire to synthesize turnComplete
        // on a dead session (would no-op due to the state guard inside
        // `turnStuckWatchdogFired`, but cancelling is cleaner).
        cancelTurnStuckWatchdog()
        // Drain pending continuations BEFORE cancelling tasks — if we
        // cancel `receiveDispatcherTask` first, its `handleTransportError`
        // path (the normal drain site) never fires, and any caller
        // suspended on `awaitSetupComplete` / `awaitTurnComplete` is
        // stranded. On dealloc that becomes a "continuation was not
        // resumed" concurrency runtime crash. Nil-clear before resume so
        // a racing happy-path resolve can't double-resume.
        if let cont = setupCompleteContinuation {
            setupCompleteContinuation = nil
            cont.resume(throwing: RealtimeSessionError.notOpen)
        }
        if let cont = turnCompleteContinuation {
            turnCompleteContinuation = nil
            cont.resume(throwing: RealtimeSessionError.notOpen)
        }
        receiveDispatcherTask?.cancel()
        receiveDispatcherTask = nil
        micForwardTask?.cancel()
        micForwardTask = nil
        transport?.close()
        transport = nil
        audioPipeline?.tearDown()
        audioPipeline = nil
        // P0-D (2026-04-23): stop observing system audio events. Safe to
        // call even if start was never invoked (idempotent).
        audioInterruptionObserver?.stop()
        audioInterruptionObserver = nil
        // P0-F (2026-04-23): remove foreground observer.
        if let obs = foregroundObserver {
            NotificationCenter.default.removeObserver(obs)
            foregroundObserver = nil
        }
        // AVAudioSession deactivation is the VM's responsibility (see
        // CookModeViewModel.exit). Removed from close() to keep the
        // audio-session lifecycle owned in one place — parity with
        // SpeechFallbackService.close().
        if stateMachine.state != .closed {
            stateMachine.forceClose()
        }
        // Reset per-session accumulators that would otherwise leak
        // into a hypothetical future reuse (not done today; VM rebuilds
        // instead, but keeping close() hygienic keeps future refactors
        // safe).
        lastInboundAudioAt = nil
        turnStartedAt = nil
        userTurnEndAt = nil
        firstModelAudioAt = nil
        turnContainedToolCall = false
        lastToolCallName = nil
        finalizeWasWatchdogFire = false
        clearHouseholdContextCache()  // P3-H
        currentTurnInlineText = nil
        currentTurnUserTranscript = nil
        turnUsageAccumulator.reset()
        #if DEBUG
        VoiceSessionLog.sessionEnd()
        #endif
    }

    // MARK: - Cross-extension stored state
    //
    // SCA-79 / SCA-164: these properties live on the main class declaration
    // because Swift extensions cannot host stored instance properties. They
    // are read/written across the four extension files (AudioIO, Transport,
    // StateMachine, plus this main file). Lifecycle ownership:
    //
    //   cachedHouseholdContext / ...At — Transport (buildHouseholdContext
    //                                    populates; close → clearHouseholdContextCache clears)
    //   setupCompleteContinuation       — Transport (awaitSetupComplete sets;
    //                                    StateMachine.handleInboundFrame.setupComplete
    //                                    + main close drain)
    //   turnCompleteGeneration          — StateMachine (awaitTurnComplete bumps)
    //   setupCompleteGeneration         — Transport (awaitSetupComplete bumps)

    /// P3-H (2026-04-23): TTL-cached household snapshot. Invalidated
    /// naturally after 60 s; preWarm + close both clear it via
    /// `clearHouseholdContextCache()` as a belt-and-suspenders reset.
    var cachedHouseholdContext: RealtimeHouseholdContext?  // SCA-159 non-private: written by Transport.buildHouseholdContext, cleared from main close()
    var cachedHouseholdContextAt: Date?  // SCA-159 non-private: paired with cachedHouseholdContext

    var setupCompleteContinuation: CheckedContinuation<Void, Error>?  // SCA-159 non-private: nil-clear BEFORE resume — double-resume of CheckedContinuation crashes

    /// Monotonic counter bumped every time a new `turnComplete` /
    /// `setupComplete` await begins. Each timeout task captures the
    /// generation value observed at spawn; when it wakes up 30 s later,
    /// it compares against the CURRENT generation before firing. If the
    /// original continuation already resolved naturally and a new one
    /// has since started, the generations differ and the stale timeout
    /// no-ops instead of poisoning a live continuation.
    ///
    /// Without this, a turn-N timeout spawned at T could wake up at
    /// T+30s, see a non-nil `turnCompleteContinuation` (turn-N+1's),
    /// and resume-throw `.turnDrained` on it — surfacing as a spurious
    /// "voice turn failed" in the middle of an otherwise-working
    /// session (review 2026-04-22 §Critical #3).
    var turnCompleteGeneration: Int = 0  // SCA-159 non-private: bumped by StateMachine.awaitTurnComplete
    var setupCompleteGeneration: Int = 0  // SCA-159 non-private: bumped by Transport.awaitSetupComplete
}
