// RealtimeSession
//
// Gemini Live (3.1 Flash Live Preview) driver. Conforms to
// VoiceSessionDriver so CookModeViewModel can hold `any VoiceSessionDriver`
// without branching on path type — telemetry keys off `pathLabel`.
//
// Lifecycle mirrors SpeechFallbackService:
//   preWarm  → mint token (via /v1/ai/realtime-session) + open WS +
//              wait for setupComplete + prepare AudioPipeline.
//              Throws on mint failure or setup timeout — VM downgrades
//              to C.3 on any preWarm error.
//   beginTurn → start mic capture, frames stream to WS as realtimeInput.
//   endTurn   → flush mic, wait for serverContent turnComplete + any
//               toolCall round-trip, persist VoiceTurn, return result.
//   speak     → no-op on Live (audio already streamed during endTurn).
//   cancelSpeaking → stop audio player; user is about to begin a new turn.
//   close     → tear down WS + audio + audio session. Idempotent.
//
// Session refresh (ADR 0014): triggered on `turnCount - lastRefreshedAtTurn
// >= 4` OR `sumPromptTokens > 10_000`. Silent swap via `refreshSession()`
// with pre-mint one turn earlier on the cadence path. The older drafts
// documented "pruning via sessionUpdate" and a "FillerClipPlayer"; both
// were superseded — pruning is the session-refresh swap itself
// (Gemini Live's protocol has no mid-session truncation frame), and the
// filler-clip design was never wired (we rely on model-emitted preambles
// + the natural ~1 s tool-dispatch latency for UX cover).

import AVFoundation
import Foundation
import OSLog
import UIKit

/// Numeric budgets for the Live driver. Mirrored from CLAUDE.md's
/// `LiveSessionLimits` spec. Keeping them here (scoped to the Live
/// path) rather than in a global struct because every value is
/// Live-specific. Values tuned from device measurements + the
/// ADR 0010 / 0012 / 0014 / 0015 trigger re-checks documented inline.
///
/// P2-G (2026-04-23): `@MainActor` annotation dropped — the enum holds
/// only `Sendable` primitive `static let` values and needs no isolation.
/// The prior annotation forced every reader (including nonisolated
/// tests and the backend-shared constants file) to hop the MainActor
/// to read a pure constant, which is a footgun for future
/// Swift 6 strict-concurrency cleanups.
enum LiveSessionBudget {
    /// Seconds to wait for the server's `setupComplete` handshake
    /// before failing `preWarm()`. Observed p95 is ~300 ms; 5 s is a
    /// generous upper bound.
    static let setupHandshakeSec: Double = 5
    /// Seconds to wait for the server's `turnComplete` frame after
    /// user audio closes. 2× Gemini's observed ~15 s p95 for a long
    /// multi-sentence response.
    static let turnCompleteSec: Double = 30
    /// Turn count at which we trigger a session refresh (CLAUDE.md
    /// §Gemini Live constants `refreshAtTurnCount`). Trajectory:
    /// 15 → 10 AM (ADR 0014), 10 → 7 PM, 7 → 2 PM (second pass), and
    /// finally 2 → 4 PM (third pass, after device test showed 2-turn
    /// cadence was too handoff-heavy — user perceived the 3s refresh
    /// as "too much latency"). Analysis: cost-per-turn is LINEAR in N
    /// (each extra turn in the window adds ~$0.0014 to average), but
    /// refresh-count-per-session is HYPERBOLIC (30/N). The knee in
    /// savings-per-added-refresh sits at N=3-5; below that, each
    /// additional refresh saves very little cost for a guaranteed 3s
    /// handoff. N=4 pins worst-case per-turn prompt tokens at ~4,300
    /// (fast perceived latency, every turn feels ~similar), cuts
    /// N=7's per-turn cost by ~35%, and keeps refreshes to ~7 per
    /// 30-turn session (one every ~20s of actual conversation).
    /// ADR 0014 third-pass PM amendment.
    static let refreshAtTurnCount: Int = 4
    /// Hard cap on per-turn prompt tokens. Any turn that exceeds this
    /// triggers an immediate refresh at turn completion — guards against
    /// a long single turn (long user utterance + long model reply +
    /// tool-call round-trip) pushing us past the soft cap before turn
    /// count naturally rolls. Lowered 15k → 10k on 2026-04-22 PM in
    /// lockstep with the turn-count drop; same "latency over prior
    /// context" tradeoff.
    static let refreshAtPromptTokenCount: Int = 10_000
    /// Upper bound on how long we wait for `usageMetadata` to arrive
    /// after `turnComplete` before firing the voice-turn-usage POST
    /// with whatever tokens we have (zero if nothing arrived). Tuned
    /// conservatively: Gemini's trailing-usage frames land within
    /// ~200 ms in practice; 2 s gives slow cellular plenty of headroom
    /// without delaying dashboards long enough to confuse ops.
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
    /// fired on legitimate multi-pass tool-call gaps (Gemini
    /// preparing the next audio pass after a tool response —
    /// measured ~11 s worst case).
    static let turnStuckWatchdogSec: TimeInterval = 15
    /// AEC + room-reverb cooldown after playback ends, before we
    /// re-open the mic. Tuned from a 2026-04-22 observation that
    /// server-side VAD fired on a -30 dB residual inside the
    /// cooldown window.
    static let echoCooldownSec: TimeInterval = 0.5
    /// Pre-mint Task staleness window. Backend's
    /// `new_session_expire_time` is 60 s from mint; we discard
    /// pre-mints older than this to leave headroom for WS open +
    /// setup handshake on the refresh side. Typical pre-mint →
    /// refresh gap is 8-20 s, so 45 s virtually never triggers in
    /// practice but is the backstop against a deferred refresh
    /// consuming a dead token.
    static let preMintStalenessSec: TimeInterval = 45
}

/// Running totals of `usageMetadata` observed during a single turn.
/// Gemini Live streams usage as per-chunk deltas — empirically
/// observed 2026-04-22:
///   - first frame of a turn: `promptTokenCount=N` (real input count,
///     e.g. 3482), `responseTokenCount=0`
///   - every subsequent audio chunk: `promptTokenCount=0`,
///     `responseTokenCount=K` (per-chunk delta, typically 1–10)
///   - turnComplete envelope: `usageMetadata: {}` (all zeros)
///
/// An earlier version stored the LAST frame's usage, which meant the
/// empty turnComplete envelope wiped out every per-chunk delta, so
/// every voice-turn-usage POST reported 0 tokens (40+ zero-token
/// events in prod before the fix). Accumulating preserves the real
/// totals across the turn.
struct TurnUsageAccumulator: Sendable, Equatable {
    /// SUM across frames — each non-zero `promptTokenCount` frame
    /// represents a SEPARATE generation pass billed by Gemini. A
    /// tool-call turn produces TWO such frames (first pass = tool
    /// call, second pass = spoken reply after tool return); both
    /// must be summed to capture true input cost. Per-chunk deltas
    /// have `promptTokenCount=0`, so summing them is a no-op.
    ///
    /// An earlier version used `max()` which under-reported tool-call
    /// turns by the first-pass prompt token count (~3640 tokens per
    /// tool-call turn, ~$0.011 at audio-in pricing).
    var sumPromptTokens: Int = 0
    /// SUM across frames — response count arrives as per-chunk deltas.
    var sumResponseTokens: Int = 0
    /// Per-modality breakdown — both prompt AND response take SUM.
    /// Prompt-side sum matches the reasoning for `sumPromptTokens`
    /// (each non-zero frame is a fresh generation pass).
    var sumPromptAudioTokens: Int = 0
    var sumPromptTextTokens: Int = 0
    var sumResponseAudioTokens: Int = 0
    var sumResponseTextTokens: Int = 0
    /// Tokens served from Gemini's content cache (discounted billing).
    /// Sum across generation passes for the same reason as prompt:
    /// each pass incurs its own cache lookup. Forwarded to backend so
    /// ops can track cache-hit ratio as a cost lever.
    var sumCachedContentTokens: Int = 0
    /// True once any non-zero usage frame has been observed. Drives
    /// the finalizeTurn short-circuit path and the nil/populated
    /// distinction that dashboards use to differentiate "this turn's
    /// Gemini bill" from "this turn had no usage data at all".
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
        )
    }
}

/// Per-turn summary forwarded to CookModeViewModel on every `turnComplete`.
/// VM accumulates these into the close-summary `$ai_trace` output_state.
/// Carries the same token counts iOS POSTed to /v1/ai/voice-turn-usage —
/// so the VM's aggregated totals match backend ai_request_log SUMs.
///
/// `promptTokensTotal` / `responseTokensTotal` are Gemini's raw
/// `promptTokenCount` / `responseTokenCount` (summed across generation
/// passes). They may EXCEED `text + audio` by the AUDIO-mode per-pass
/// overhead (~200 tokens/pass, CLAUDE.md sharp-edge #15) which Gemini
/// does not attribute to either modality in `promptTokensDetails`.
/// Dashboards join on totals; cost math uses the breakdown plus the
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
    /// Time-to-first-audio: from server's `inputTranscription.finished`
    /// to the first model audio chunk. Zero when either anchor was
    /// missing for this turn (tool-call-only turns, or server races
    /// audio ahead of transcription-finished). Surfaces as
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

@MainActor
final class RealtimeSession: VoiceSessionDriver {

    // MARK: - VoiceSessionDriver conformance

    let pathLabel: VoiceSessionPath = .liveAPI

    var currentState: VoiceSessionState { stateMachine.state }

    /// Backend-minted session id. Set at preWarm success; nil before
    /// preWarm and after close. VM uses this as the PostHog $ai_trace_id
    /// for the close-summary $ai_trace event.
    var voiceSessionID: String? { mintResponse?.sessionID }

    /// Prompt version baked into the mint. Same lifetime as voiceSessionID.
    /// VM reads this to build $ai_input_state on the close-summary trace.
    var voiceSessionPromptVersion: String? { mintResponse?.promptVersion }

    // MARK: - Deps

    private let aiDispatch: AIDispatch
    private let voiceTurnRepository: VoiceTurnRepository
    private let cookingSession: CookingSession
    private let stateMachine = VoiceSessionStateMachine()

    // Transport + audio
    private var transport: LiveWebSocketTransport?
    private var audioPipeline: LiveAudioPipeline?
    /// P0-D (2026-04-23): observes AVAudioSession interruption /
    /// route-change / media-services-reset events and forwards them to
    /// `handleAudioInterruption(_:)` so we can tear down cleanly on
    /// phone-call / Siri / AirPods-yank / OS-media-graph-reset.
    private var audioInterruptionObserver: AudioInterruptionObserver?
    /// P0-F (2026-04-23): observer for `UIApplication.willEnterForegroundNotification`
    /// so we can re-check mic permission. If the user revoked mic access
    /// in Settings while backgrounded, the engine happily returns all-
    /// zero buffers indefinitely — we need to detect + fast-fail.
    private var foregroundObserver: NSObjectProtocol?
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
    private var dispatcherGeneration: Int = 0

    /// Wall-clock timestamp of the most recent inbound server audio
    /// chunk. Used by `startMicForwarding` to extend the post-speech playback tail + room-reverb
    /// window. Without this, mic frames resume the moment state
    /// flips `.modelSpeaking → .ready`, which is before the speaker
    /// has finished playing buffered audio and before AEC has fully
    /// adapted — observed 2026-04-22 producing garbage `transcription.user`
    /// frames ("자", "la", "in") that were transcriptions of the model's
    /// own echo.
    private var lastInboundAudioAt: Date?

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
    private var mintResponse: RealtimeSessionResponse?
    private var turnCount: Int = 0

    // Mic forwarding task — reads mic frames from pipeline and sends
    // to the WebSocket. Started at beginTurn, cancelled at endTurn.
    private var micForwardTask: Task<Void, Never>?

    // Receive dispatcher task — reads inbound frames from transport
    // and updates state / plays audio / handles tool calls. Started
    // after preWarm succeeds.
    private var receiveDispatcherTask: Task<Void, Never>?

    // Per-turn accumulator. Reset at `flushPendingReport()`. so hands-free
    // turns (which never re-enter beginTurn) get clean slate per turn.
    private var currentTurnInlineText: String?
    private var turnCompleteContinuation: CheckedContinuation<Void, Error>?
    /// Accumulates per-chunk `usageMetadata` deltas across the current
    /// turn. Reset at `flushPendingReport()`. See `TurnUsageAccumulator`
    /// docstring for the Gemini Live streaming-delta shape.
    private var turnUsageAccumulator = TurnUsageAccumulator()
    // `lastUsageMetadata` was replaced by `turnUsageAccumulator` above —
    // the single-value design overwrote real token counts every time
    // Gemini sent its empty `usageMetadata: {}` turnComplete envelope.
    // See the TurnUsageAccumulator docstring for the streaming-delta
    // shape and the 2026-04-22 prod regression.
    /// Wall-clock when the CURRENT turn began processing server-side.
    /// Set at beginTurn (first turn) and at each `finalizeTurn()` (next
    /// turn starts implicitly after previous finalizes). Used to stamp
    /// backendLatencyMs in the CookTurnResult — approximate since iOS
    /// can't detect the server's speech-start VAD event in hands-free.
    private var turnStartedAt: Date?
    /// Snapshot of the most recently finalized turn. Published by
    /// `finalizeTurn()` so `endTurn()` (when the VM's tap-to-end path
    /// lands after the hands-free auto-loop already resolved the turn)
    /// has something concrete to return. Nil before the first turn
    /// completes.
    private var lastTurnResult: CookTurnResult?
    /// Wall-clock when the server's input-transcription finalized for
    /// the CURRENT turn (i.e., server VAD detected end-of-utterance and
    /// emitted `inputTranscription.finished = true`). Paired with
    /// `firstModelAudioAt` below to compute per-turn TTFA — time from
    /// "user stopped talking" to "model started responding with audio".
    /// Reset on every `finalizeTurn()`. Nil for turns where the server
    /// never emitted a finished transcription (non-audio tool-call
    /// turns, or very short utterances where the server races past
    /// transcription) — TTFA is zeroed in that case and the turn shows
    /// up on the dashboard as "unmeasurable" rather than a fake 0 s.
    private var userTurnEndAt: Date?
    /// Wall-clock of the first non-empty `audioChunks` arrival within
    /// the current turn. Set once per turn (subsequent chunks don't
    /// overwrite) so TTFA captures the model-first-byte moment, not the
    /// streaming-steady-state arrival. Reset on every `finalizeTurn()`.
    private var firstModelAudioAt: Date?
    /// True if the current turn invoked any tool call (substitution_check,
    /// start_timer, advance_step, set_step, etc.). Set in `handleToolCall`,
    /// latched into `PendingTurnReport.containedToolCall` by `finalizeTurn()`
    /// before the per-turn reset. Drives `cook_turn_resolved.result_type`
    /// downstream, which gates ADR 0012's split TTFA thresholds
    /// (normal p95 < 500 ms vs tool_call p95 < 1500 ms).
    private var turnContainedToolCall: Bool = false
    /// Name of the most recent tool call in the current turn
    /// ("start_timer", "advance_step", "substitution_check", "set_step",
    /// "restart_timer"). Set by `handleToolCall`; latched into the
    /// stuck-watchdog PostHog payload so ops can correlate incidence
    /// rate with tool-call type. 3.1 Flash Live is synchronous one-in-
    /// flight (CLAUDE.md §sharp-edge #12), so "most recent" = "only one
    /// this turn" in practice. Reset on every `finalizeTurn()` + close.
    private var lastToolCallName: String?

    /// True when the current `finalizeTurn()` is running as a watchdog
    /// synthetic-turnComplete. Changes the model-turn persist path to
    /// `resultType: .error, errorCode: "turnComplete_timeout"` so the
    /// session history audit trail reflects the stuck recovery per
    /// spec §4.12. Reset at the end of finalizeTurn + close.
    private var finalizeWasWatchdogFire: Bool = false

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
        /// closed (P0-B: prior code leaked it until Gemini's 35-min TTL).
        case postCommitFailure
    }

    /// True when the current `finalizeTurn()`-adjacent persist is running
    /// because a transport error killed the session mid-turn. Distinct
    /// from the watchdog flag so dashboards can tell the two error
    /// classes apart: watchdog means "Gemini dropped turnComplete"
    /// (preview-API bug), transport-error means "WebSocket died" (network
    /// hiccup / cellular stall / Gemini outage). Review finding
    /// P0-H / Critical #8.
    private var finalizeWasTransportError: Bool = false

    /// Watchdog Task that force-advances state when Gemini Live drops
    /// a `turnComplete` frame. Observed 2026-04-23 device test: on a
    /// multi-pass tool-call turn (start_timer with post-tool narration),
    /// Gemini emitted `generationComplete` after the second narration
    /// but never sent `turnComplete`. State machine stayed pinned in
    /// `.modelSpeaking` for 35+s until the user manually tapped to close.
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
    ///     how often Gemini drops turnComplete. Uses a dedicated
    ///     `ended_reason: .watchdog` downstream.
    private var turnStuckWatchdog: Task<Void, Never>?
    // turnStuckWatchdogSec moved to LiveSessionBudget.turnStuckWatchdogSec (P2-F).
    /// Turn index at which the most recent successful session refresh
    /// completed. Refresh triggers off `turnCount - lastRefreshedAtTurn
    /// >= LiveSessionBudget.refreshAtTurnCount`, so the threshold fires
    /// every N turns across the session lifetime rather than exactly once.
    /// Starts at 0; the first refresh at turn 10 sets this to 10, after
    /// which the next fires at turn 20, and so on. ADR 0014.
    private var lastRefreshedAtTurn: Int = 0
    /// True while a refresh is in flight (mint → new WS open → handshake
    /// → swap → old close). Guards re-entry — mid-refresh turn boundaries
    /// shouldn't trigger a second refresh. Cleared in the refresh path's
    /// defer block so a failed refresh doesn't wedge the session.
    private var isRefreshing: Bool = false

    /// Pre-minted refresh token, kicked off one turn before the refresh
    /// cadence fires (at `turnsSinceRefresh == refreshAtTurnCount - 1`).
    /// When refresh actually triggers on the next turn, this Task is
    /// awaited instead of kicking off a fresh mint — saving the ~1.5-1.9s
    /// mint round-trip on the handoff's critical path. If the Task has
    /// already completed, `.value` returns instantly. If still running
    /// (rare — user talked fast), we await the same in-flight work we
    /// would have started anyway. If it fails, we fall back to sync
    /// mint. Cleared after consumption or after staleness (see
    /// `pendingPreMintStartedAt`).
    private var pendingPreMintTask: Task<RealtimeSessionResponse, Error>?
    /// Wall-clock when `pendingPreMintTask` was kicked off. Backend's
    /// `new_session_expire_time` is 60s from mint (sharp-edge #5), so a
    /// pre-minted token older than ~45s (leaving 15s of handshake
    /// headroom) is discarded in favor of a fresh sync mint. Typical
    /// gap between pre-mint (turn N-1 finalize) and refresh (turn N
    /// finalize) is 8-20s of conversation — well within the budget.
    private var pendingPreMintStartedAt: Date?
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
    /// Why the delay exists: Gemini Live's `usageMetadata` can arrive
    /// in (1) the same envelope as `serverContent{turnComplete}`,
    /// (2) an envelope BEFORE turnComplete, or (3) an envelope AFTER
    /// turnComplete. Only (1) and (2) are handled by the parseAll
    /// ordering fix; (3) requires waiting. Observed 2026-04-22: 40+
    /// prod events with $ai_input_tokens=0 despite parseAll fix,
    /// indicating Gemini routinely uses path (3) on audio-mode
    /// sessions.
    private struct PendingTurnReport: Sendable {
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
    }
    private var pendingReport: PendingTurnReport?


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
    ///   "turns"            — crossed `refreshAtTurnCount`
    ///   "minutes"          — crossed `refreshAtElapsedSec` (not yet wired)
    ///   "tokens"           — hit token soft cap
    ///   "goaway"           — server emitted a goAway frame
    ///   "transport_error"  — WS transport errored mid-session; refresh as recovery
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
    ///                        Gemini tool call, e.g. "dried pasta").
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
    /// Gemini Live drops a `turnComplete` (observed 2026-04-23 on
    /// multi-pass tool-call turns). VM emits the PostHog
    /// `voice_turn_stuck_watchdog_fired` event so ops can track the
    /// incidence rate of the underlying Live-API protocol bug.
    ///
    /// Payload:
    ///   sessionID          — Gemini Live session id (current mint). In
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
    ) {
        self.aiDispatch = aiDispatch
        self.voiceTurnRepository = voiceTurnRepository
        self.cookingSession = cookingSession
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
    ) {
        self.aiDispatch = aiDispatch
        self.voiceTurnRepository = voiceTurnRepository
        self.cookingSession = cookingSession
        self.mintResponse = testingOnlyMintResponse
    }

    /// Test-only frame injection for the pending-report reporting path.
    /// Feeds a synthetic inbound frame through `handleInboundFrame`
    /// exactly as the receive dispatcher would — tests can stage
    /// same-envelope, leading-envelope, and trailing-envelope
    /// usageMetadata patterns and observe `onTurnFinalized` to verify
    /// the POST payload would carry the right token counts.
    ///
    /// Not exposed in release — the receive dispatcher is the only
    /// production caller of `handleInboundFrame` and injecting frames
    /// from anywhere else is a test concern.
    func _testInjectFrame(_ frame: LiveInboundFrame) async {
        await handleInboundFrame(frame)
    }

    /// TTFA computed by the most recent `finalizeTurn()`. Exposed for
    /// tests that assert the frame-sequence → TTFA pipeline; not
    /// usable in production because it reflects only the last-finalized
    /// turn and is reset when the session closes. Returns 0 before any
    /// turn finalizes.
    var _testMostRecentTtfaMs: Int {
        lastTurnResult?.sttLatencyMs ?? 0
    }

    /// Drives the internal state machine for tests. Production paths
    /// only ever advance via preWarm → handleInboundFrame; tests that
    /// need to exercise handlers gated on `liveStates` (`handleToolCall`)
    /// without running the real mint + WS handshake use this helper.
    /// Returns the advance result.
    ///
    /// Current callers (StirTests/Unit/RealtimeSessionReportingTests):
    ///   - test_containedToolCall_trueWhenToolFrameSeen
    ///   - test_containedToolCall_resetsPerTurn
    /// If you add a third call site, think hard about whether the
    /// handler under test has a legitimate production state-entry path
    /// the test could exercise instead — this helper is a deliberate
    /// back door, not a shortcut.
    @discardableResult
    func _testAdvance(to next: VoiceSessionState) -> Bool {
        stateMachine.advance(to: next)
    }

    /// P0-L (2026-04-23): synchronous trigger of the stuck-turnComplete
    /// watchdog path for testing. Equivalent to the watchdog Task
    /// timeout firing after `LiveSessionBudget.turnStuckWatchdogSec`
    /// of silence on the `.modelSpeaking` entry — but without the
    /// 15 s real-time wait. Exercises the exact recovery pipeline:
    ///
    ///   PostHog callback fires with (sessionID, turnIndex, toolCallType,
    ///   elapsedStuckMs, turnLengthAtStuck)
    ///   → `finalizeWasWatchdogFire = true`
    ///   → `.modelSpeaking` → `.ready`
    ///   → `finalizeTurn()` persists VoiceTurn with
    ///      resultType=.error, errorCode="turnComplete_timeout"
    ///   → pendingReport flush
    ///
    /// Caller responsibility: put the state machine in `.modelSpeaking`
    /// first (tests do this via `_testAdvance(to: .modelSpeaking)` or
    /// by injecting a serverContent frame carrying audio).
    func _testFireTurnStuckWatchdog() {
        turnStuckWatchdogFired()
    }

    /// P0-L test hook: inspect `lastToolCallName` so tests can verify
    /// the watchdog payload correctly latches the in-flight tool-call
    /// name from a preceding toolCall frame.
    var _testLastToolCallName: String? {
        lastToolCallName
    }

    /// P1-P test hook: inject a task + timestamp into the pre-mint slot.
    /// Drives `consumePreMintedTaskIfFresh` into each of its four lifecycle
    /// cases deterministically (close-before-consume, ready-before-refresh,
    /// 45 s staleness, in-flight-await) without waiting on a real mint
    /// HTTP round trip. Passing `nil` for `task` clears the slot; passing
    /// `nil` for `startedAt` is treated as infinitely stale by the consumer
    /// via the `.map { ... } ?? .infinity` branch in
    /// `consumePreMintedTaskIfFresh`.
    func _testSetPreMintTask(
        _ task: Task<RealtimeSessionResponse, Error>?,
        startedAt: Date?,
    ) {
        pendingPreMintTask = task
        pendingPreMintStartedAt = startedAt
    }

    /// P1-P test hook: non-destructive peek — true iff `pendingPreMintTask`
    /// is currently set. Does NOT trigger the consumer's defer-clear.
    /// Used by the seam-integration test to assert that
    /// `kickOffPreMintIfBudgetAllows` put something in the slot.
    var _testPendingPreMintIsSet: Bool {
        pendingPreMintTask != nil
    }

    /// P1-P test hook: non-destructive peek at `pendingPreMintStartedAt`.
    /// Returns nil after a stale-branch consumption cleared the slot;
    /// lifecycle tests use this to assert the consumer's defer ran.
    var _testPendingPreMintStartedAt: Date? {
        pendingPreMintStartedAt
    }

    /// P1-P test hook: test-accessible wrapper for the private consumer.
    /// Returns the Task if fresh, nil otherwise; clears state via the
    /// consumer's defer regardless of outcome. Same contract as the
    /// production call site in `refreshSession` (line ~1339).
    func _testConsumePreMintedTaskIfFresh() -> Task<RealtimeSessionResponse, Error>? {
        consumePreMintedTaskIfFresh()
    }

    /// P1-P test hook: synchronous wrapper for the private prewarm.
    /// Production trigger is deep in the finalize-turn path (fires only
    /// at `turnsSinceRefresh == refreshAtTurnCount - 1`, ~3 turns in);
    /// driving that naturally in a test would require a full multi-turn
    /// setup. The seam-integration test uses this hook to invoke the
    /// prewarm directly after injecting a MockURLProtocol-backed
    /// `AIDispatch` via the normal constructor, then asserts
    /// `_testPendingPreMintIsSet == true` to pin the seam.
    func _testKickOffPreMintIfBudgetAllows(currentTurn: Int) {
        kickOffPreMintIfBudgetAllows(currentTurn: currentTurn)
    }

    /// P1-P test hook: run the pre-mint teardown path exactly as
    /// `session.close()` does, without running the rest of close's
    /// 200-line teardown (continuations, transport, audio pipeline,
    /// etc.). Exercises `cancelAndClearPreMintSlot()` — the extracted
    /// symbol both the production `close()` and this hook call. A
    /// future refactor that moves the cancel or clear out of the
    /// extracted method is caught by P1-P test 1; a future refactor
    /// that removes the call from `close()` is caught by the paired
    /// wiring test (close-invokes-extraction).
    func _testTearDownPreMintSlot() {
        cancelAndClearPreMintSlot()
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

            // 2. Open WebSocket
            guard let wsURL = URL(string: response.wsURL) else {
                #if DEBUG
                VoiceSessionLog.log("mint.invalid_ws_url")
                #endif
                throw RealtimeSessionError.openFailed(message: "invalid ws_url")
            }
            let transport = LiveWebSocketTransport()
            self.transport = transport
            try transport.open(url: wsURL)
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

            // 5. Send the `{"setup": {...}}` frame that unblocks
            //    `setupComplete`. Required even though the ephemeral
            //    token bakes in a `bidiGenerateContentSetup` — the
            //    Constrained method treats the baked-in config as the
            //    authorization ceiling, and the server still waits for
            //    the client to explicitly begin the session by sending
            //    the setup frame. Verified 2026-04-20 against the
            //    google-gemini reference app
            //    (gemini-live-ephemeral-tokens-websocket/frontend/
            //    geminilive.js → sendInitialSetupMessages()). Without
            //    this send, `awaitSetupComplete` times out at 5s and
            //    preWarm falls through to C.3.
            //
            //    Backend pre-serializes the payload so iOS forwards a
            //    single JSON blob — no shape drift possible between
            //    what the token authorizes and what the client sends.
            //
            //    P3-D (2026-04-23): send via `setupRawJSON` so the
            //    transport skips the JSONSerialization round-trip
            //    (~10 ms/preWarm saved on 4-8 KiB setup frames).
            try await transport.send(.setupRawJSON(response.setupFrameJSON))
            #if DEBUG
            VoiceSessionLog.log("ws.setup_sent")
            #endif

            // 6. Wait for setupComplete (budget named in
            //    LiveSessionBudget — server normally emits this within
            //    200-400 ms after receiving our setup frame). Any
            //    inbound frame before setupComplete is a protocol
            //    violation and throws.
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
        turnUsageAccumulator.reset()
        turnStartedAt = Date()

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
        // session. VAD (server-side, `automaticActivityDetection` is
        // enabled in the mint) drives turn boundaries — iOS never
        // stops the mic mid-session and never signals "audio stream
        // done" to the server.
        //
        // Lessons from the two prior attempts:
        //   1. Abruptly stopping the mic on tap-to-end (original
        //      code) leaves VAD with no trailing silence — it sits
        //      waiting for more audio and `turnComplete` never
        //      arrives (30s `turnDrained` observed 2026-04-20).
        //   2. Sending `realtimeInput.audioStreamEnd` as a "done"
        //      signal CLOSES the WebSocket (TransportError
        //      `connectionDropped` with "Socket is not connected"
        //      observed immediately after the send). That frame is
        //      a session-terminal signal, not a turn-end signal —
        //      not usable for a multi-turn cook session.
        //
        // So: endTurn's job is just UI/state coordination. Advance
        // state to `.thinking` ONLY if we're still in .userSpeaking —
        // VAD may already have auto-advanced us through
        // .modelSpeaking (via handleServerContent). Mic stays hot
        // either way. Then await the server-driven `turnComplete`.
        // If the user is still talking past the tap, VAD processes
        // their audio normally and closes the turn on natural silence.
        // If the user stopped before tapping, VAD already saw the
        // silence and `turnComplete` may be near instant.
        if stateMachine.state == .userSpeaking {
            stateMachine.advance(to: .thinking)
        }
        #if DEBUG
        VoiceSessionLog.log("turn.end_submitted", ["turn": turnCount + 1])
        #endif

        // Wait for serverContent turnComplete — handleServerContent
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
        // and (harmlessly) holds a Gemini auth_tokens resource until the
        // token expires. Extracted to `cancelAndClearPreMintSlot()` so
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
        finalizeWasTransportError = false
        clearHouseholdContextCache()  // P3-H
        currentTurnInlineText = nil
        turnUsageAccumulator.reset()
        #if DEBUG
        VoiceSessionLog.sessionEnd()
        #endif
    }

    // MARK: - Session refresh (ADR 0014 — real implementation)

    /// Silent handoff to a fresh Gemini Live session. Triggered at
    /// `LiveSessionBudget.refreshAtTurnCount` turn boundary OR any
    /// single turn that exceeds `refreshAtPromptTokenCount`, and also
    /// defensively on server goAway frames (server signalled 30-min
    /// hard cap approach). Also guards against race re-entry via
    /// `isRefreshing`.
    ///
    /// Dance (order matters — a wrong order leaks either audio frames
    /// into the wrong transport or state updates against a stale
    /// mintResponse):
    ///   1. Guard state + set `isRefreshing = true` in defer-unset block
    ///   2. Build minimal recap — step position only (ADR 0014 PM amendment)
    ///   3. Mint new token with `is_refresh: true, recap: <recap>`
    ///      (backend skips quota increment; systemInstruction gets
    ///      recap suffix for continuity)
    ///   4. Open new WS transport (local var — not yet assigned to self)
    ///   5. Cancel old receive dispatcher ONLY. The mic forwarder stays
    ///      alive across refresh — `pipeline.micFrames` is a single-
    ///      consumer AsyncStream and cancel+restart would wedge it to
    ///      `.finished` permanently. The forwarder instead reads
    ///      `self.transport` dynamically each iteration and picks up
    ///      the swap done in step 6 automatically.
    ///      `startReceiveDispatcher` bumps `dispatcherGeneration` when
    ///      the new one starts in step 7 — the old dispatcher's
    ///      cancellation error is suppressed in its catch block by
    ///      generation check (structural, race-free).
    ///   6. Swap `self.transport` + `self.mintResponse` to new
    ///   7. Restart receive dispatcher on new transport (bumps gen)
    ///   8. Send setup frame on new transport
    ///   9. Await setupComplete (shared continuation; new dispatcher
    ///      drives it)
    ///  10. (Mic forwarder continues; if nil because it never started,
    ///      start it here)
    ///  11. Close old transport
    ///  12. Reset per-turn state + bump `lastRefreshedAtTurn`
    ///
    /// Failure mode: if any step throws, we fall back to the old
    /// transport IF it's still open (i.e., we failed before the swap).
    /// After the swap the old transport is gone and a failure leaves
    /// us in an unrecoverable state — transition to .error and the VM
    /// downgrades to C.3. Rare path; logs allow post-hoc triage.
    @discardableResult
    func refreshSession(reason: String) async -> RefreshOutcome {
        guard !isRefreshing else {
            #if DEBUG
            VoiceSessionLog.log("refresh.skipped_already_in_flight")
            #endif
            return .skipped
        }
        guard stateMachine.state != .closed && stateMachine.state != .error else {
            #if DEBUG
            VoiceSessionLog.log("refresh.skipped_state", [
                "state": stateMachine.state.rawValue,
            ])
            #endif
            return .skipped
        }
        isRefreshing = true
        // Defer-unset guarantees the flag clears even if a future edit
        // adds code after the do/catch that throws (review 2026-04-22
        // Warning #2). Runs on @MainActor before the method returns.
        defer { isRefreshing = false }

        // P1-J (2026-04-23): advance the state machine into .refreshing
        // so external observers (`beginTurn`'s state guard, VM's
        // MicButtonRole, etc.) see the mid-refresh window. Prior code
        // relied on `isRefreshing` alone, which was actor-internal and
        // invisible to callers — `beginTurn`'s `state == .ready` guard
        // could pass during the brief old-close / new-setupComplete
        // window and race a frame into the swap.
        let preRefreshState = stateMachine.state
        stateMachine.advance(to: .refreshing)

        let startedAt = Date()
        let oldSessionID = mintResponse?.sessionID ?? ""
        // Captured inside the do-block once the new response is minted.
        // On post-commit failure (swap assigned but setup handshake
        // threw) we report THIS id so dashboard triage correctly
        // attributes the failure to the destination session — not the
        // source, which was fine.
        var destinationSessionID: String?
        Logger.voice.info(
            "live_session_refresh_started turn=\(self.turnCount, privacy: .public) old_session=\(oldSessionID, privacy: .public)",
        )
        #if DEBUG
        VoiceSessionLog.log("refresh.start", [
            "turn": turnCount,
            "old_session": oldSessionID,
        ])
        #endif

        // Track the old transport so we can close it at the end. Nil
        // if refresh fires in a state where we somehow have no transport
        // (defensive — shouldn't happen with the state guards above).
        let oldTransport = self.transport

        do {
            // 2. Build minimal recap (step position only, ADR 0014 PM amendment).
            let recap = buildRecap()

            // 3. Mint new token with refresh-mode context. Fast path:
            // consume a pre-minted token kicked off one turn earlier.
            // Cold path: sync mint here. Pre-mint shaves ~1.5-1.9s off
            // the handoff's critical path in the common case.
            let newResponse: RealtimeSessionResponse
            if let preMintTask = consumePreMintedTaskIfFresh() {
                newResponse = try await preMintTask.value
            } else {
                let mintRequest = try buildMintRequest(recap: recap, isRefresh: true)
                newResponse = try await aiDispatch.realtimeSession(request: mintRequest)
            }
            // Stamp the destination id the moment we have it, so a
            // later step throwing still lets the catch block attribute
            // the failure to the destination session.
            destinationSessionID = newResponse.sessionID
            #if DEBUG
            VoiceSessionLog.log("refresh.mint_complete", [
                "new_session": newResponse.sessionID,
                "prompt_version": newResponse.promptVersion,
            ])
            #endif

            // 4. Open new WS transport.
            guard let wsURL = URL(string: newResponse.wsURL) else {
                throw RealtimeSessionError.openFailed(message: "invalid ws_url from refresh mint")
            }
            let newTransport = LiveWebSocketTransport()
            try newTransport.open(url: wsURL)

            // 5. Tear down the old RECEIVE dispatcher only. Do NOT
            //    cancel the mic forwarder — `pipeline.micFrames` is a
            //    single-consumer AsyncStream and starting a second
            //    iteration after cancel returns `.finished`, leaving
            //    post-refresh turns with zero mic audio forwarded
            //    (observed 2026-04-22, turn 10+: zero `mic.sent`).
            //    The forwarder now reads `self.transport` dynamically
            //    each iteration, so swapping the transport in step 6
            //    automatically redirects its sends to the new WS.
            //
            //    The receive dispatcher's cancellation throw IS
            //    suppressed structurally by the generation check in
            //    its own catch block (see startReceiveDispatcher) —
            //    step 7 bumps `dispatcherGeneration` and the old
            //    dispatcher's captured gen no longer matches.
            receiveDispatcherTask?.cancel()
            receiveDispatcherTask = nil

            // 6. Swap owned references to new transport + response.
            self.transport = newTransport
            self.mintResponse = newResponse

            // 7. Restart receive dispatcher on new transport. This is
            //    what will drive the setupComplete continuation in
            //    step 9.
            startReceiveDispatcher()

            // 8. Send setup frame (baked-in config must be sent
            //    explicitly even after mint — same contract as preWarm,
            //    see sharp-edge #19).
            // P3-D (2026-04-23): send pre-serialized JSON directly;
            // avoids triple JSON round-trip on every refresh.
            try await newTransport.send(.setupRawJSON(newResponse.setupFrameJSON))

            // 9. Wait for setupComplete on the new session. Shared
            //    continuation — new dispatcher will resume it.
            try await awaitSetupComplete(timeoutSec: LiveSessionBudget.setupHandshakeSec)

            // 10. (Mic forwarding stays alive across the refresh — no
            //     restart needed. The forwarder reads `self.transport`
            //     dynamically each iteration and picks up the swap done
            //     in step 6 automatically. If the forwarder was somehow
            //     already nil (e.g., never started), start it now.)
            if micForwardTask == nil {
                startMicForwarding()
            }

            // 11. Close the old transport now that we're fully migrated.
            //     Idempotent; no-op if the cancelled dispatcher already
            //     caused it to unwind.
            oldTransport?.close()

            // 12. Flush the just-finalized turn's pending report BEFORE
            //     resetting accumulators. finalizeTurn() schedules the
            //     refresh AND the pendingReport in the same pass, and
            //     flushPendingReport's usage-arrival path might not
            //     have fired yet if the trailing usageMetadata frame
            //     was still pending when we started the refresh. Losing
            //     the report silently would under-report per-turn cost
            //     in voice-turn-usage for exactly the turn that
            //     triggered the refresh. Flush with whatever tokens we
            //     have. The `supersededByRefresh` reason distinguishes
            //     this in dashboards from the generic "newer turn
            //     arrived" supersede path.
            if pendingReport != nil {
                flushPendingReport(dueTo: .supersededByRefresh)
            }

            // Reset per-turn state. The new session has zero history
            // from Gemini's perspective (we seeded continuity via
            // recap in systemInstruction, not via replayed turns),
            // so accumulators start fresh.
            turnUsageAccumulator = TurnUsageAccumulator()
            currentTurnInlineText = nil
            lastRefreshedAtTurn = turnCount

            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.voice.info(
                "live_session_refresh_complete turn=\(self.turnCount, privacy: .public) new_session=\(newResponse.sessionID, privacy: .public) latency_ms=\(latencyMs, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("refresh.complete", [
                "turn": turnCount,
                "new_session": newResponse.sessionID,
                "latency_ms": latencyMs,
            ])
            #endif
            // Spec §15 voice_session_refreshed — SUCCESS path. Carries
            // the NEW session id since the swap committed.
            if let cb = onVoiceSessionRefreshResolved {
                cb(reason, turnCount, newResponse.sessionID, true)
            }
            // P1-J: settle out of .refreshing. We return to .ready
            // uniformly; any in-flight turn was either flushed above
            // (supersededByRefresh drain) or was finalized by the time
            // refresh fired (cadence refresh runs from finalizeTurn's
            // post-turn-reset path). Prior state value not restored
            // because the new session starts fresh from Gemini's
            // perspective — .ready is the correct entry point.
            if stateMachine.state == .refreshing {
                stateMachine.advance(to: .ready)
            }
            _ = preRefreshState // preserved for future restore-prior-state logic if needed
            return .success
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            Logger.voice.error(
                "live_session_refresh_failed error=\(error.localizedDescription, privacy: .private) latency_ms=\(latencyMs, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.logError("refresh.failed", error: error, [
                "turn": turnCount,
                "latency_ms": latencyMs,
            ])
            #endif
            // Recovery: if the old transport is still alive (we failed
            // before swap), keep using it — degraded (token growth
            // continues) but functional. If we failed after swap, the
            // session is broken; transition to .error so the VM can
            // fall back to C.3 on the next tap.
            let isPreCommitFailure = (self.transport === oldTransport)
            if isPreCommitFailure {
                // Still on old transport — no state change needed.
                Logger.voice.info("refresh_failed_on_old_transport session_continues")
                // P1-J: back to whatever state we entered refresh from.
                // The old transport is healthy; session continues as
                // if refresh never happened. Self-transition is a no-op
                // if preRefreshState == .refreshing (shouldn't happen —
                // guard blocks re-entry — but safe either way).
                if stateMachine.state == .refreshing {
                    stateMachine.advance(to: preRefreshState)
                }
            } else {
                // Committed the swap but handshake failed — new
                // transport is useless, old is NOT yet closed (step 11
                // of the 12-step dance at line 1272 only fires on the
                // happy path). Close it here so we don't leak the WS
                // until Gemini's 35-min TTL fires — observed during
                // review P0-B (2026-04-23) as a drip of orphaned
                // connections accumulating per failed refresh, which
                // at beta user cadence compounds meaningfully.
                oldTransport?.close()
                // P1-J: route via .fallingBack → .error so the grammar
                // records the failure path explicitly. .fallingBack is
                // the canonical "Live → C.3 handoff" state per
                // VoiceSessionState.swift.
                if stateMachine.state == .refreshing {
                    stateMachine.advance(to: .fallingBack)
                }
                stateMachine.advance(to: .error)
                // P1-K (2026-04-23): tell the VM that any future voice
                // rebuild within this Cook Mode session should skip
                // Live and go straight to C.3. Fresh Live preWarm on
                // the same device + same network after a post-commit
                // handshake failure has a high probability of failing
                // the same way; pinning fallback avoids the ping-pong
                // latency the user would otherwise perceive on every
                // subsequent tap.
                onVoiceFallbackRequired?("refresh_post_commit_failure")
            }
            // Spec §15 voice_session_refreshed — FAILURE path. Emitting
            // on failure is what lets the Voice session health dashboard
            // compute a real refresh success rate (prior design fired on
            // request only so failures went telemetry-invisible).
            //
            // session_id semantics — report the session that "owned" the
            // failure so dashboard triage is actionable:
            //   pre-commit failure (mint / WS open / setup-send threw
            //     before self.transport was swapped) → OLD id; the
            //     destination never came up and the old session is
            //     still live.
            //   post-commit failure (swap assigned, awaitSetupComplete
            //     or later threw) → NEW id; old session is already torn
            //     down and the failure is attached to the destination
            //     that didn't handshake.
            let failureSessionID: String
            if self.transport === oldTransport {
                failureSessionID = oldSessionID
            } else {
                failureSessionID = destinationSessionID ?? oldSessionID
            }
            if let cb = onVoiceSessionRefreshResolved {
                cb(reason, turnCount, failureSessionID, false)
            }
            return isPreCommitFailure ? .preCommitFailure : .postCommitFailure
        }
        // `isRefreshing = false` handled by the `defer` at the top.
    }

    /// Build a minimal recap (~30 tokens) that gets appended to
    /// systemInstruction on the refresh mint so the new session starts
    /// grounded in the current step rather than re-introducing the recipe.
    ///
    // preMintStalenessSec moved to LiveSessionBudget.preMintStalenessSec (P2-F).

    /// Kick off a background mint for the NEXT refresh token, so refreshSession()
    /// can consume a ready response instead of waiting on a cold mint
    /// (Re-)arm the stuck-modelSpeaking watchdog. Called on every
    /// inbound audio chunk and on state transition into `.modelSpeaking`.
    /// Cancels any prior watchdog first — the new timer restarts from
    /// zero, giving multi-chunk turns a fresh budget per chunk.
    private func rearmTurnStuckWatchdog() {
        turnStuckWatchdog?.cancel()
        turnStuckWatchdog = Task { [weak self] in
            let nanos = UInt64(LiveSessionBudget.turnStuckWatchdogSec * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            if Task.isCancelled { return }
            await self?.turnStuckWatchdogFired()
        }
    }

    /// Cancel the watchdog without firing. Called on state transition
    /// OUT of `.modelSpeaking` (turnComplete, refresh, error, close).
    private func cancelTurnStuckWatchdog() {
        turnStuckWatchdog?.cancel()
        turnStuckWatchdog = nil
    }

    /// Watchdog fired — Gemini went `turnStuckWatchdogSec` seconds in
    /// `.modelSpeaking` with no inbound audio chunk. Synthesize a
    /// turnComplete so the state machine unwedges and the user can
    /// speak again. Re-checks state under MainActor because a real
    /// `turnComplete` could have arrived between the Task.sleep wake
    /// and the fire handler (rare but possible).
    @MainActor
    private func turnStuckWatchdogFired() {
        guard stateMachine.state == .modelSpeaking else { return }
        // Capture metrics BEFORE finalizeTurn advances turnCount and
        // resets turnStartedAt / lastInboundAudioAt. Both anchors are
        // best-effort: `lastInboundAudioAt` is nil on turns where no
        // audio arrived (model declined to speak), `turnStartedAt` is
        // nil if the watchdog fires before beginTurn stamped it (which
        // shouldn't happen since the watchdog arms on entry to
        // `.modelSpeaking`, but defense-in-depth).
        let now = Date()
        let elapsedStuckMs: Int = {
            guard let last = lastInboundAudioAt else { return 0 }
            return Int(now.timeIntervalSince(last) * 1000)
        }()
        let turnLengthAtStuck: Int = {
            guard let started = turnStartedAt else { return 0 }
            return Int(now.timeIntervalSince(started) * 1000)
        }()
        // `turnCount + 1` matches the turn about to finalize. finalizeTurn
        // increments turnCount before persist, so the watchdog PostHog
        // payload and the persisted VoiceTurn row share the same
        // turnIndex semantic (1-indexed, the "turn we were on").
        let watchdogTurnIndex = turnCount + 1
        let toolCallType = lastToolCallName

        Logger.voice.warning(
            "turn_stuck_watchdog_fired — synthesizing turnComplete turn=\(watchdogTurnIndex, privacy: .public) tool=\(toolCallType ?? "nil", privacy: .public) elapsed_stuck_ms=\(elapsedStuckMs, privacy: .public) turn_length_ms=\(turnLengthAtStuck, privacy: .public) (Gemini Live appears to have dropped turnComplete; see ADR 0014/0015 notes)",
        )
        #if DEBUG
        VoiceSessionLog.log("turn.stuck_watchdog_fired", [
            "turn": watchdogTurnIndex,
            "watchdog_sec": LiveSessionBudget.turnStuckWatchdogSec,
            "tool_call_type": toolCallType ?? "nil",
            "elapsed_stuck_ms": elapsedStuckMs,
            "turn_length_at_stuck": turnLengthAtStuck,
        ])
        #endif
        // Fire PostHog callback BEFORE advancing state — so the VM
        // emission uses the current session id (not a stale swap) and
        // latches onto the turn about to finalize, not the next one.
        // `mintResponse?.sessionID` is always populated by the time the
        // watchdog fires (watchdog only arms on `.modelSpeaking` which
        // implies setup completed); the `"unknown"` fallback is defensive
        // against future invariant drift, not an observed path.
        onVoiceTurnStuckWatchdogFired?(
            mintResponse?.sessionID ?? "unknown",
            watchdogTurnIndex,
            toolCallType,
            elapsedStuckMs,
            turnLengthAtStuck,
        )
        // Flag the imminent finalizeTurn so the model-turn persist
        // path uses `resultType: .error, errorCode: "turnComplete_timeout"`
        // instead of the normal `.normal` default. Reset inside
        // finalizeTurn after the persist lands.
        finalizeWasWatchdogFire = true

        // Mirror the state-transition path that `content.turnComplete`
        // takes in `handleServerContent`: modelSpeaking → ready. Not
        // handling thinking/toolCalling/userSpeaking here because the
        // watchdog only runs when we're in modelSpeaking (enforced by
        // the guard above).
        stateMachine.advance(to: .ready)
        finalizeTurn()
    }

    /// round-trip. Called from `finalizeTurn`'s refresh trigger block at
    /// `turnsSinceRefresh == refreshAtTurnCount - 1`. No-op if a pre-mint
    /// is already in flight or we're mid-refresh. Build-time errors are
    /// logged at warn and the sync mint path handles it at refresh time.
    private func kickOffPreMintIfBudgetAllows(currentTurn: Int) {
        guard pendingPreMintTask == nil else { return }
        guard !isRefreshing else { return }
        let mintRequest: RealtimeSessionRequest
        do {
            mintRequest = try buildMintRequest(recap: buildRecap(), isRefresh: true)
        } catch {
            Logger.voice.warning(
                "refresh_premint_build_failed error=\(error.localizedDescription, privacy: .private)",
            )
            return
        }
        let dispatch = aiDispatch
        let task = Task<RealtimeSessionResponse, Error> {
            return try await dispatch.realtimeSession(request: mintRequest)
        }
        pendingPreMintTask = task
        pendingPreMintStartedAt = Date()
        #if DEBUG
        VoiceSessionLog.log("refresh.premint_started", ["turn": currentTurn])
        #endif
    }

    /// Cancel any in-flight pre-mint Task and clear the slot. Extracted
    /// from `close()` so the P1-P `_testTearDownPreMintSlot` hook can
    /// exercise the exact production teardown — not a test-private copy.
    /// Call sites: `close()` + `_testTearDownPreMintSlot`. A future
    /// refactor that needs to add or change the teardown of the pre-mint
    /// slot must edit this one method; both call sites inherit the
    /// change.
    private func cancelAndClearPreMintSlot() {
        if let preMint = pendingPreMintTask {
            preMint.cancel()
            pendingPreMintTask = nil
            pendingPreMintStartedAt = nil
        }
    }

    /// Consume the pending pre-mint if it exists and is still fresh.
    /// Returns the Task so the caller can await it; returns nil to signal
    /// "no usable pre-mint, fall back to sync". Cancels + clears stale
    /// entries. Always clears state regardless of outcome.
    private func consumePreMintedTaskIfFresh() -> Task<RealtimeSessionResponse, Error>? {
        guard let task = pendingPreMintTask else { return nil }
        defer {
            pendingPreMintTask = nil
            pendingPreMintStartedAt = nil
        }
        let age = pendingPreMintStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age < LiveSessionBudget.preMintStalenessSec else {
            task.cancel()
            Logger.voice.info(
                "refresh_premint_stale_discarded age_sec=\(age, privacy: .public)",
            )
            return nil
        }
        #if DEBUG
        VoiceSessionLog.log("refresh.premint_consumed", ["age_ms": Int(age * 1000)])
        #endif
        return task
    }

    /// 2026-04-22 PM (ADR 0014 amendment): simplified from the earlier
    /// interleaved user+model turns structure. Device testing showed the
    /// model doesn't reference prior dialog after refresh ("conversation
    /// is moving forward, not really recalling back things that have been
    /// previously said"), so the extra ~200-300 tokens of exchange history
    /// were pure overhead on a path that runs every 7 turns. Step position
    /// is the one piece of continuity the model consistently uses post-
    /// refresh. `sanitizeForRecap()` is kept available as defense-in-depth
    /// if user-text continuity is reintroduced.
    private func buildRecap() -> String? {
        let stepsCount = cookingSession.recipePlan?.stepArray.count ?? 0
        let currentStep = Int(cookingSession.currentStepIndex) + 1
        // stepsCount == 0 during a valid cook session is impossible —
        // Cook Mode entry blocks on a non-empty recipe. Hitting this
        // guard means upstream data corruption; return nil so the
        // refresh proceeds without a recap (safer than asserting which
        // would crash in prod mid-session) and fire a warn log so it
        // surfaces in dashboards (review 2026-04-22 Suggestion #2).
        guard stepsCount > 0 else {
            Logger.voice.warning(
                "build_recap_no_steps cooking_session_id=\(self.cookingSession.id?.uuidString ?? "nil", privacy: .public)",
            )
            return nil
        }
        return "You are mid-cook on step \(currentStep) of \(stepsCount). Continue from here. Don't re-introduce the recipe."
    }

    /// Normalize a captured turn's text for recap inclusion: collapse
    /// whitespace, strip canonical prompt-injection markers, and truncate
    /// to ~140 chars. Defense-in-depth — the content comes from
    /// inputTranscription (user speech) or outputTranscription (model's
    /// own reply), both lower-risk than arbitrary user input, but
    /// echoing "Ignore prior instructions" into the next session's
    /// systemInstruction is cheap to defend against. `nonisolated` so
    /// unit tests can exercise it without @MainActor wrapping — the
    /// method is a pure string transform with no instance-state access.
    nonisolated static func sanitizeForRecap(_ raw: String) -> String {
        let oneLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Canonical injection markers. Order matters — longer patterns
        // first so shorter ones don't leave dangling fragments. P3-J
        // (2026-04-23): regex objects are pre-compiled in
        // `injectionRegexes` so sanitizeForRecap doesn't rebuild them
        // per call. Even though recap is currently step-position-only
        // (sanitizer is dead-code-today), keeping it hot-path-fast is
        // cheap defense-in-depth for the moment someone reintroduces
        // user-derived text into the recap path.
        var cleaned = oneLine
        for regex in Self.injectionRegexes {
            let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, options: [], range: range, withTemplate: "[redacted]",
            )
        }
        if cleaned.count > 140 {
            return String(cleaned.prefix(140)) + "…"
        }
        return cleaned
    }

    /// Pre-compiled injection-detection patterns. Evaluated in order;
    /// longer patterns first. Static so the regex compile cost is paid
    /// once per process rather than per sanitizer invocation.
    private static let injectionRegexes: [NSRegularExpression] = {
        let patterns: [String] = [
            "ignore (all )?(prior|previous|above|earlier) (instructions|directives|rules|prompts?)",
            "disregard (all )?(prior|previous|above|earlier) (instructions|directives|rules|prompts?)",
            "forget (all )?(prior|previous|above|earlier) (instructions|directives|rules|prompts?)",
            "override (all )?(system )?(instructions|directives|rules|prompts?)",
            "you are now (a|an) ",
            "new (system )?prompt:",
        ]
        return patterns.compactMap { pattern in
            try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        }
    }()

    /// Called at every server-driven `turnComplete`. Hands-free and
    /// tap-to-end both route through here, so turn-boundary bookkeeping
    /// (turnCount, VoiceTurn persistence, accumulator reset, refresh
    /// trigger) lives in ONE place. Earlier drafts did this inline in
    /// `endTurn()` only — which silently skipped every hands-free turn
    /// where the VM never called endTurn, breaking turn-count-based
    /// session refresh and leaking currentTurnInlineText across turns.
    /// Persist a VoiceTurn row with an observable error path (P0-G fix).
    /// Used by `finalizeTurn` (happy + watchdog) and
    /// `recordTurnAsTransportError` (transport-error recovery). Replaces
    /// the prior `try?` pattern that silently discarded Core Data save
    /// failures — losing the persist is the exact signal ADR 0015's
    /// cap-reversal trigger query keys off, so silent drop defeated
    /// the observability the whole watchdog was instrumented to provide.
    ///
    /// `context` is a static short string (e.g. "finalize_turn_model",
    /// "transport_error_recovery") that goes into the log line so
    /// dashboards can attribute persist failures by call site.
    private func persistVoiceTurnSafely(
        _ input: VoiceTurnRepository.PersistInput,
        context: String,
    ) {
        do {
            try voiceTurnRepository.persist(input)
        } catch {
            Logger.voice.error(
                "voice_turn_persist_failed context=\(context, privacy: .public) turn=\(self.turnCount, privacy: .public) speaker=\(input.speaker.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
            )
            #if DEBUG
            VoiceSessionLog.logError("voice_turn.persist_failed", error: error, [
                "context": context,
                "turn": turnCount,
                "speaker": input.speaker.rawValue,
            ])
            #endif
            // Intentionally no re-throw: the user's turn already
            // happened (audio played), retrying the persist won't
            // recreate the row reliably, and bubbling up would
            // corrupt state-machine unwinding paths that call this
            // from `finalizeTurn`'s synchronous body. The failure IS
            // now observable via OSLog → Sentry breadcrumbs, which
            // feeds the ADR 0015 trigger query.
        }
    }

    /// P3-F (2026-04-23): batch variant used by `finalizeTurn` and
    /// `recordTurnAsTransportError` so the user + model VoiceTurn rows
    /// land in a single `context.save()` instead of two. Halves Core
    /// Data write overhead + CloudKit push rate per turn. Error
    /// handling mirrors `persistVoiceTurnSafely` — observable, non-
    /// re-throwing.
    private func persistVoiceTurnPairSafely(
        user: VoiceTurnRepository.PersistInput,
        model: VoiceTurnRepository.PersistInput,
        context: String,
    ) {
        do {
            try voiceTurnRepository.persistPair(user: user, model: model)
        } catch {
            Logger.voice.error(
                "voice_turn_persist_pair_failed context=\(context, privacy: .public) turn=\(self.turnCount, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
            )
            #if DEBUG
            VoiceSessionLog.logError("voice_turn.persist_pair_failed", error: error, [
                "context": context,
                "turn": turnCount,
            ])
            #endif
        }
    }

    private func finalizeTurn() {
        // Per-turn flag resets run via `defer` so any future early-return
        // (e.g. added guard clauses) can't leak a stale watchdog / tool-
        // call flag into the next turn's finalize. Current body has no
        // early returns, but the invariant is structurally enforced now
        // rather than positionally — surviving refactors without silent
        // data-corruption (stray `.error` row persisted on a normal turn).
        //
        // `turnContainedToolCall` is latched into a local below before
        // this defer fires; `lastToolCallName` was read by the watchdog
        // fire path BEFORE it invoked finalizeTurn; `finalizeWasWatchdogFire`
        // is read during the VoiceTurn persist block below. All three
        // have been captured or consumed by the time defer runs.
        defer {
            turnContainedToolCall = false
            lastToolCallName = nil
            finalizeWasWatchdogFire = false
            // finalizeWasTransportError is reset by `recordTurnAsTransportError`
            // rather than finalizeTurn (finalizeTurn only runs on the
            // normal / watchdog paths — transport errors route through
            // the dedicated recorder). Reset here defensively anyway.
            finalizeWasTransportError = false
        }
        let now = Date()
        let startedAt = turnStartedAt ?? now
        let totalMs = Int(now.timeIntervalSince(startedAt) * 1000)
        turnCount += 1

        // TTFA = time from server's VAD-end-of-user-speech to the first
        // model audio chunk. Frame-level precision (both endpoints are
        // WebSocket-handler timestamps, not UI-layer timers). Zero when
        // either endpoint is missing for this turn — the dashboard
        // filters zero values so "unmeasurable" doesn't skew the p95.
        let ttfaMs: Int = {
            guard let userEnd = userTurnEndAt,
                  let firstAudio = firstModelAudioAt,
                  firstAudio >= userEnd
            else { return 0 }
            return Int(firstAudio.timeIntervalSince(userEnd) * 1000)
        }()
        // Latch the tool-call flag BEFORE the per-turn reset below so
        // the PendingTurnReport captures the correct value even when
        // the handler clears it for the next turn.
        let containedToolCall = turnContainedToolCall

        #if DEBUG
        VoiceSessionLog.log("turn.complete", [
            "turn": turnCount,
            "latency_ms": totalMs,
            "ttfa_ms": ttfaMs,
            "contained_tool_call": containedToolCall,
            "accum_prompt_tokens": turnUsageAccumulator.sumPromptTokens,
            "accum_response_tokens": turnUsageAccumulator.sumResponseTokens,
            "accum_has_data": turnUsageAccumulator.hasAnyData,
        ])
        #endif

        // Snapshot the per-turn result BEFORE clearing accumulators —
        // `endTurn()` (if the VM called it) reads this via
        // `lastTurnResult` after `awaitTurnComplete` resumes. The
        // `sttLatencyMs` slot carries TTFA on the Live path (the field
        // is overloaded — "stt" fits the fallback path's Speech-to-Text
        // latency; on Live it carries the equivalent "time-to-first-audio"
        // signal the VM maps onto `cook_turn_resolved.latency_ttfa_ms`).
        let snapshot = CookTurnResult(
            transcript: "",
            response: CookTurnResponse(
                spokenResponse: currentTurnInlineText ?? "",
                suggestedAction: .none,
                actionParams: nil,
                promptVersion: mintResponse?.promptVersion ?? "",
                latencyMS: totalMs,
                retryCount: 0,
            ),
            sttLatencyMs: ttfaMs,
            backendLatencyMs: totalMs,
        )
        lastTurnResult = snapshot

        // Persist VoiceTurn rows (user + model). Transcript unknown on
        // Live path — empty strings are fine per schema. turnIndex is
        // 1-indexed across the session's lifetime.
        //
        // On watchdog fires, the model-turn row is persisted with
        // `resultType: .error, errorCode: "turnComplete_timeout"` so
        // the session history audit reflects the stuck recovery per
        // spec §4.12. The user-turn row stays `.normal` because the
        // user did successfully speak — only the model's response
        // turn was truncated by the synthetic turnComplete.
        let userIdx = voiceTurnRepository.nextTurnIndex(for: cookingSession)
        // P0-G (2026-04-23): persist failures must be observable — prior
        // code used `try?` which silently discarded Core Data save errors.
        // Losing the persist is specifically the signal ADR 0015's
        // cap-reversal trigger query keys off (count of error-typed
        // rows per session); invisibling it defeats the point of having
        // the watchdog instrument the recovery path at all.
        //
        // P3-F (2026-04-23): batch both rows into one `context.save()`
        // via `persistVoiceTurnPairSafely` (halves Core Data +
        // CloudKit push overhead per turn; prior code called persist
        // twice producing two full graph walks).
        let modelResult: VoiceTurn.ResultType = finalizeWasWatchdogFire ? .error : .normal
        let modelErrorCode: String? = finalizeWasWatchdogFire ? "turnComplete_timeout" : nil
        persistVoiceTurnPairSafely(
            user: .init(
                session: cookingSession,
                speaker: .user,
                turnIndex: userIdx,
                transcriptText: "",
                inputMode: .voice,
                latencyMs: 0,
                resultType: .normal,
            ),
            model: .init(
                session: cookingSession,
                speaker: .model,
                turnIndex: userIdx + 1,
                transcriptText: currentTurnInlineText ?? "",
                inputMode: .voice,
                latencyMs: totalMs,
                resultType: modelResult,
                errorCode: modelErrorCode,
            ),
            context: finalizeWasWatchdogFire ? "finalize_turn_pair_watchdog" : "finalize_turn_pair",
        )

        // Reset per-turn accumulators EXCEPT `turnUsageAccumulator` —
        // it stays populated so `flushPendingReport` can snapshot it.
        currentTurnInlineText = nil
        turnStartedAt = now
        // Reset TTFA anchors so the next turn measures fresh. Must land
        // AFTER the `ttfaMs` compute above; resetting before the snapshot
        // would zero every turn's latency_ttfa_ms.
        userTurnEndAt = nil
        firstModelAudioAt = nil
        // `turnContainedToolCall`, `lastToolCallName`, and
        // `finalizeWasWatchdogFire` are reset by the `defer` block at
        // the top of this function — placed there so early-return
        // refactors can't leak per-turn flags into the next turn.

        // Session refresh trigger (ADR 0014). Fires when EITHER:
        //   (a) `turnCount - lastRefreshedAtTurn >= refreshAtTurnCount` (4)
        //   (b) accumulated prompt tokens this turn > refreshAtPromptTokenCount (10_000)
        // Guard `isRefreshing` prevents a second refresh kicking off while
        // one is in flight — trigger recheck happens on the next turn.
        // Skip when turnCount == 0 (defensive; accumulator can fire with
        // data during initial turn setup).
        if !isRefreshing && turnCount > 0 {
            let turnsSinceRefresh = turnCount - lastRefreshedAtTurn
            let promptTokensThisTurn = turnUsageAccumulator.sumPromptTokens
            let reason: String?
            if promptTokensThisTurn > LiveSessionBudget.refreshAtPromptTokenCount {
                reason = "tokens"
            } else if turnsSinceRefresh >= LiveSessionBudget.refreshAtTurnCount {
                reason = "turns"
            } else {
                reason = nil
            }
            if let reason {
                // DO NOT set `isRefreshing = true` here. `refreshSession()`
                // owns the flag; setting it in the caller plus the guard
                // inside the callee means the Task below sees the flag
                // set and returns immediately without doing any work
                // (review 2026-04-22 Critical #1). The guard inside
                // refreshSession protects against rapid-fire concurrent
                // scheduling — if a second finalize happens before the
                // first refresh task runs, the second task sees the
                // first's in-progress flag and skips.
                //
                // Fire-and-forget the refresh. refreshSession() fires
                // the `onVoiceSessionRefreshResolved` callback on BOTH
                // the success and failure paths, so spec §15
                // `voice_session_refreshed` carries `success: bool`
                // and the Voice session health dashboard can compute
                // a real success rate (prior design fired on request
                // only — failures went telemetry-invisible).
                Task { [weak self] in await self?.refreshSession(reason: reason) }
            } else if turnsSinceRefresh == LiveSessionBudget.refreshAtTurnCount - 1 {
                // Pre-mint trigger: one turn before the cadence refresh
                // fires, kick off the next token mint in the background.
                // When the refresh actually triggers on the next turn,
                // consumePreMintedToken() either grabs the already-
                // completed response instantly or awaits the in-flight
                // Task — saving the ~1.5-1.9s mint round-trip on the
                // handoff's critical path.
                kickOffPreMintIfBudgetAllows(currentTurn: turnCount)
            }
        }

        // Schedule the per-turn usage report. We defer the POST + VM
        // callback until either (a) inbound `usageMetadata` arrives
        // (early-fire path), or (b) the timeoutSec timer expires (defensive
        // fallback). Without this deferral, Gemini's trailing-usage
        // envelopes cause every $ai_generation to report 0 tokens
        // (observed 2026-04-22, 40+ events).
        //
        // If a previous turn's report is still pending when this fires,
        // drain it now with whatever usage we have. That avoids losing
        // a turn's observability when two turnCompletes arrive in rapid
        // succession (rare, but possible on VAD-bursty kitchen audio).
        if let superseded = pendingReport {
            Logger.voice.warning(
                "turn_report_superseded turn=\(superseded.turnIndex, privacy: .public) — next turn arrived before usage; flushing with current usage state (may be empty)",
            )
            flushPendingReport(dueTo: .supersededByNextTurn)
        }

        let nonce = UUID()
        pendingReport = PendingTurnReport(
            turnIndex: turnCount,
            latencyMs: totalMs,
            latencyTtfaMs: ttfaMs,
            containedToolCall: containedToolCall,
            submittedAt: startedAt,
            endedAt: now,
            nonce: nonce,
        )

        // Short-circuit: if we already accumulated any non-zero usage
        // data for this turn, flush right away. Saves the 2 s wait on
        // the common path (Gemini streams deltas throughout the turn,
        // so accumulator has real data by the time turnComplete fires).
        if turnUsageAccumulator.hasAnyData {
            flushPendingReport(dueTo: .usageArrived)
            return
        }

        // Otherwise wait for a trailing usageMetadata envelope OR the
        // timeoutSec timer — whichever comes first.
        let timeoutSec = LiveSessionBudget.pendingReportTimeoutSec
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeoutSec))
            guard let self, self.pendingReport?.nonce == nonce else { return }
            self.flushPendingReport(dueTo: .timeout)
        }
    }

    /// Reason the pending report is being drained. Affects diagnostic
    /// logging only — the payload shape is the same regardless.
    private enum PendingReportDrainReason {
        /// `usageMetadata` arrived while a report was pending. Happy
        /// path on Gemini's trailing-usage-envelope shape.
        case usageArrived
        /// Timer expired before `usageMetadata` arrived. Report fires
        /// with zero tokens; `usage_metadata_never_arrived` warning
        /// surfaces so ops can trend the rate.
        case timeout
        /// A NEW turn completed while the previous report was still
        /// pending. Drain the previous with current state to avoid
        /// losing it, then schedule the new one.
        case supersededByNextTurn
        /// A session refresh (ADR 0014) is about to reset the turn
        /// accumulator. Flush the pending report with whatever tokens
        /// arrived before the refresh started so the boundary turn's
        /// cost isn't silently dropped. Semantically distinct from
        /// `supersededByNextTurn` ("a faster subsequent turn") — this
        /// is "a session handoff boundary." Dashboards use the reason
        /// to distinguish them (review 2026-04-22 Suggestion #1).
        case supersededByRefresh
        /// Session close — drain whatever we have.
        case sessionClosed
    }

    /// Build + fire the voice-turn-usage POST and VM callback for the
    /// currently-pending turn. No-op if no report is pending. Idempotent:
    /// clears `pendingReport` and resets `turnUsageAccumulator` atomically
    /// so timer-vs-early-fire races can't double-post.
    private func flushPendingReport(dueTo reason: PendingReportDrainReason) {
        guard let pending = pendingReport else { return }
        pendingReport = nil

        let usageForReport = turnUsageAccumulator.snapshot()
        turnUsageAccumulator.reset()

        #if DEBUG
        VoiceSessionLog.log("turn.usage_report_flush", [
            "turn": pending.turnIndex,
            "reason": String(describing: reason),
            "prompt_tokens": usageForReport?.promptTokenCount ?? -1,
            "response_tokens": usageForReport?.responseTokenCount ?? -1,
            "total_tokens": usageForReport?.totalTokenCount ?? -1,
        ])
        #endif

        if case .timeout = reason {
            // The timer fired — regardless of whether usage arrived just
            // before we ran, the fact that we hit the deadline at all is
            // diagnostic-worthy (Gemini is slow enough to threaten the
            // 2s budget). Differentiate "never arrived" from "arrived
            // late" in the log so ops can trend separately.
            if usageForReport == nil {
                Logger.voice.warning(
                    "usage_metadata_never_arrived turn=\(pending.turnIndex, privacy: .public) — firing report with zero tokens",
                )
            } else {
                Logger.voice.warning(
                    "usage_metadata_late turn=\(pending.turnIndex, privacy: .public) — usage arrived after \(LiveSessionBudget.pendingReportTimeoutSec, privacy: .public)s budget",
                )
            }
        }

        guard let sessionID = mintResponse?.sessionID,
              let sessionUUID = UUID(uuidString: sessionID)
        else { return }

        // Detect missing per-modality breakdown on ANY component — if
        // Gemini stops emitting promptTokensDetails / responseTokensDetails,
        // our fallback classifies unknowns as audio, which OVER-estimates
        // cost (audio-in $3/M vs text-in $0.75/M = 4×; audio-out $12/M
        // vs text-out $4.50/M = 2.67×). Dashboards drift silently unless
        // we surface this.
        if let usage = usageForReport {
            let promptBreakdownMissing =
                usage.promptAudioTokens == nil && usage.promptTextTokens == nil
            let responseBreakdownMissing =
                usage.responseAudioTokens == nil && usage.responseTextTokens == nil
            if promptBreakdownMissing || responseBreakdownMissing {
                Logger.voice.warning(
                    "usage_metadata_breakdown_missing session=\(sessionID, privacy: .public) turn=\(pending.turnIndex, privacy: .public) prompt_total=\(usage.promptTokenCount, privacy: .public) response_total=\(usage.responseTokenCount, privacy: .public) prompt_missing=\(promptBreakdownMissing, privacy: .public) response_missing=\(responseBreakdownMissing, privacy: .public)",
                )
            }
        }

        let promptText = usageForReport?.promptTextTokens ?? 0
        let promptAudioTotal = usageForReport.map {
            $0.promptAudioTokens ?? max(0, $0.promptTokenCount - ($0.promptTextTokens ?? 0))
        } ?? 0
        let responseText = usageForReport?.responseTextTokens ?? 0
        let responseAudioTotal = usageForReport.map {
            $0.responseAudioTokens ?? max(0, $0.responseTokenCount - ($0.responseTextTokens ?? 0))
        } ?? 0
        // Implicit-cache hit portion — nil when the accumulator was zero
        // (either caching didn't fire, or the field wasn't in the usage
        // frame at all). Forwarded to backend only when positive to keep
        // the wire tight on the common non-cached path. Powers the spec §9
        // cap-reversal trigger ("cachedContentTokenCount ≥ 50% of prompt
        // across 100 sessions").
        let promptCachedTotal = usageForReport?.cachedContentTokenCount

        // Map drain reason to wire-level endedReason so dashboards can
        // distinguish normal turn completions from timeouts, drops, and
        // supersedes. `usageArrived`, `supersededByNextTurn`, and
        // `supersededByRefresh` all represent successful turn boundaries
        // (Gemini completed the turn), so they map to `.turnComplete`.
        // `timeout` and `sessionClosed` map to `.error` — the turn
        // technically completed but we either lost usage data (timeout)
        // or the session tore down mid-stream (sessionClosed).
        let endedReason: VoiceTurnUsageRequest.TurnUsage.EndedReason = {
            switch reason {
            case .usageArrived, .supersededByNextTurn, .supersededByRefresh:
                return .turnComplete
            case .timeout, .sessionClosed:
                return .error
            }
        }()

        // Forward Gemini's raw `promptTokenCount` / `responseTokenCount`
        // totals so the backend can attribute the uncategorized
        // remainder at audio rate (AUDIO-mode overhead — CLAUDE.md
        // sharp-edge #15). `usageForReport` is nil iff the turn
        // completed with no usage frames ever observed; in that case
        // totals are zero and the row is logged with zero tokens.
        let promptTotal = usageForReport?.promptTokenCount ?? 0
        let responseTotal = usageForReport?.responseTokenCount ?? 0

        let turnUsage = VoiceTurnUsageRequest.TurnUsage(
            turnIndex: pending.turnIndex,
            promptTokensText: max(0, promptText),
            promptTokensAudio: max(0, promptAudioTotal),
            promptTokensTotal: max(0, promptTotal),
            promptTokensCached: promptCachedTotal.flatMap { $0 > 0 ? $0 : nil },
            responseTokensText: max(0, responseText),
            responseTokensAudio: max(0, responseAudioTotal),
            responseTokensTotal: max(0, responseTotal),
            latencyMS: pending.latencyMs,
            endedReason: endedReason,
            promptVersion: mintResponse?.promptVersion ?? "",
            path: .liveAPI,
            endedAt: pending.endedAt,
        )
        let payload = VoiceTurnUsageRequest(sessionID: sessionUUID, turns: [turnUsage])

        let dispatch = aiDispatch
        let turnIdx = pending.turnIndex
        Task.detached {
            // P1-H (2026-04-23): surface failures to OSLog so wire-drift
            // (e.g. a release where iOS payload diverges from backend Zod
            // schema) doesn't silently black-hole every turn's cost
            // telemetry. Still fire-and-forget at the flow level (the
            // user turn continues regardless), but the error is
            // observable in Sentry breadcrumbs when it does happen.
            do {
                try await dispatch.voiceTurnUsage(request: payload)
            } catch {
                Logger.voice.warning(
                    "voice_turn_usage_post_failed turn=\(turnIdx, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
                )
            }
        }

        // Notify VM so it can aggregate for the close-summary trace.
        let summary = LiveTurnSummary(
            turnIndex: pending.turnIndex,
            promptTokensText: turnUsage.promptTokensText,
            promptTokensAudio: turnUsage.promptTokensAudio,
            promptTokensTotal: turnUsage.promptTokensTotal,
            responseTokensText: turnUsage.responseTokensText,
            responseTokensAudio: turnUsage.responseTokensAudio,
            responseTokensTotal: turnUsage.responseTokensTotal,
            submittedAt: pending.submittedAt,
            latencyMs: pending.latencyMs,
            latencyTtfaMs: pending.latencyTtfaMs,
            containedToolCall: pending.containedToolCall,
            endedReason: turnUsage.endedReason,
            endedAt: pending.endedAt,
        )
        onTurnFinalized?(summary)
    }

    // MARK: - Private: mint + setup

    /// Shared coercion mirror of `CookModeViewModel.safeInstructionText`.
    /// Keeps buildMintRequest's allSteps + currentStepText Zod-safe
    /// without depending on the VM class.
    private static func safeInstructionText(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "(step instruction unavailable)" : trimmed
    }

    private func buildMintRequest(
        recap: String? = nil,
        isRefresh: Bool = false,
    ) throws -> RealtimeSessionRequest {
        guard let sessionID = cookingSession.id else {
            throw RealtimeSessionError.mintFailed(message: "cooking session has no id")
        }
        guard let recipePlan = cookingSession.recipePlan,
              let recipePlanID = recipePlan.id
        else {
            throw RealtimeSessionError.mintFailed(message: "cooking session has no recipe_plan")
        }
        let steps = recipePlan.stepArray
        let currentIndex = Int(cookingSession.currentStepIndex)
        let currentStep = steps.indices.contains(currentIndex) ? steps[currentIndex] : nil
        let currentStepNumber = currentIndex + 1

        // Empty/whitespace-only instruction text would VAL-01 the mint
        // (Zod `text: z.string().min(1)` and `current_step_text:
        // z.string().min(1)`). Coerce to a placeholder so malformed
        // imports don't silently downgrade users to C.3. Mirrors the
        // VM-side `CookModeViewModel.safeInstructionText`.
        let allSteps = steps.map {
            RealtimeRecipeContext.StepDescription(
                stepNumber: Int($0.stepNumber),
                text: Self.safeInstructionText($0.instructionText),
                // 0 = no timer. Backend schema requires the key present.
                timerSeconds: Int($0.timerSeconds),
            )
        }
        let recipeContext = RealtimeRecipeContext(
            title: recipePlan.title ?? "",
            servings: Int(recipePlan.servings),
            estimatedMinutes: Int(recipePlan.estimatedMinutes),
            totalSteps: steps.count,
            currentStepText: Self.safeInstructionText(currentStep?.instructionText),
            // 0 when no timer on this step (or no current step). DTO
            // is non-Optional because the backend requires the key to
            // be present even when null — explicit 0 is the simplest
            // encoding that always satisfies the schema.
            currentStepTimerSeconds: Int(currentStep?.timerSeconds ?? 0),
            allSteps: allSteps,
            remainingIngredients: recipePlan.ingredientArray.map { ing in
                .init(displayName: ing.displayName ?? "", canonicalSlug: ing.canonicalIngredientSlug)
            },
        )
        let householdContext = buildHouseholdContext()

        return RealtimeSessionRequest(
            clientRequestID: UUID(),
            cookingSessionID: sessionID,
            recipePlanID: recipePlanID,
            currentStepNumber: max(1, currentStepNumber),
            recipeContext: recipeContext,
            householdContext: householdContext,
            recap: recap,
            isRefresh: isRefresh,
        )
    }

    private func buildHouseholdContext() -> RealtimeHouseholdContext {
        // P2-I (2026-04-23): routed through
        // `HouseholdProfile.voiceContextSnapshot()` shared seam so the
        // mint + VM + substitution paths all project with identical
        // filters. Prior three call-site drift fixed there.
        //
        // P3-H (2026-04-23): TTL-cache the snapshot so refresh mints
        // don't re-walk the full pantry set (up to 1000 items for Pro)
        // on every refresh. 60 s TTL balances cost-of-recompute
        // against cost-of-stale (a user deleting a pantry item via
        // another app mid-session waits up to 60 s before the new
        // session-refresh picks it up — acceptable since the stale
        // view still matches what iOS's own Cook Mode UI shows).
        let now = Date()
        if let cached = cachedHouseholdContext,
           let cachedAt = cachedHouseholdContextAt,
           now.timeIntervalSince(cachedAt) < Self.householdContextTTLSec {
            return cached
        }
        let ctx: RealtimeHouseholdContext
        if let household = cookingSession.household {
            ctx = RealtimeHouseholdContext(snapshot: household.voiceContextSnapshot())
        } else {
            ctx = RealtimeHouseholdContext(snapshot: .empty)
        }
        cachedHouseholdContext = ctx
        cachedHouseholdContextAt = now
        return ctx
    }

    /// P3-H (2026-04-23): TTL-cached household snapshot. Invalidated
    /// naturally after 60 s; preWarm + close both clear it via
    /// `clearHouseholdContextCache()` as a belt-and-suspenders reset.
    private var cachedHouseholdContext: RealtimeHouseholdContext?
    private var cachedHouseholdContextAt: Date?
    private static let householdContextTTLSec: TimeInterval = 60

    private func clearHouseholdContextCache() {
        cachedHouseholdContext = nil
        cachedHouseholdContextAt = nil
    }

    // MARK: - Private: inbound dispatch

    private func startReceiveDispatcher() {
        guard let transport else { return }
        dispatcherGeneration += 1
        let myGen = dispatcherGeneration
        receiveDispatcherTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await frame in transport.inbound {
                    await self.handleInboundFrame(frame)
                }
            } catch {
                // Generation check: if another dispatcher has since been
                // started (via refreshSession or close+restart), this
                // task is stale and its error is noise from an intentional
                // teardown. Log at info and return. Race-free because both
                // reads happen on the @MainActor.
                let current = await self.dispatcherGeneration
                if myGen != current {
                    Logger.voice.info(
                        "live_receive_dispatcher_stale_suppressed gen=\(myGen, privacy: .public) current=\(current, privacy: .public)",
                    )
                    #if DEBUG
                    VoiceSessionLog.log("receive.stale_suppressed", [
                        "gen": myGen,
                        "current": current,
                    ])
                    #endif
                    return
                }
                Logger.voice.warning(
                    "live_receive_dispatcher_failed error=\(error.localizedDescription, privacy: .private)",
                )
                await self.handleTransportError(error)
            }
        }
    }

    private var setupCompleteContinuation: CheckedContinuation<Void, Error>?

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
    private var turnCompleteGeneration: Int = 0
    private var setupCompleteGeneration: Int = 0

    /// Await the server's `setupComplete` handshake frame. Returns when
    /// `handleInboundFrame` resumes the continuation; throws
    /// `RealtimeSessionError.setupTimeout` if the budget elapses first.
    ///
    /// Implementation note: earlier drafts used a TaskGroup with one
    /// task blocking on the continuation and another on a timer.
    /// `TaskGroup.cancelAll()` does NOT propagate into a
    /// `withCheckedThrowingContinuation` — the continuation never
    /// resumed and leaked. This version resolves the continuation
    /// explicitly from the timeout path, so neither side leaks.
    private func awaitSetupComplete(timeoutSec: Double) async throws {
        setupCompleteGeneration += 1
        let gen = setupCompleteGeneration
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setupCompleteContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSec))
                guard let self,
                      self.setupCompleteGeneration == gen,
                      let pending = self.setupCompleteContinuation
                else { return }
                self.setupCompleteContinuation = nil
                pending.resume(throwing: RealtimeSessionError.setupTimeout)
            }
        }
    }

    /// Await the server's `turnComplete` frame. Mirrors `awaitSetupComplete`'s
    /// timeout pattern so a stalled server (no close, no `turnComplete`)
    /// can't hang the mic forever. Budget comes from `LiveSessionBudget`
    /// so it's tunable alongside the other Live-path budgets after D.1.
    /// On timeout, the caller's `endTurn` throws `.turnDrained`, the VM
    /// surfaces a toast, and state is recoverable by tapping again.
    private func awaitTurnComplete(
        timeoutSec: Double = LiveSessionBudget.turnCompleteSec,
    ) async throws {
        turnCompleteGeneration += 1
        let gen = turnCompleteGeneration
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.turnCompleteContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSec))
                // Only fire if the continuation we OWN is still pending.
                // A newer turn would have bumped the generation; in that
                // case the old timeout silently no-ops so we don't poison
                // the live turn.
                guard let self,
                      self.turnCompleteGeneration == gen,
                      let pending = self.turnCompleteContinuation
                else { return }
                self.turnCompleteContinuation = nil
                pending.resume(throwing: RealtimeSessionError.turnDrained)
            }
        }
    }

    private func handleInboundFrame(_ frame: LiveInboundFrame) async {
        // P1-I (2026-04-23): short-circuit on a torn-down session. If a
        // frame is mid-delivery when close() races in, the handler
        // could advance the state machine (.modelSpeaking, .ready, etc.)
        // on a session the VM has already disposed — producing Sentry
        // noise and, in tests, flakiness. The state machine's
        // `forceClose()` at close() sets state to .closed; once terminal,
        // no further advances should fire. Generation-token suppression
        // at the dispatcher level (line 2093-2126) handles the common
        // case, but a frame already in the switch when cancel lands
        // slips past it — this guard closes that window.
        if stateMachine.state == .closed {
            return
        }
        switch frame {
        case .setupComplete:
            // Nil-clear BEFORE resume so a re-entrant resume (shouldn't
            // happen, but defense-in-depth against Google sending two
            // setupComplete frames) doesn't double-resume.
            if let cont = setupCompleteContinuation {
                setupCompleteContinuation = nil
                cont.resume()
            }

        case let .serverContent(content):
            await handleServerContent(content)

        case let .toolCall(toolCall):
            await handleToolCall(toolCall)

        case let .usageMetadata(usage):
            // Gemini Live streams usage as per-chunk deltas (prompt count
            // on first frame, response deltas on every audio chunk, empty
            // envelope on turnComplete). Accumulate rather than overwrite
            // so the empty turnComplete envelope doesn't zero out all the
            // real token counts — the bug that caused every $ai_generation
            // to report 0 tokens in prod 2026-04-22 before this fix.
            turnUsageAccumulator.accumulate(usage)
            #if DEBUG
            VoiceSessionLog.log("usage.metadata", [
                "frame_prompt_tokens": usage.promptTokenCount,
                "frame_response_tokens": usage.responseTokenCount,
                // String-encoded to preserve "field absent in frame" vs
                // "field present but zero" — both can occur and they
                // mean different things for the caching-status diagnostic
                // (`accum_cached_tokens` below is the authoritative
                // "is any caching firing this turn" signal).
                "frame_cached_tokens": usage.cachedContentTokenCount.map { "\($0)" } ?? "nil",
                "accum_prompt_tokens": turnUsageAccumulator.sumPromptTokens,
                "accum_response_tokens": turnUsageAccumulator.sumResponseTokens,
                "accum_cached_tokens": turnUsageAccumulator.sumCachedContentTokens,
                "has_pending_report": pendingReport != nil,
            ])
            #endif
            // Early-fire any turn report that was waiting on this
            // metadata. Common path when Gemini sends usageMetadata in
            // a trailing envelope AFTER `serverContent{turnComplete}`.
            if pendingReport != nil {
                flushPendingReport(dueTo: .usageArrived)
            }

        case let .goAway(ms):
            Logger.voice.info(
                "live_session_go_away time_before_disconnect_ms=\(ms ?? -1, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("server.go_away", ["time_before_disconnect_ms": ms ?? -1])
            #endif
            // Server-initiated refresh (goAway = server about to drop
            // this session within `ms`). Fire telemetry then run the
            // refresh handshake. `isRefreshing` guard inside
            // `refreshSession()` keeps a concurrent threshold-triggered
            // refresh from racing. ADR 0014.
            if !isRefreshing {
                await refreshSession(reason: "goaway")
            }

        case .sessionResumption:
            #if DEBUG
            VoiceSessionLog.log("server.session_resumption_update")
            #endif
        case let .unknown(key):
            #if DEBUG
            VoiceSessionLog.log("server.unknown_frame", ["key": key])
            #endif
        }
    }

    private func handleServerContent(_ content: LiveServerContent) async {
        if !content.audioChunks.isEmpty {
            // Record timestamp BEFORE state transitions / playback.
            // Mic-forwarder reads this for the echo cooldown gate.
            let now = Date()
            lastInboundAudioAt = now
            // TTFA capture: stamp "user finished speaking" the moment the
            // server's transcription flips `finished=true`. Only stamp
            // once per turn — partial-transcription frames with
            // `finished=false` shouldn't move the anchor backwards.
            if firstModelAudioAt == nil {
                firstModelAudioAt = now
            }
            #if DEBUG
            VoiceSessionLog.log("audio.chunk", [
                "count": content.audioChunks.count,
                "state": stateMachine.state.rawValue,
            ])
            #endif
            // Hands-free: audio chunks can arrive from ANY non-terminal
            // state because the mic is always hot and VAD drives turn
            // transitions server-side without iOS prior notice.
            //
            //   .userSpeaking  → .modelSpeaking  (user paused, server
            //                                     VAD fired, response
            //                                     arrived — no tap)
            //   .thinking      → .modelSpeaking  (original tap-to-end
            //                                     path — VM advanced
            //                                     to thinking before)
            //   .toolCalling   → .modelSpeaking  (CLAUDE.md #9 — model
            //                                     auto-continues after
            //                                     toolResponse)
            //   .ready         → .modelSpeaking  (next-turn response
            //                                     arrived while iOS
            //                                     was between turns)
            //
            // Already-.modelSpeaking is a no-op (the guard avoids a
            // redundant .modelSpeaking → .modelSpeaking transition
            // which canTransition disallows).
            switch stateMachine.state {
            case .userSpeaking, .thinking, .toolCalling, .ready:
                stateMachine.advance(to: .modelSpeaking)
            default:
                break
            }
            // Rearm the watchdog on every audio chunk. The onTransition
            // hook arms it on entry to .modelSpeaking, but subsequent
            // chunks in the same modelSpeaking window need the timer
            // reset so a turn that spans e.g. 15s of audio doesn't
            // self-trigger halfway through.
            rearmTurnStuckWatchdog()
            // Break on first failure — if `enqueuePlayback` throws,
            // the audio engine is stopped and every subsequent chunk
            // in this frame will fail the same way. One log per failed
            // turn is sufficient for triage; absent the break, a
            // failed turn would log ~50 warnings.
            for chunk in content.audioChunks {
                do {
                    try audioPipeline?.enqueuePlayback(chunk)
                } catch {
                    Logger.voice.warning(
                        "live_playback_enqueue_failed error=\(error.localizedDescription, privacy: .private)",
                    )
                    break
                }
            }
        }
        if let text = content.inlineText, !text.isEmpty {
            currentTurnInlineText = (currentTurnInlineText ?? "") + text
        }
        // Diagnostic + long-term transcript source. When
        // `inputAudioTranscription` is in the mint setup, the server
        // returns per-delta transcripts of what it heard from the
        // user. Zero-transcription output over several seconds of
        // apparent speech = audio pipeline problem, not a VAD problem.
        if let input = content.inputTranscription, !input.text.isEmpty {
            #if DEBUG
            VoiceSessionLog.log("transcription.user", [
                "text": input.text,
                "finished": input.finished,
            ])
            #endif
            // TTFA capture: stamp the user-end anchor on every
            // transcription frame that arrives BEFORE first model
            // audio. The latest pre-audio transcription frame is the
            // closest proxy to "server's VAD finalized the user's turn"
            // — once audio starts, later transcription frames are
            // irrelevant and must not move the anchor forward (that
            // would underestimate TTFA).
            //
            // Gemini Live with `automaticActivityDetection` doesn't
            // reliably emit `inputTranscription.finished=true` in
            // Stir's mint configuration (observed 2026-04-22:
            // cook_turn_resolved events showed ttfa_ms=0 across 30+
            // real-world turns because every transcription frame
            // arrived with `finished=false`, never tripping the prior
            // `if input.finished` guard). Stamping on every pre-audio
            // frame is the robust fallback — `finished=true` frames
            // still work identically since they're pre-audio in the
            // normal turn ordering.
            if firstModelAudioAt == nil {
                userTurnEndAt = Date()
            }
            // User-transcript ring buffer REMOVED 2026-04-22 PM — recap
            // is step-position-only. input.text is still logged above for
            // diagnostic trace purposes (VoiceSessionLog `transcription.user`).
        }
        if let output = content.outputTranscription, !output.text.isEmpty {
            // Accumulate model transcript into currentTurnInlineText
            // so VoiceTurn persistence gets a real string instead of
            // empty. Don't double-count inlineText (rare on AUDIO) +
            // outputTranscription on the same turn — prefer the
            // latter since it matches what was actually spoken.
            currentTurnInlineText = (currentTurnInlineText ?? "") + output.text
            #if DEBUG
            VoiceSessionLog.log("transcription.model", [
                "text": output.text,
                "finished": output.finished,
            ])
            #endif
        }
        if content.turnComplete {
            // Advance all the way to `.ready` so the hands-free loop
            // is self-sustaining — the next user utterance lands on a
            // legal `.ready → .modelSpeaking` edge without any VM
            // intervention.
            //
            // Transitions handled here:
            //   .thinking      → .modelSpeaking → (bare completion;
            //                    audio never arrived — no continuation
            //                    to .ready yet, so step through)
            //   .modelSpeaking → .ready         (natural end after
            //                    audio chunks played)
            //   .userSpeaking  → .ready         (VAD fired with no
            //                    server-audio response, e.g. the
            //                    model declined to speak)
            //   .toolCalling   → .modelSpeaking → .ready (guard
            //                    against stuck tool states)
            switch stateMachine.state {
            case .thinking, .toolCalling:
                stateMachine.advance(to: .modelSpeaking)
                stateMachine.advance(to: .ready)
            case .modelSpeaking, .userSpeaking:
                stateMachine.advance(to: .ready)
            default:
                break
            }
            // Finalize BEFORE resuming the continuation so `endTurn()`
            // reads a populated `lastTurnResult` when it wakes up.
            // finalizeTurn handles persistence, turnCount increment,
            // per-turn accumulator reset, and the refresh trigger.
            finalizeTurn()

            // The playback may still be queued — we resume the
            // continuation immediately so any waiting caller (VM
            // tap-to-end path) can react; audio continues playing in
            // the background. The VM calls cancelSpeaking / next tap
            // to interrupt if needed.
            //
            // Nil-clear before resume so a re-entrant turnComplete
            // (e.g., server emits one on audio end and another on
            // toolCall completion) doesn't double-resume.
            if let cont = turnCompleteContinuation {
                turnCompleteContinuation = nil
                cont.resume()
            }
        }
    }

    private func handleToolCall(_ toolCall: LiveToolCall) async {
        // Hands-free: tool calls can arrive from any live turn state —
        // VAD drives transitions server-side and the server can decide
        // to invoke `advance_step` / `start_timer` / `substitution_check`
        // at any point in the turn cycle. Reject only from terminal
        // / pre-session states where we genuinely can't respond.
        //
        // Observed 2026-04-22: model called `advance_step` while state
        // was `.userSpeaking` (VAD had heard "move on to step three"
        // but iOS hadn't advanced state yet). Old `.thinking`-only
        // guard dropped the call, server sent toolCallCancellation,
        // screen never advanced. Fix: allow .userSpeaking, .ready,
        // .modelSpeaking, .thinking, .toolCalling (re-entrant) as
        // valid source states.
        let liveStates: Set<VoiceSessionState> = [
            .userSpeaking, .ready, .modelSpeaking, .thinking, .toolCalling,
        ]
        guard liveStates.contains(stateMachine.state) else {
            Logger.voice.warning(
                "live_tool_call_in_unexpected_state state=\(self.stateMachine.state.rawValue, privacy: .public)",
            )
            #if DEBUG
            VoiceSessionLog.log("tool_call.dropped_bad_state", [
                "state": stateMachine.state.rawValue,
                "calls": toolCall.functionCalls.map(\.name).joined(separator: ","),
            ])
            #endif
            if let cont = turnCompleteContinuation {
                turnCompleteContinuation = nil
                cont.resume(throwing: RealtimeSessionError.turnDrained)
            }
            return
        }
        // Self-transitions are idempotent no-ops at the machine layer
        // (see VoiceSessionStateMachine.advance), so this call is safe
        // whether we're already in `.toolCalling` (re-entrant tool
        // frame) or transitioning from `.userSpeaking` / `.ready` /
        // `.modelSpeaking` / `.thinking`.
        stateMachine.advance(to: .toolCalling)
        // Mark the current turn as tool-involving so finalizeTurn() can
        // latch it into PendingTurnReport.containedToolCall and the VM
        // tags cook_turn_resolved.result_type accordingly (ADR 0012).
        turnContainedToolCall = true
        // Capture the most-recent tool name for the stuck-watchdog
        // PostHog payload. 3.1 Flash Live is synchronous one-in-flight
        // (CLAUDE.md §sharp-edge #12), so this is the only tool call
        // for this turn in practice. Pre-dispatch so the name is
        // available even if dispatchTool throws.
        lastToolCallName = toolCall.functionCalls.first?.name
        #if DEBUG
        VoiceSessionLog.log("tool_call.received", [
            "calls": toolCall.functionCalls.map(\.name).joined(separator: ","),
        ])
        #endif

        // 3.1 Flash Live does synchronous tool calls — one in flight
        // at a time (CLAUDE.md §sharp-edge #12). So iterating the
        // (length-1) array in order is the right contract.
        for call in toolCall.functionCalls {
            let response = await dispatchTool(call)
            let frame = LiveOutboundFrame.toolResponse(
                functionResponseId: call.id,
                name: call.name,
                response: response,
            )
            do {
                try await transport?.send(frame)
                #if DEBUG
                VoiceSessionLog.log("tool_response.sent", ["name": call.name])
                #endif
            } catch {
                Logger.voice.warning(
                    "live_tool_response_send_failed name=\(call.name, privacy: .public) error=\(error.localizedDescription, privacy: .private)",
                )
                #if DEBUG
                VoiceSessionLog.logError("tool_response.send_failed", error: error, ["name": call.name])
                #endif
            }
        }

        // After toolResponse, state STAYS in `.toolCalling` until the
        // next serverContent audio frame arrives — the state machine's
        // legal transitions forbid `.toolCalling → .thinking` (only
        // `.toolCalling → .modelSpeaking` is allowed). When Gemini
        // resumes its spoken response (sharp-edge #9: auto-continue
        // after toolResponse), `handleServerContent` advances
        // `.toolCalling → .modelSpeaking` on the first audio chunk.
        // Removing a prior premature `.toolCalling → .thinking` hop
        // that would have hit an assertionFailure in debug builds.
    }

    private func dispatchTool(_ call: LiveFunctionCall) async -> [String: Any] {
        switch call.name {
        case "substitution_check":
            return await dispatchSubstitution(call)
        case "start_timer":
            guard let secs = call.timerSeconds else {
                return ["ok": false, "error": "missing_seconds"]
            }
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onStartTimerRequested {
                // Await the start so the resulting snapshot reflects
                // the real on-screen CookTimer (NOT an LLM-guessed
                // state). The VM writes the CookTimer to Core Data
                // and schedules the UNNotificationRequest inside
                // `startTimerFromVoice`, so this await is the actual
                // "timer is live" fence.
                snapshot = await cb(secs, call.timerLabel)
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state == .running || snapshot.state == .pending
            if !((response["ok"] as? Bool) ?? false) {
                response["error"] = "timer_not_started"
            }
            return response
        case "get_timer_status":
            let snapshot = onTimerQueryRequested?() ?? makeNoneTimerSnapshot()
            var response = snapshotToDict(snapshot)
            response["ok"] = true
            return response
        case "pause_timer":
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerPauseRequested {
                snapshot = await cb()
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state == .paused
            if snapshot.state != .paused {
                response["error"] = "no_running_timer"
            }
            return response
        case "resume_timer":
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerResumeRequested {
                snapshot = await cb()
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state == .running
            if snapshot.state != .running {
                response["error"] = "no_paused_timer"
            }
            return response
        case "cancel_timer":
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerCancelRequested {
                snapshot = await cb()
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            response["ok"] = snapshot.state != .running && snapshot.state != .paused
            return response
        case "restart_timer":
            // Atomic cancel-then-start. `timerSeconds` may be nil — VM
            // reuses the existing timer's total duration in that case.
            // If no existing timer AND no seconds, VM returns a
            // .none/.cancelled snapshot and we map it to no_existing_timer.
            let snapshot: CookModeViewModel.VoiceTimerSnapshot
            if let cb = onTimerRestartRequested {
                snapshot = await cb(call.timerSeconds, call.timerLabel)
            } else {
                snapshot = makeNoneTimerSnapshot()
            }
            var response = snapshotToDict(snapshot)
            // P0-C (2026-04-23): check the VM's explicit restart bookkeeping
            // BEFORE relying on timer-active state. The prior check (just
            // `.running || .pending`) returned ok=true on a partial-cancel
            // failure because the STALE original timer was still running —
            // narrating "I restarted the timer" while the original alarm's
            // fire date stood. Device-reproduced 2026-04-23.
            //
            // `restartSucceeded == false` means the VM's cancel-before-start
            // loop couldn't drain the step-scoped active timers and
            // bailed rather than create a duplicate. `nil` defaults to
            // "no explicit signal, fall back to state check" for defensive
            // compatibility with callbacks that don't set the field.
            let restartSucceeded = snapshot.restartSucceeded ?? true
            let timerActive = snapshot.state == .running || snapshot.state == .pending
            let ok = restartSucceeded && timerActive
            response["ok"] = ok
            if !ok {
                if !restartSucceeded {
                    // Cancel loop failed — model should prompt user to
                    // explicitly cancel then start a fresh timer rather
                    // than retrying the restart blindly.
                    response["error"] = "cancel_failed"
                } else {
                    // No timer to restart + no seconds given → advise the
                    // model to suggest start_timer instead.
                    response["error"] = "no_existing_timer"
                }
            }
            return response
        case "set_step":
            // Generalized step navigation — forward OR backward. Accepts
            // a 1-indexed target step. VM clamps into range.
            #if DEBUG
            // Log the raw arg so we can see what the model actually
            // sent — `targetStepNumber` clamps <=0 to 1 and >=101 to
            // 100, so a user report of "step 1 doesn't work" would
            // otherwise hide the model's 0-indexed confusion.
            VoiceSessionLog.log("tool_args.set_step", [
                "step_number_raw": String(describing: call.args["step_number"] ?? "nil"),
                "target": call.targetStepNumber ?? -1,
            ])
            #endif
            guard let target1 = call.targetStepNumber else {
                return ["ok": false, "error": "invalid_step_number"]
            }
            onGoToStepRequested?(target1)
            return makeStepResponse()
        case "advance_step":
            // Legacy tool name (pre-v1.3.0 prompts). Kept as an alias
            // so in-flight sessions minted on v1.2.0 still work during
            // the rollout window. Always +1.
            onAdvanceStepRequested?()
            return makeStepResponse()
        default:
            Logger.voice.warning("live_unknown_tool name=\(call.name, privacy: .public)")
            return ["ok": false, "error": "unknown_tool"]
        }
    }

    /// Flatten a VoiceTimerSnapshot into the tool-response dict the
    /// model expects. Fields omitted when nil/zero so the dict stays
    /// compact.
    private func snapshotToDict(_ s: CookModeViewModel.VoiceTimerSnapshot) -> [String: Any] {
        var dict: [String: Any] = [
            "state": s.state.rawValue,
            "remaining_seconds": s.remainingSeconds,
        ]
        if s.totalSeconds > 0 {
            dict["total_seconds"] = s.totalSeconds
        }
        if let label = s.label, !label.isEmpty {
            dict["label"] = label
        }
        if let step = s.stepNumber {
            dict["step_number"] = step
        }
        return dict
    }

    /// Fallback used when a timer callback is unset. Indicates "no
    /// timer attached at all" rather than "timer exists but is idle".
    private func makeNoneTimerSnapshot() -> CookModeViewModel.VoiceTimerSnapshot {
        CookModeViewModel.VoiceTimerSnapshot(
            state: .none, remainingSeconds: 0, totalSeconds: 0, label: nil, stepNumber: nil,
        )
    }

    /// Build the standard tool-response dict describing the user's
    /// CURRENT step post-navigation. Shared by `set_step` and the
    /// legacy `advance_step` path so the model gets the same grounding
    /// either way. Returns `ok: true` always — the navigation itself
    /// is clamped to bounds by the VM, so even past-end requests
    /// produce a valid dict (`is_last_step: true`).
    ///
    /// The VM's handler is synchronous (MainActor + Core Data save),
    /// so `cookingSession.currentStepIndex` reflects the post-nav value
    /// by the time we read it here.
    private func makeStepResponse() -> [String: Any] {
        let newIdx = Int(cookingSession.currentStepIndex)
        let steps = cookingSession.recipePlan?.stepArray ?? []
        if steps.indices.contains(newIdx) {
            let newStep = steps[newIdx]
            return [
                "ok": true,
                "new_step_number": newIdx + 1,
                "new_step_text": Self.safeInstructionText(newStep.instructionText),
                "total_steps": steps.count,
                "is_last_step": newIdx == steps.count - 1,
            ]
        }
        return [
            "ok": true,
            "new_step_number": steps.count,
            "new_step_text": "(no further steps)",
            "total_steps": steps.count,
            "is_last_step": true,
        ]
    }

    private func dispatchSubstitution(_ call: LiveFunctionCall) async -> [String: Any] {
        // Route through AIDispatch.substitution. Backend enforces the
        // hard-rule validator identically to the sheet path (single
        // source of truth per CLAUDE.md §north-star constraint #5).
        //
        // Build full recipe + household context from the live cooking
        // session so the validator has everything it needs — same
        // shape the sheet sends. live_session_id correlation is wired
        // via `cookingSessionID` (paired with the mint's session_id
        // on the backend via ai_request_log metadata).

        // Generate the sub_event_id up-front so BOTH the requested fire
        // (below) AND the paired resolved fire (in the
        // .safe / .unsafe cases) carry the same ID, letting the
        // funnel join them without timestamp heuristics.
        let subEventID = UUID()
        let subEventIDString = subEventID.uuidString

        // C.5: fire the spec §15 `substitution_requested` event with
        // `invocation: "realtime_function_call"` so the rescue-usage
        // dashboard can distinguish voice-driven substitutions from
        // sheet-driven ones. Fires BEFORE the guard clauses below —
        // the model-intent-to-substitute signal is what matters for
        // funnel analysis, not whether the args parsed cleanly.
        onSubstitutionRequestedFromVoice?(subEventIDString)

        guard let missingIngredient = call.substitutionMissingIngredient,
              !missingIngredient.isEmpty
        else {
            #if DEBUG
            VoiceSessionLog.log("substitution.missing_args", ["tool": call.name])
            #endif
            return [
                "ok": false,
                "error": "missing_ingredient_required",
                "message": "Tell the user you need to know which ingredient is missing.",
            ]
        }
        let userProblem = call.substitutionUserProblem ?? "Out of \(missingIngredient)"

        guard let sessionID = cookingSession.id,
              let recipePlan = cookingSession.recipePlan,
              let recipePlanID = recipePlan.id
        else {
            Logger.voice.warning("live_substitution_missing_ids")
            return [
                "ok": false,
                "error": "session_state_invalid",
                "message": "Tell the user to use the Substitution Sheet.",
            ]
        }

        let steps = recipePlan.stepArray
        let currentIdx = Int(cookingSession.currentStepIndex)
        let remaining = recipePlan.ingredientArray.map { ing in
            SubstitutionRequest.RecipeContext.RemainingIngredient(
                displayName: ing.displayName ?? "",
                canonicalSlug: ing.canonicalIngredientSlug,
            )
        }
        let recipeContext = SubstitutionRequest.RecipeContext(
            title: recipePlan.title ?? "",
            currentStepNumber: max(1, currentIdx + 1),
            totalSteps: max(1, steps.count),
            remainingIngredients: remaining,
        )

        // Household context: pantry + dietary rules + equipment.
        // P2-I (2026-04-23): routed through the shared
        // `HouseholdProfile.voiceContextSnapshot()` seam. Prior inline
        // projection here accepted any pantry item with a non-empty
        // displayName — diverging from the mint + VM paths, which
        // required `userConfirmed && deletedAt == nil`. Unconfirmed
        // items could leak into the substitution validator. Canonical
        // filter now applies uniformly.
        let householdContext = SubstitutionRequest.HouseholdContext(
            snapshot: cookingSession.household?.voiceContextSnapshot() ?? .empty,
        )

        let request = SubstitutionRequest(
            subEventID: subEventID,
            cookingSessionID: sessionID,
            recipePlanID: recipePlanID,
            missingIngredient: SubstitutionRequest.MissingIngredient(
                displayName: missingIngredient,
                canonicalSlug: nil,
                amountText: nil,
            ),
            userProblem: userProblem,
            householdContext: householdContext,
            recipeContext: recipeContext,
        )

        #if DEBUG
        VoiceSessionLog.log("substitution.dispatch", [
            "missing": missingIngredient,
            "step": max(1, currentIdx + 1),
            "sub_event_id": subEventIDString,
        ])
        #endif

        do {
            let result = try await aiDispatch.substitution(request: request)
            switch result {
            case let .safe(_, text, amountConversion, reasoning, confidence, _):
                #if DEBUG
                VoiceSessionLog.log("substitution.safe", [
                    "confidence": confidence.rawValue,
                ])
                #endif
                // Voice has no user confirm step — a safe substitution
                // is auto-applied as the model speaks it. Fire
                // `substitution_accepted` so the voice rescue funnel
                // stays symmetric with the sheet path.
                onSubstitutionResolvedFromVoice?(true, subEventIDString)
                // Persist + mutate the recipe so the swap is visible to
                // every downstream consumer (substitution picker, the
                // next voice turn's remainingIngredients, grocery
                // export). Without this, "auto-applied" is a narration-
                // only claim that diverges from the persisted recipe.
                onSubstitutionAppliedFromVoice?(
                    subEventID, missingIngredient, text, amountConversion,
                )
                var response: [String: Any] = [
                    "ok": true,
                    "safe_to_use": true,
                    "substitution": text,
                    "reasoning": reasoning,
                    "confidence": confidence.rawValue,
                ]
                if let conv = amountConversion, !conv.isEmpty {
                    response["amount_conversion"] = conv
                }
                return response
            case let .unsafe(_, reason, message, _):
                #if DEBUG
                VoiceSessionLog.log("substitution.unsafe", ["reason": reason])
                #endif
                // Unsafe on voice = system refused to apply. Emit a
                // paired accepted=false so the funnel shows refusal
                // rate rather than silently dropping the pair.
                onSubstitutionResolvedFromVoice?(false, subEventIDString)
                return [
                    "ok": true,
                    "safe_to_use": false,
                    "reason": reason,
                    "message": message,
                ]
            }
        } catch {
            Logger.voice.warning(
                "live_substitution_failed error=\(error.localizedDescription, privacy: .private)",
            )
            #if DEBUG
            VoiceSessionLog.logError("substitution.upstream_failed", error: error)
            #endif
            return [
                "ok": false,
                "error": "upstream_failed",
                "message": "Tell the user substitution check failed and to tap the Substitution Sheet.",
            ]
        }
    }

    private func handleTransportError(_ error: any Error) async {
        // Stale-dispatcher suppression has moved into the receive
        // dispatcher's catch block (generation-token check in
        // `startReceiveDispatcher`). Any error reaching THIS method is
        // guaranteed to come from the currently-live dispatcher, which
        // means it's a real transport failure worth handling.
        #if DEBUG
        VoiceSessionLog.logError("transport.error", error: error, [
            "state": stateMachine.state.rawValue,
        ])
        #endif
        // P0-A / P0-H (2026-04-23): refresh outcome dictates recovery.
        //   .success          → new transport is live; the old transport
        //                       errored but we recovered. Settle state
        //                       back to .ready if we were mid-turn
        //                       (the turn's user audio may or may not
        //                       have reached Gemini — unknowable — but
        //                       staying pinned in .modelSpeaking with no
        //                       active response would freeze the UX).
        //   .preCommitFailure → refresh never swapped. Old transport is
        //                       the one that errored, so it's dead. We
        //                       have no working WS. Advance to .error
        //                       + record the lost turn.
        //   .postCommitFailure→ refresh swapped then handshake failed;
        //                       refreshSession already advanced state
        //                       to .error and closed the old transport.
        //                       Record the lost turn.
        //   .skipped          → guard short-circuited (refresh already
        //                       in flight, or state already terminal).
        //                       Treat like preCommitFailure from the
        //                       caller's perspective.
        let hadActiveTurn = (turnStartedAt != nil)
        let outcome = await refreshSession(reason: "transport_error")
        switch outcome {
        case .success:
            if hadActiveTurn {
                // Clear per-turn state; the turn is lost either way.
                // No VoiceTurn row persisted — if Gemini actually
                // processed the user utterance before the drop, we'd
                // be double-counting by persisting here. The next
                // user-visible tap / utterance will start a fresh turn.
                currentTurnInlineText = nil
                turnStartedAt = nil
                userTurnEndAt = nil
                firstModelAudioAt = nil
                turnContainedToolCall = false
                lastToolCallName = nil
            }
            // Refresh landed; settle the machine into a tap-ready state
            // so the UX doesn't hang on the prior "Thinking…" indicator.
            if stateMachine.state != .ready && stateMachine.state != .closed && stateMachine.state != .error {
                stateMachine.advance(to: .ready)
            }
        case .postCommitFailure:
            // State already .error and old transport closed inside
            // refreshSession. Record the lost turn for ADR 0015 trigger
            // visibility.
            if hadActiveTurn {
                recordTurnAsTransportError()
            }
        case .preCommitFailure, .skipped:
            // Old transport is the one that errored. Session is dead.
            if stateMachine.state != .closed && stateMachine.state != .error {
                stateMachine.advance(to: .error)
            }
            if hadActiveTurn {
                recordTurnAsTransportError()
            }
        }
        // Nil-clear each continuation BEFORE resume so a concurrent
        // happy-path resolve (e.g., a setupComplete / turnComplete
        // frame racing the transport error) doesn't double-resume the
        // same CheckedContinuation — that's a crash.
        if let cont = turnCompleteContinuation {
            turnCompleteContinuation = nil
            cont.resume(throwing: error)
        }
        if let cont = setupCompleteContinuation {
            setupCompleteContinuation = nil
            cont.resume(throwing: error)
        }
    }

    /// Register the AudioInterruptionObserver so AVAudioSession
    /// interruption / route-change / media-services-reset events are
    /// routed to `handleAudioInterruption(_:)`. Idempotent — if an
    /// observer already exists (shouldn't happen given preWarm semantics,
    /// but defensive), we stop the prior one first.
    private func startAudioInterruptionObserver() {
        audioInterruptionObserver?.stop()
        audioInterruptionObserver = AudioInterruptionObserver { [weak self] event in
            self?.handleAudioInterruption(event)
        }
        audioInterruptionObserver?.start()

        // P0-F (2026-04-23): foreground-mic-permission re-check. Users
        // can revoke mic access in Settings while Cook Mode is
        // backgrounded; on return the AVAudioEngine continues reporting
        // zero-peak buffers forever with no error. On foreground,
        // re-query `AVAudioApplication.shared.recordPermission` and
        // force-close if denied.
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main,
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkMicPermissionOnForeground()
                }
            }
        }
    }

    private func checkMicPermissionOnForeground() {
        let status = AVAudioApplication.shared.recordPermission
        guard status == .denied else { return }
        Logger.voice.warning(
            "voice_live_mic_permission_revoked — closing session on foreground; user must re-grant in Settings",
        )
        #if DEBUG
        VoiceSessionLog.log("mic_permission_revoked_on_foreground")
        #endif
        // Treat as interruption-class event: tear down + surface .error
        // so VM routes to C.3 (which will itself check permission and
        // also hard-fail, but that's the existing VM path).
        handleAudioInterruption(.mediaServicesReset)
    }

    /// React to system audio events. Scope is deliberately narrow: we
    /// tear down the Live path cleanly and let the VM's existing
    /// fallback-to-C.3 flow (via `.error` state) handle the user-facing
    /// recovery. Attempting an in-place refresh on `.interruptionEnded`
    /// is risky — the OS may be mid-interruption on the AVAudioSession
    /// even after announcing end, and forcing Gemini Live audio through
    /// a half-valid session produces worse UX than a clean "tap again
    /// to re-start voice" cue.
    private func handleAudioInterruption(_ event: AudioInterruptionObserver.Event) {
        Logger.voice.info(
            "voice_live_audio_interruption event=\(String(describing: event), privacy: .public)",
        )
        #if DEBUG
        VoiceSessionLog.log("audio_interruption", [
            "event": String(describing: event),
            "state": stateMachine.state.rawValue,
        ])
        #endif
        switch event {
        case .interruptionBegan, .routeOldDeviceUnavailable, .mediaServicesReset:
            // Treat all three as "the session is unrecoverable, tear
            // down and let VM fall back." Mid-turn VoiceTurn persist
            // runs via `recordTurnAsTransportError` so ai_request_log
            // + the session's $ai_trace get the aborted-turn row for
            // ADR 0015 cap-reversal trigger visibility.
            if turnStartedAt != nil {
                recordTurnAsTransportError()
            }
            // Cancel in-flight playback so the speaker goes quiet
            // immediately — the interruption handler (OS-level audio
            // pause) has already muted our output but our local
            // pendingPlaybackBuffers may still be scheduling sound
            // that'd surge back when the interruption clears.
            audioPipeline?.cancelPlayback()
            if stateMachine.state != .closed && stateMachine.state != .error {
                stateMachine.advance(to: .error)
            }
        case .interruptionEnded(let shouldResume):
            // Log + leave session in its current state. The user's next
            // tap triggers a fresh preWarm via the VM rebuild path,
            // which gets a clean session + re-activated audio session.
            // Auto-resuming in-place adds risk without clear UX value.
            Logger.voice.info(
                "voice_live_interruption_ended shouldResume=\(shouldResume, privacy: .public) — session stays in error; next tap rebuilds",
            )
        }
    }

    /// Record the in-flight turn as a transport-error row and flush any
    /// pending usage report. Distinct from `finalizeTurn` which handles
    /// happy + watchdog paths — transport-error semantics are different:
    /// - No refresh trigger (we just tried and failed; the session is
    ///   dead or has already swapped to a new transport).
    /// - No new pendingReport creation (nothing downstream will drain it).
    /// - User turn is also marked `.error` (unlike watchdog, where user
    ///   DID speak successfully and only the model's response was
    ///   truncated — here both directions are compromised).
    ///
    /// Review finding P0-H / Critical #8 (2026-04-23). Prior behavior
    /// dropped the turn from both VoiceTurn history AND `ai_request_log`
    /// — ADR 0015's cap-reversal trigger query missed these entirely.
    private func recordTurnAsTransportError() {
        guard turnStartedAt != nil else { return }
        let now = Date()
        let startedAt = turnStartedAt ?? now
        let totalMs = Int(now.timeIntervalSince(startedAt) * 1000)
        turnCount += 1

        let userIdx = voiceTurnRepository.nextTurnIndex(for: cookingSession)
        persistVoiceTurnPairSafely(
            user: .init(
                session: cookingSession,
                speaker: .user,
                turnIndex: userIdx,
                transcriptText: "",
                inputMode: .voice,
                latencyMs: 0,
                resultType: .error,
                errorCode: "transport_error",
            ),
            model: .init(
                session: cookingSession,
                speaker: .model,
                turnIndex: userIdx + 1,
                transcriptText: currentTurnInlineText ?? "",
                inputMode: .voice,
                latencyMs: totalMs,
                resultType: .error,
                errorCode: "transport_error",
            ),
            context: "transport_error_pair",
        )

        // Flush any in-flight pending usage report with the drain reason
        // that best fits: the session isn't really "closed" yet from the
        // VM's perspective, but for the voice-turn-usage POST's purposes
        // this is a terminal-for-this-turn signal. `.sessionClosed` is
        // the closest existing reason; a future enum addition could
        // introduce `.transportError` for dashboard clarity.
        if pendingReport != nil {
            flushPendingReport(dueTo: .sessionClosed)
        }

        // Reset per-turn state. No refresh trigger / pre-mint — session
        // is dead or was just swapped and the caller will either settle
        // back to .ready (on refresh success, handled in
        // handleTransportError's .success branch) or to .error.
        currentTurnInlineText = nil
        turnStartedAt = nil
        userTurnEndAt = nil
        firstModelAudioAt = nil
        turnContainedToolCall = false
        lastToolCallName = nil
    }

    // MARK: - Private: mic forwarding

    private func startMicForwarding() {
        guard let pipeline = audioPipeline else { return }
        // P1-F (2026-04-23): guard against stacking forwarders. Without
        // this, a defensive re-invoke (e.g. belt-and-suspenders
        // `beginTurn` call after error recovery) would assign a new
        // Task to `micForwardTask` while the prior one still holds
        // the `for await pipeline.micFrames` single-consumer iterator.
        // The new Task sees `.finished` immediately and exits; the OLD
        // one keeps forwarding but is no longer referenced — leaked
        // until `close()`. Silent bug class; match the refresh step-10
        // pattern (line 1265: `if micForwardTask == nil`).
        guard micForwardTask == nil else {
            #if DEBUG
            VoiceSessionLog.log("mic_forwarder.start_skipped_already_running")
            #endif
            return
        }
        // Self-capture (weak) so the Task reads `self.transport` on
        // every iteration. `pipeline.micFrames` is a single-consumer
        // AsyncStream created once in LiveAudioPipeline.init; starting
        // a second iteration after cancellation returns immediately
        // with `.finished`. So the forwarder must stay ALIVE across
        // refreshes and pick up the swapped transport dynamically —
        // cancelling + restarting was the bug that stopped mic sends
        // after turn 10's refresh (observed 2026-04-22: mic_tap_fired
        // continued firing but zero mic.sent entries post-refresh).
        micForwardTask = Task { [weak self] in
            guard let self else { return }
            #if DEBUG
            var framesSent = 0
            var bytesSent = 0
            var framesMuted: UInt64 = 0
            var nextLogAtFrame = 50 // ~1 s at 20 ms per frame
            #endif
            // Track the playerNode's running state so we can detect
            // the instant playback transitions from playing→stopped.
            // The cooldown window is measured from THAT transition,
            // not from the server's last audio chunk, because the
            // local AVAudioPlayerNode continues draining buffered
            // audio for 1-2s after the server stops sending chunks.
            // Without this, the cooldown expired while the speaker
            // was still emitting audio and the mic captured the tail
            // (observed 2026-04-22: "heat until", "step", "stick",
            // "then", "kiri" — model transcribing its own playback).
            var wasPlayingBack = false
            var lastPlaybackEndedAt: Date?
            for await frame in pipeline.micFrames {
                if Task.isCancelled { break }
                // Dynamically fetch the CURRENT transport. Nil during
                // the brief window between old-close and new-ready in
                // a refresh; we drop those frames (acceptable — the
                // user is typically silent at turn boundaries).
                guard let transport = self.transport else { continue }
                // Three-part half-duplex gate:
                //
                //   A. state == .modelSpeaking — server reports it's
                //      mid-utterance. Explicit, fast.
                //   B. pipeline.isPlayingBack — local player has
                //      scheduled buffers still draining. Covers the
                //      gap between last server chunk and speaker
                //      silence.
                //   C. now - lastPlaybackEndedAt < echoCooldownSec —
                //      AEC adapt window + room reverb tail after the
                //      speaker actually stopped.
                //
                // AEC (via AVAudioSession mode = .voiceChat) attenuates
                // the echo signal, but server-side VAD can still fire
                // on a -30dB residual given enough time. This gate is
                // the hard backstop.
                //
                // Cost: user can't barge in while model is speaking.
                // Acceptable for MVP — can be re-enabled later if AEC
                // quality proves sufficient in D.1 validation.
                let isPlayingNow = pipeline.isPlayingBack
                if wasPlayingBack && !isPlayingNow {
                    lastPlaybackEndedAt = Date()
                }
                wasPlayingBack = isPlayingNow

                let inModelSpeaking = self.stateMachine.state == .modelSpeaking
                let inPostPlaybackCooldown: Bool = {
                    guard let ended = lastPlaybackEndedAt else { return false }
                    return Date().timeIntervalSince(ended) < LiveSessionBudget.echoCooldownSec
                }()
                // Fourth mute path: active session refresh. During the
                // ~1.7-3.6s handoff we must NOT forward mic audio across
                // the transport swap — if we do, frames land on the new
                // session mid-stream without a clean silence-to-speech
                // VAD boundary, and semantic VAD never fires end-of-speech
                // on the first utterance. Symptom: user speaks after
                // refresh, nothing happens; says it again and it works.
                // Observed 2026-04-22 PM: 43s of mic.sent events post-
                // refresh with zero transcription.user / serverContent,
                // then a second utterance transcribed normally.
                // Dropping frames during refresh means the user's words
                // spoken mid-handoff are lost — but that's a tiny window
                // (~2s at best, ~4s at worst) at a turn boundary where
                // the user is typically silent anyway, and it's vastly
                // preferable to the current 43s dead zone.
                let inRefresh = self.isRefreshing
                let muted = inModelSpeaking || isPlayingNow || inPostPlaybackCooldown || inRefresh
                if muted {
                    #if DEBUG
                    framesMuted &+= 1
                    if framesMuted % 50 == 1 {
                        VoiceSessionLog.log("mic.muted_half_duplex", [
                            "frames_muted": framesMuted,
                            "state": self.stateMachine.state.rawValue,
                            "playing": isPlayingNow,
                            "cooldown": inPostPlaybackCooldown,
                            "refresh": inRefresh,
                        ])
                    }
                    #endif
                    // P3-C (2026-04-23): brief sleep instead of tight
                    // read-and-drop during mute. Without the sleep, the
                    // forwarder wakes on every 20 ms mic frame (50 Hz)
                    // and burns MainActor contention while the user
                    // hears 5-15 s of model speech. With the sleep we
                    // release the MainActor for SwiftUI/other work and
                    // re-check gate conditions on the next tick. 100 ms
                    // is a balance: short enough that post-mute mic
                    // resumption doesn't perceptibly lag (user has to
                    // react to model finishing speaking anyway — their
                    // utterance starts well after the 100 ms window),
                    // long enough to materially reduce wake-ups during
                    // a ~10 s model turn (~100 wakes vs ~500 without).
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                do {
                    try await transport.send(.realtimeInputAudio(
                        base64: frame.base64,
                        mimeType: frame.mimeType,
                    ))
                    #if DEBUG
                    framesSent += 1
                    bytesSent += frame.base64.count
                    // Log every ~1 s of audio so we can see in the
                    // console whether the mic pipeline is actually
                    // pushing bytes. If this log never appears while
                    // user is obviously speaking, the AVAudioEngine
                    // tap callback isn't firing and the whole
                    // "silence from Gemini" problem is on iOS side.
                    if framesSent >= nextLogAtFrame {
                        VoiceSessionLog.log("mic.sent", [
                            "frames": framesSent,
                            "b64_bytes": bytesSent,
                        ])
                        nextLogAtFrame = framesSent + 50
                    }
                    #endif
                } catch {
                    // Don't `break` — a send failure is typically a
                    // refresh-swap teardown of the OLD transport. The
                    // next iteration reads `self.transport` fresh and
                    // picks up the new one. Breaking killed the forwarder
                    // forever post-refresh (observed 2026-04-22, turn 10
                    // onward: zero `mic.sent` events after handoff).
                    Logger.voice.warning(
                        "live_mic_send_failed error=\(error.localizedDescription, privacy: .private)",
                    )
                    #if DEBUG
                    VoiceSessionLog.logError("mic.send_failed", error: error)
                    #endif
                    continue
                }
            }
        }
    }

    private func stopMicForwarding() {
        micForwardTask?.cancel()
        micForwardTask = nil
    }
}
