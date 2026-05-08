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
// State ownership transfer: liveTurnSummaries / voiceSessionStartedAt /
// voiceSessionTraceID / voiceSessionPathLabel / voiceSessionInputState
// all live here. The helper owns the wire shape end-to-end — `seedTrace`
// takes typed arguments and builds the $ai_input_state dict internally;
// `fireCloseTrace` reads the stored path label rather than hardcoding
// "live_api". `recordTurnTranscript` deliberately stays on the VM —
// it's a UI-state mutator that drives the YOU SAID / STIR transcript
// card, not telemetry. `currentTurnBargedIn` also stays on the VM
// (it's set by mic-tap UI logic); the VM passes a `() -> Bool` closure
// to `recordLiveTurnSummary` so the flag is consumed past the trace
// guard — preserves the spec §15 line 1695 invariant that bargeIn is
// reset only when an emission actually fires.

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

    /// Per-turn summaries accumulated from RealtimeSession. Cleared on
    /// each fireCloseTrace emission to prevent double-firing on multi-
    /// close sequences (exit-after-close).
    private var liveTurnSummaries: [LiveTurnSummary] = []

    /// Wall-clock start of the currently-active Live voice session.
    /// Set when a RealtimeSession attaches; cleared on close trace fire.
    private var voiceSessionStartedAt: Date?

    /// Session id of the currently-active Live voice session, captured
    /// when the driver attaches (so it's available even after `close()`
    /// nulls the driver's mintResponse).
    private var voiceSessionTraceID: String?

    /// Path label captured at seedTrace ("live_api" today; reserved
    /// for fallback once that path gains $ai_trace coverage). Read by
    /// `fireCloseTrace` for the $ai_output_state path field and by
    /// `recordLiveTurnSummary` for the per-turn cook_turn_submitted /
    /// cook_turn_resolved path properties — single source of truth so
    /// the Live and Close traces can never disagree on path.
    private var voiceSessionPathLabel: String?

    /// $ai_input_state snapshot captured at driver-attach time. Paired
    /// with $ai_output_state in a single close-summary $ai_trace
    /// emission (ADR 0009 — PostHog is append-only, so one emission
    /// carrying both states is the only way to get a complete trace
    /// record). Cleared alongside other session-trace state.
    private var voiceSessionInputState: [String: Any]?

    init(analytics: PostHogClient) {
        self.analytics = analytics
    }

    // MARK: - Lifecycle

    /// Start a new Live-session trace when a driver arrives with a
    /// mint-populated session id. Idempotent: re-entry with the same
    /// session id is a no-op, so attach/rebuild paths don't double-count
    /// duration. Builds the $ai_input_state dict internally from typed
    /// arguments; the VM only passes raw values, never the assembled
    /// dict — keeps wire shape ownership on the helper.
    ///
    /// If a prior trace id is still populated at reseed time, that
    /// previous session's `fireCloseTrace` never fired. We DEFENSIVELY
    /// fire a close-trace with `endedReason: "error"` first to recover
    /// the prior session's $ai_trace before overwriting state, AND log
    /// at error severity so the regression is observable. All current
    /// call sites close the prior session BEFORE rebuilding
    /// (CookModeViewModel.exit → CookModeRoot.onRequestNewVoiceSession),
    /// so this should never fire in practice — recovery is a safety
    /// net for callers that route around the close step.
    func seedTrace(
        sessionID: String,
        cookingSessionID: UUID?,
        recipePlanID: UUID?,
        currentStepNumber: Int,
        pathLabel: String,
        promptVersion: String?,
    ) {
        guard sessionID != voiceSessionTraceID else { return }
        if let priorTraceID = voiceSessionTraceID {
            Logger.telemetry.error(
                "voice_session_reseed_over_live_trace prior=\(priorTraceID, privacy: .public) new=\(sessionID, privacy: .public) — recovering prior trace via defensive fireCloseTrace",
            )
            fireCloseTrace(endedReason: "error")
        }
        voiceSessionTraceID = sessionID
        voiceSessionStartedAt = Date()
        voiceSessionPathLabel = pathLabel
        liveTurnSummaries.removeAll()
        var inputState: [String: Any] = [
            "cooking_session_id": cookingSessionID?.uuidString ?? "",
            "recipe_plan_id": recipePlanID?.uuidString ?? "",
            "current_step_number": currentStepNumber,
            "path": pathLabel,
        ]
        if let promptVersion {
            inputState["prompt_version"] = promptVersion
        }
        voiceSessionInputState = inputState
    }

    /// Fires the single `$ai_trace` per voice session (ADR 0009).
    /// Emits with BOTH `$ai_input_state` (captured at attach time) and
    /// `$ai_output_state` (session totals) populated in one event —
    /// PostHog is append-only, so one emission carrying both states is
    /// the only way to get a complete trace record. Idempotent: guard on
    /// voiceSessionTraceID prevents exit-after-close double-fire. State
    /// nil-outs run inside `defer` so a future throwing PostHog API
    /// can't leak trace state across sessions.
    ///
    /// endedReason values:
    ///   "user_exit"      — user tapped Exit
    ///   "user_stop"      — user tapped mic to stop voice (kept cook mode)
    ///   "user_pause"     — user paused mid-session (not abandoning)
    ///   "session_finish" — user completed the recipe
    ///   "error"          — driver surfaced an unrecoverable error, OR
    ///                      defensive recovery from `seedTrace` over a
    ///                      stale trace id (see seedTrace docstring).
    func fireCloseTrace(endedReason: String) {
        guard let traceID = voiceSessionTraceID else { return }
        defer {
            voiceSessionTraceID = nil
            voiceSessionStartedAt = nil
            voiceSessionPathLabel = nil
            voiceSessionInputState = nil
            liveTurnSummaries.removeAll()
        }
        let startedAt = voiceSessionStartedAt ?? Date()
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        // Single-pass tuple accumulator — runs once per session at close
        // (n ≤ ~30 turns typical, hard-cap ~60), so perf is irrelevant;
        // single pass reads as one operation and removes a class of
        // "did I forget to sum field X" bugs if the schema gains a field.
        // `total_prompt_tokens` / `total_response_tokens` are Gemini's
        // raw totals (matches backend `ai_request_log.input_tokens` /
        // `output_tokens` SUM). Text+audio breakdowns may undersum the
        // total by the AUDIO-mode per-pass overhead — that delta is
        // documented in LiveTurnSummary + spec §15.
        var totals = (
            promptText: 0,
            promptAudio: 0,
            promptRaw: 0,
            responseText: 0,
            responseAudio: 0,
            responseRaw: 0,
        )
        for s in liveTurnSummaries {
            totals.promptText += s.promptTokensText
            totals.promptAudio += s.promptTokensAudio
            totals.promptRaw += s.promptTokensTotal
            totals.responseText += s.responseTokensText
            totals.responseAudio += s.responseTokensAudio
            totals.responseRaw += s.responseTokensTotal
        }
        let outputState: [String: Any] = [
            "total_turns": liveTurnSummaries.count,
            "total_prompt_tokens": totals.promptRaw,
            "total_response_tokens": totals.responseRaw,
            "total_prompt_tokens_text": totals.promptText,
            "total_prompt_tokens_audio": totals.promptAudio,
            "total_response_tokens_text": totals.responseText,
            "total_response_tokens_audio": totals.responseAudio,
            "ended_reason": endedReason,
            "duration_ms": durationMs,
            "path": voiceSessionPathLabel ?? "live_api",
        ]
        analytics.captureAITrace(
            traceID: traceID,
            spanName: "voice_session_start",
            inputState: voiceSessionInputState,
            outputState: outputState,
            feature: "cook_mode_realtime",
        )
        let turnCount = liveTurnSummaries.count
        Logger.telemetry.info(
            "voice_session_close_trace session_id=\(traceID, privacy: .public) turns=\(turnCount, privacy: .public) duration_ms=\(durationMs, privacy: .public) reason=\(endedReason, privacy: .public)",
        )
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
    /// `consumeBargeInFlag` is invoked AFTER the trace-id guard, never
    /// before — so a late `turnComplete` arriving post-close leaves
    /// `currentTurnBargedIn` intact for the next session. Path label
    /// is read from the stored `voiceSessionPathLabel` set at seedTrace
    /// time so per-turn and close-trace paths can never disagree.
    func recordLiveTurnSummary(
        _ summary: LiveTurnSummary,
        currentStepIndex: Int,
        consumeBargeInFlag: () -> Bool,
    ) {
        guard let traceID = voiceSessionTraceID else { return }
        let pathLabel = voiceSessionPathLabel ?? "live_api"
        liveTurnSummaries.append(summary)

        // Fire cook_turn_submitted + cook_turn_resolved here rather
        // than from endVoiceTurn, because hands-free Live sessions
        // don't call endVoiceTurn at all — VAD drives turn boundaries
        // server-side and the VM never taps to submit. Tap-to-end paths
        // on the fallback path keep their endVoiceTurn emission; the
        // Live path's endVoiceTurn skips emission to avoid double-firing.
        // P2-A (2026-04-23): read carried `submittedAt` from the
        // LiveTurnSummary rather than reconstructing via `endedAt -
        // latencyMs` to avoid NTP-drift-induced negative latencies.
        let submittedAt = summary.submittedAt
        analytics.capture(.cookTurnSubmitted, properties: [
            "turn_type": "voice",
            "current_step_index": currentStepIndex,
            "path": pathLabel,
        ])
        // result_type routing on the Live path (spec §15: normal |
        // tool_call | error). Error-ended turns MUST land as "error"
        // so ADR 0012's split-gate p95 isn't polluted by failure
        // latencies masquerading as normal turns.
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
            bargedIn: consumeBargeInFlag(),
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
    /// `bargedIn` is consumed on the VM side at every emit site (the
    /// Live path consumes it past the trace guard via the closure on
    /// `recordLiveTurnSummary`; the fallback path consumes it directly
    /// in the VM's emitCookTurnResolved wrapper).
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

    /// Called by the RealtimeSession when `refreshSession()` resolves
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

    /// Called by the RealtimeSession when the stuck-modelSpeaking
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

    /// Called by the RealtimeSession on each `substitution_check`
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
    ///
    /// Paired with `emitVoiceSubstitutionResolved` — both MUST carry
    /// `sub_event_id` so the funnel joins cleanly. Signature tightened
    /// from `String? = nil` on 2026-04-24 — the optional default invited
    /// a future caller to emit without the id, producing an unjoinable
    /// row (spec §15 line 1697).
    func emitVoiceSubstitutionRequested(subEventID: String) {
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
    func emitVoiceSubstitutionResolved(constraintSafe: Bool, subEventID: String) {
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

    // MARK: - SCA-148 — substitution disambiguation

    /// Closed surface enum for `voice_substitution_disambiguated.surface`.
    /// Voice path is the only emit site today; tap path is reserved for
    /// the SubstitutionSheet's auto-apply branch if it ever picks up
    /// matchIngredient logic. Adding a new case requires updating spec
    /// §15 + CLAUDE.md telemetry list in the same commit.
    enum SubstitutionDisambiguationSurface: String {
        case voice
        case tap
    }

    /// Closed resolution enum for `voice_substitution_disambiguated.resolved_to`.
    /// `freeTextFallback` is what we ship in v1: ambiguous voice matches
    /// route to the free-text persistence path (no recipe mutation);
    /// the model's narration carries the user-facing swap.
    /// `userPickedFirst` / `userPickedSecond` / `timedOut` are reserved
    /// for the future "ask the user mid-turn" build-out (Owner-step:
    /// "as triggered" — needs RealtimeSession state-machine work).
    /// Until that lands, emit only `freeTextFallback`. Closed vocab
    /// keeps the eventual prompt-UX wiring from drift-shipping a typo.
    enum SubstitutionDisambiguationResolution: String {
        case freeTextFallback = "free_text_fallback"
        case userPickedFirst = "user_picked_first"
        case userPickedSecond = "user_picked_second"
        case timedOut = "timed_out"
    }

    /// SCA-148: emit `voice_substitution_disambiguated` when matchIngredient
    /// detects a same-length tie among substring candidates. Properties:
    ///   - `session_id` (string) — joins to the voice session trace
    ///   - `candidate_count` (int) — number of equally-long winners
    ///   - `surface` (string ∈ {voice, tap})
    ///   - `resolved_to` (string ∈ closed enum above)
    /// PostHog dashboards: split by surface; if 7-day rolling
    /// `voice_substitution_disambiguated / substitution_requested(invocation=realtime_function_call) ≥ 1%`
    /// the prompt-UX work is justified per the SCA-148 ticket trigger.
    func recordSubstitutionDisambiguated(
        sessionID: UUID?,
        candidateCount: Int,
        surface: SubstitutionDisambiguationSurface,
        resolvedTo: SubstitutionDisambiguationResolution,
    ) {
        // "unknown" placeholder beats "" so PostHog dashboards filtering
        // by session_id don't silently drop these events. Matches the
        // pattern used by `leftovers_dish_selected.source_recipe_plan_id`.
        let sessionIDString = sessionID?.uuidString ?? "unknown"
        Logger.telemetry.info(
            "voice_substitution_disambiguated session_id=\(sessionIDString, privacy: .public) candidate_count=\(candidateCount, privacy: .public) surface=\(surface.rawValue, privacy: .public) resolved_to=\(resolvedTo.rawValue, privacy: .public)",
        )
        analytics.capture(.voiceSubstitutionDisambiguated, properties: [
            "session_id": sessionIDString,
            "candidate_count": candidateCount,
            "surface": surface.rawValue,
            "resolved_to": resolvedTo.rawValue,
        ])
    }

    // MARK: - Generic UX-error emitters

    /// Single spec §15 `screen_error_shown` emission point (properties:
    /// `screen_name`, `error_code`). Extracted 2026-04-24 to unify two
    /// drift-prone inline sites; the voice-restart-failure site
    /// previously emitted `"screen"` (wrong key) plus non-spec extras
    /// (`step_number`, `attempted_cancels`). Diagnostic detail for
    /// that path lives in the sibling `Logger.ui.warning`.
    func emitScreenError(screen: String, errorCode: String) {
        analytics.capture(.screenErrorShown, properties: [
            "screen_name": screen,
            "error_code": errorCode,
        ])
    }

    /// Spec §15 `voice_affordance_tapped`. Result vocabulary is closed
    /// — see `VoiceAffordanceResult` — so a stray new property value
    /// can't reach PostHog without updating the enum + spec §15 +
    /// CLAUDE.md telemetry list together.
    func emitVoiceAffordance(tier: Tier, result: VoiceAffordanceResult) {
        analytics.capture(.voiceAffordanceTapped, properties: [
            "tier": tier.rawValue,
            "result": result.rawValue,
        ])
    }
}

/// Closed result vocabulary for `voice_affordance_tapped.result` (spec
/// §15). Adding a new case requires updating spec §15 `paywall_viewed.
/// trigger` mappings if the case routes through the paywall, plus the
/// CLAUDE.md telemetry-events list.
enum VoiceAffordanceResult: String {
    case paywallShown = "paywall_shown"
    case voiceStarted = "voice_started"
    case voiceStopped = "voice_stopped"
    case permissionDenied = "permission_denied"
}
