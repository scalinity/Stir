// VoiceSessionTelemetry
//
// SCA-80 — extracted from CookModeViewModel.swift on 2026-05-08. Owns the
// per-Live-session $ai_trace accumulator (PostHog LLM Observability, ADR
// 0009) plus the small cluster of voice-event emitters that previously
// lived inline on the VM. CookModeViewModel keeps thin forwarders so the
// public surface called by `CookModeRoot`, `RealtimeSession`, and the
// CookMode test suite is unchanged — wire-shape preservation is the
// invariant of this refactor (zero new events, zero property churn).
//
// State ownership transfer:
//   liveTurnSummaries / voiceSessionStartedAt / voiceSessionTraceID /
//   voiceSessionInputState moved here. The VM consults `hasActiveTrace`
//   when it needs to ask "is there a trace currently open" without
//   touching the underlying state.
//
// `recordTurnTranscript` deliberately stays on the VM — it's a UI-state
// mutator that drives the YOU SAID / STIR transcript card, not telemetry.
// `currentTurnBargedIn` also stays on the VM (it's set by mic-tap UI
// logic); the VM consumes + resets it at every cook_turn_resolved emit
// site and passes the value down as a parameter so the telemetry helper
// can stay free of UI-flag plumbing.

import Foundation
import OSLog

@MainActor
final class VoiceSessionTelemetry {
    private let analytics: PostHogClient

    // MARK: - Voice session trace accumulator (PostHog LLM Observability)
    //
    // Populated on every RealtimeSession turnComplete via
    // `recordLiveTurnSummary`. Drained when `fireCloseTrace` runs (on
    // exit / close / finish) — emits the close-summary $ai_trace per
    // ADR 0009.
    //
    // These are only populated on the Live path; fallback path has no
    // session concept (cook-turn is per-turn standalone via cook-turn's
    // own $ai_generation capture, which covers its own trace implicitly).

    /// Per-turn summaries accumulated from RealtimeSession.
    /// Cleared on each fireCloseTrace emission to prevent
    /// double-firing on multi-close sequences (exit-after-close).
    private var liveTurnSummaries: [LiveTurnSummary] = []

    /// Wall-clock start of the currently-active Live voice session.
    /// Set when a RealtimeSession attaches; cleared on close trace fire.
    private var voiceSessionStartedAt: Date?

    /// Session id of the currently-active Live voice session, captured
    /// when the driver attaches (so it's available even after `close()`
    /// nulls the driver's mintResponse).
    private var voiceSessionTraceID: String?

    /// $ai_input_state snapshot captured at driver-attach time. Paired
    /// with $ai_output_state in a single close-summary $ai_trace
    /// emission (ADR 0009 — PostHog is append-only, so one emission
    /// carrying both states is the only way to get a complete trace
    /// record). Cleared alongside other session-trace state.
    private var voiceSessionInputState: [String: Any]?

    init(analytics: PostHogClient) {
        self.analytics = analytics
    }

    /// True when a close-trace would actually fire. The VM uses this to
    /// avoid double-firing close traces from teardown paths that race
    /// (e.g. exit while finish is mid-flight); both paths can call
    /// `fireCloseTrace` and only the first wins.
    var hasActiveTrace: Bool { voiceSessionTraceID != nil }

    // MARK: - Lifecycle

    /// Start a new Live-session trace when a driver arrives with a
    /// mint-populated session id. Idempotent: re-entry with the same
    /// session id is a no-op, so attach/rebuild paths don't double-count
    /// duration. Caller (`CookModeViewModel.seedVoiceSessionTrace`)
    /// builds `inputState` from VM-owned data (session.id,
    /// recipePlan.id, currentStepIndex+1, driver.pathLabel,
    /// driver.voiceSessionPromptVersion).
    ///
    /// Before this was factored out, the init path silently skipped
    /// trace-id seeding, which silenced voice_session_token_snapshot
    /// for the whole session and rolled up $ai_trace close-summary to
    /// zero tokens.
    func seedTrace(sessionID: String, inputState: [String: Any]) {
        guard sessionID != voiceSessionTraceID else { return }
        // If a prior trace id is still populated at reseed time, the
        // previous session's `fireCloseTrace` never fired — which means
        // the previous session's $ai_trace is about to be silently
        // dropped (liveTurnSummaries.removeAll() + trace id overwrite
        // below). All current call sites close the prior session BEFORE
        // rebuilding (CookModeViewModel.exit →
        // CookModeRoot.onRequestNewVoiceSession), so this should never
        // fire in practice. Logging at error severity keeps the
        // invariant observable so we catch regressions that route
        // around the close step.
        if let priorTraceID = voiceSessionTraceID {
            Logger.telemetry.error(
                "voice_session_reseed_over_live_trace prior=\(priorTraceID, privacy: .public) new=\(sessionID, privacy: .public) — previous close-trace never fired",
            )
        }
        voiceSessionTraceID = sessionID
        voiceSessionStartedAt = Date()
        liveTurnSummaries.removeAll()
        voiceSessionInputState = inputState
    }

    /// Fires the single `$ai_trace` per voice session (ADR 0009).
    /// Emits with BOTH `$ai_input_state` (captured at attach time) and
    /// `$ai_output_state` (session totals) populated in one event —
    /// PostHog is append-only, so one emission carrying both states is
    /// the only way to get a complete trace record. Idempotent: guard on
    /// voiceSessionTraceID prevents exit-after-close double-fire.
    ///
    /// endedReason values:
    ///   "user_exit"      — user tapped Exit
    ///   "user_stop"      — user tapped mic to stop voice (kept cook mode)
    ///   "user_pause"     — user paused mid-session (not abandoning)
    ///   "session_finish" — user completed the recipe
    ///   "error"          — driver surfaced an unrecoverable error
    func fireCloseTrace(endedReason: String) {
        guard let traceID = voiceSessionTraceID else { return }
        let startedAt = voiceSessionStartedAt ?? Date()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let summaries = liveTurnSummaries
        let totalPromptText = summaries.reduce(0) { $0 + $1.promptTokensText }
        let totalPromptAudio = summaries.reduce(0) { $0 + $1.promptTokensAudio }
        let totalPromptRaw = summaries.reduce(0) { $0 + $1.promptTokensTotal }
        let totalResponseText = summaries.reduce(0) { $0 + $1.responseTokensText }
        let totalResponseAudio = summaries.reduce(0) { $0 + $1.responseTokensAudio }
        let totalResponseRaw = summaries.reduce(0) { $0 + $1.responseTokensTotal }
        // `total_prompt_tokens` / `total_response_tokens` are Gemini's
        // raw totals (matches backend `ai_request_log.input_tokens` /
        // `output_tokens` SUM). Text+audio breakdowns may undersum the
        // total by the AUDIO-mode per-pass overhead — that delta is
        // documented in LiveTurnSummary + spec §15.
        let outputState: [String: Any] = [
            "total_turns": summaries.count,
            "total_prompt_tokens": totalPromptRaw,
            "total_response_tokens": totalResponseRaw,
            "total_prompt_tokens_text": totalPromptText,
            "total_prompt_tokens_audio": totalPromptAudio,
            "total_response_tokens_text": totalResponseText,
            "total_response_tokens_audio": totalResponseAudio,
            "ended_reason": endedReason,
            "duration_ms": durationMs,
            "path": "live_api",
        ]
        analytics.captureAITrace(
            traceID: traceID,
            spanName: "voice_session_start",
            inputState: voiceSessionInputState,
            outputState: outputState,
            feature: "cook_mode_realtime",
        )
        Logger.ui.info(
            "voice_session_close_trace session_id=\(traceID, privacy: .public) turns=\(summaries.count, privacy: .public) duration_ms=\(durationMs, privacy: .public) reason=\(endedReason, privacy: .public)",
        )
        voiceSessionTraceID = nil
        voiceSessionStartedAt = nil
        voiceSessionInputState = nil
        liveTurnSummaries.removeAll()
    }

    // MARK: - Per-turn

    /// Called by CookModeRoot's `onTurnFinalized` wiring on every
    /// RealtimeSession `turnComplete`. Accumulates tokens/latency so
    /// the close-summary $ai_trace can publish totals when the user
    /// ends the session. Drops silently if no trace is active (e.g.,
    /// summaries arriving after fireCloseTrace already ran).
    ///
    /// Also emits the spec §15 `voice_session_token_snapshot` event
    /// every 5 turns for runaway-cost detection. Cumulative tokens are
    /// computed from the same summaries array the close-summary trace
    /// uses, so a live sum at snapshot time + a final sum at close
    /// agree without any separate counter to drift.
    ///
    /// `currentStepIndex`, `pathLabel`, and `bargedIn` are read on the
    /// VM and passed in — the VM owns the underlying state (mic UI flag
    /// for barge-in, voiceDriver for path label, currentStepIndex for
    /// step number) and consumes / resets `currentTurnBargedIn` before
    /// invoking us so the next turn starts clean.
    func recordLiveTurnSummary(
        _ summary: LiveTurnSummary,
        currentStepIndex: Int,
        pathLabel: String,
        bargedIn: Bool,
    ) {
        guard let traceID = voiceSessionTraceID else { return }
        liveTurnSummaries.append(summary)

        // Fire cook_turn_submitted + cook_turn_resolved here rather
        // than from endVoiceTurn, because hands-free Live sessions
        // don't call endVoiceTurn at all — VAD drives turn boundaries
        // server-side and the VM never taps to submit. A 30-turn
        // hands-free session on 2026-04-22 produced zero
        // cook_turn_submitted / cook_turn_resolved events (bug) while
        // the backend billed 10 $ai_generation rows and the token
        // snapshot fired at turns 5/10/15/20 — confirming the session
        // was healthy and the emission site was simply wrong. Events
        // fire per-turn at finalize. `result_type` is "tool_call" when
        // the driver observed a `toolCall` frame during the turn
        // (`summary.containedToolCall`), else "normal" — gating ADR
        // 0012's split TTFA thresholds. Tap-to-end paths on the fallback
        // path keep their endVoiceTurn emission; the Live path's
        // endVoiceTurn skips emission to avoid double-firing.
        // P2-A (2026-04-23): read carried `submittedAt` from the
        // LiveTurnSummary rather than reconstructing via `endedAt -
        // latencyMs` subtraction. Prior reconstruction path was
        // susceptible to NTP drift mid-session producing negative
        // latency_total_ms values that polluted PostHog p95 dashboards.
        let submittedAt = summary.submittedAt
        analytics.capture(.cookTurnSubmitted, properties: [
            "turn_type": "voice",
            "current_step_index": currentStepIndex,
            "path": pathLabel,
        ])
        // result_type routing on the Live path (spec §15 note at line
        // 1693: normal | tool_call | error). Error-ended turns
        // (transport drop, watchdog-synthesized finalize) MUST land as
        // "error" so ADR 0012's split-gate p95 isn't polluted by real
        // failure latencies masquerading as normal turns. Prior to
        // 2026-04-24 this was hardcoded off `containedToolCall` alone
        // and error turns were silently mis-classified.
        let resultType: String
        let errorCode: ErrorCode?
        switch summary.endedReason {
        case .error:
            resultType = "error"
            errorCode = .aiVoice01
        case .interrupted, .turnComplete, .toolResponse:
            resultType = summary.containedToolCall ? "tool_call" : "normal"
            errorCode = nil
        }
        emitCookTurnResolved(
            submittedAt: submittedAt,
            pathLabel: pathLabel,
            resultType: resultType,
            latencyTtfaMs: summary.latencyTtfaMs,
            errorCode: errorCode,
            bargedIn: bargedIn,
        )

        // C.5: token snapshot every 5 turns (5, 10, 15, …). Skip when
        // count == 0 (unreachable in practice — append above guarantees
        // count >= 1 — but guards against misuse if a test injects a
        // zero-index summary). Properties are spec §15 verbatim.
        let turnsSoFar = liveTurnSummaries.count
        if turnsSoFar > 0 && turnsSoFar % 5 == 0 {
            // Raw totals (prompt + response) so runaway-cost detection
            // catches the AUDIO-mode per-pass overhead that the text+audio
            // breakdown undersums. Matches `total_prompt_tokens` +
            // `total_response_tokens` on the close-summary $ai_trace.
            let cumulative = liveTurnSummaries.reduce(0) {
                $0 + $1.promptTokensTotal + $1.responseTokensTotal
            }
            analytics.capture(.voiceSessionTokenSnapshot, properties: [
                "session_id": traceID,
                "turns_so_far": turnsSoFar,
                "cumulative_tokens": cumulative,
                "current_step_index": currentStepIndex,
            ])
        }
    }

    /// Emit `cook_turn_resolved` with spec §15 properties. Must fire on
    /// every terminal turn path — success (`normal`), tool-driven
    /// success (`tool_call`), or error (`error` + `error_code`) — so
    /// the submitted:resolved ratio stays ~1:1 and error rate per path
    /// is measurable. Callers pass the per-turn `submittedAt` so
    /// `latency_total_ms` is anchored at turn submission, not method
    /// entry. `latency_ttfa_ms` is 0 on error paths where TTFA couldn't
    /// be clocked.
    ///
    /// `bargedIn` is read+reset on the VM (set by handleMicTap when the
    /// user interrupts during `.modelSpeaking`); the VM consumes it
    /// before each call so the NEXT turn starts clean (spec §15 line
    /// 1695 semantics: "this turn began by interrupting the previous
    /// turn's playback"). Prior to 2026-04-24 this was a dead write on
    /// the VM and barge_in always emitted false.
    func emitCookTurnResolved(
        submittedAt: Date,
        pathLabel: String,
        resultType: String,
        latencyTtfaMs: Int,
        errorCode: ErrorCode? = nil,
        bargedIn: Bool,
    ) {
        let totalMs = Int(Date().timeIntervalSince(submittedAt) * 1000)
        var props: [String: Any] = [
            "latency_ttfa_ms": latencyTtfaMs,
            "latency_total_ms": totalMs,
            "barge_in": bargedIn,
            "path": pathLabel,
            "result_type": resultType,
        ]
        if let errorCode { props["error_code"] = errorCode.rawValue }
        analytics.capture(.cookTurnResolved, properties: props)
    }

    // MARK: - Refresh + watchdog

    /// Called by the RealtimeSession actor when `refreshSession()` resolves
    /// — success OR failure. Emits spec §15 `voice_session_refreshed`
    /// with a `success: bool` property so the Voice session health
    /// dashboard can compute refresh success rate.
    ///
    /// On success the sessionID is the NEW (post-swap) id; on failure
    /// it's the OLD id (swap didn't commit, or committed-but-handshake-
    /// failed and the session transitioned to .error).
    func recordVoiceSessionRefresh(
        reason: String,
        turnsAtRefresh: Int,
        sessionID: String,
        success: Bool,
    ) {
        analytics.capture(.voiceSessionRefreshed, properties: [
            "session_id": sessionID,
            "refresh_reason": reason,
            "turns_at_refresh": turnsAtRefresh,
            "success": success,
        ])
    }

    /// Called by the RealtimeSession actor when the stuck-modelSpeaking
    /// watchdog fires. Emits `voice_turn_stuck_watchdog_fired` so ops
    /// can track incidence rate of the underlying Gemini Live protocol
    /// bug (ADR 0015 cap-reversal trigger threshold: >5% of tool-call
    /// turns = revisit §18 vendor contingency).
    ///
    /// `sessionID` is always populated ("unknown" fallback applied at
    /// the callback's call site in RealtimeSession if the invariant
    /// ever breaks). `toolCallType` is nullable because a watchdog fire
    /// on a non-tool-call turn is theoretically possible (haven't
    /// observed yet); omitted-from-props when nil.
    func recordVoiceTurnStuckWatchdogFired(
        sessionID: String,
        turnIndex: Int,
        toolCallType: String?,
        elapsedStuckMs: Int,
        turnLengthAtStuck: Int,
    ) {
        var props: [String: Any] = [
            "session_id": sessionID,
            "turn_index": turnIndex,
            "elapsed_stuck_ms": elapsedStuckMs,
            "turn_length_at_stuck": turnLengthAtStuck,
        ]
        if let toolCallType { props["tool_call_type"] = toolCallType }
        analytics.capture(.voiceTurnStuckWatchdogFired, properties: props)
    }

    // MARK: - Substitution

    /// Called by the RealtimeSession actor on each `substitution_check`
    /// tool invocation, before the dispatch hits /v1/ai/substitution.
    /// Emits spec §15 `substitution_requested` with
    /// `invocation: "realtime_function_call"` so the rescue-usage
    /// dashboard can split voice-driven vs sheet-driven substitutions
    /// (the sheet path fires the same event with `invocation: "sheet"`
    /// in SubstitutionSheetViewModel.submit).
    ///
    /// problem_type is "free_text" here — voice has no picker UX, so
    /// the value mirrors the sheet's free-text path. Dashboards split
    /// voice vs sheet via the `invocation` property, not `problem_type`,
    /// so reusing the existing vocabulary avoids a spec §15 amendment.
    func recordVoiceSubstitutionRequested(subEventID: String) {
        // Voice path doesn't have a picker UX; problem_type mirrors the
        // sheet's free-text classification so dashboards can split by
        // `invocation` rather than needing different problem_type vocab.
        // Paired with `recordVoiceSubstitutionResolved` below — both
        // MUST carry `sub_event_id` so the funnel joins cleanly.
        // Signature tightened from `String? = nil` on 2026-04-24 — the
        // optional default invited a future caller to emit without the
        // id, producing an unjoinable row (spec §15 line 1697).
        Logger.telemetry.info(
            "substitution_requested invocation=realtime_function_call sub_event_id=\(subEventID, privacy: .public)",
        )
        analytics.capture(.substitutionRequested, properties: [
            "problem_type": "free_text",
            "invocation": "realtime_function_call",
            "sub_event_id": subEventID,
        ])
    }

    /// Emits `substitution_accepted` on the voice path. Voice has no
    /// user confirm step — safe substitutions are auto-applied
    /// (accepted=true, reason=auto_applied), unsafe results are refused
    /// by the system (accepted=false, reason=unsafe_refused). The
    /// funnel joins this event back to the requested event on
    /// `sub_event_id`. Driver (`RealtimeSession`) fires
    /// `onSubstitutionResolvedFromVoice` from the substitution
    /// tool-response path with the hard-rule-validator outcome.
    func recordVoiceSubstitutionResolved(constraintSafe: Bool, subEventID: String) {
        let reason = constraintSafe ? "auto_applied" : "unsafe_refused"
        Logger.telemetry.info(
            "substitution_accepted invocation=realtime_function_call sub_event_id=\(subEventID, privacy: .public) accepted=\(constraintSafe, privacy: .public) constraint_safe=\(constraintSafe, privacy: .public) reason=\(reason, privacy: .public)",
        )
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": constraintSafe,
            "constraint_safe": constraintSafe,
            "invocation": "realtime_function_call",
            "sub_event_id": subEventID,
            "reason": reason,
        ])
    }

    // MARK: - Generic UX-error emitters

    /// Single spec §15 `screen_error_shown` emission point (properties:
    /// `screen_name`, `error_code` — line 1688). Extracted 2026-04-24
    /// to unify two drift-prone inline sites; the voice-restart-failure
    /// site previously emitted `"screen"` (wrong key) plus non-spec
    /// extras (`step_number`, `attempted_cancels`). Diagnostic detail
    /// for that path lives in the sibling `Logger.ui.warning`.
    func emitScreenError(screen: String, errorCode: String) {
        analytics.capture(.screenErrorShown, properties: [
            "screen_name": screen,
            "error_code": errorCode,
        ])
    }

    /// Spec §15 `voice_affordance_tapped`. Mirrors the inline emitter
    /// previously on the VM; tier and result are passed in by the VM at
    /// each tap site so the helper stays free of EntitlementService
    /// plumbing.
    func emitVoiceAffordance(tier: Tier, result: String) {
        analytics.capture(.voiceAffordanceTapped, properties: [
            "tier": tier.rawValue,
            "result": result,
        ])
    }
}
