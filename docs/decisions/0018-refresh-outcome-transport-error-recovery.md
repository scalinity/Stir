# ADR 0018: RefreshOutcome return type + outcome-dispatch recovery in handleTransportError

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 6 (voice)
- **Related**: P0-A from step-6 review 2026-04-23; `RealtimeSession.refreshSession`, `.handleTransportError`, `.recordTurnAsTransportError`; ADR 0014 (session refresh is the pruning mechanism); ADR 0015 (cap reversal trigger signal)

## Context

Prior to this ADR, `refreshSession()` was `async → Void` and `handleTransportError` called it followed by an unconditional `stateMachine.advance(to: .error)` if state wasn't already `.closed`. The intent was "if refresh failed, degrade to C.3 fallback." The bug: refresh that SUCCEEDED (swap committed, new transport healthy) also got demoted to `.error`, because the caller couldn't tell success from failure. Every transient WebSocket drop recovered by a healthy refresh still got reported as "Live → C.3 fallback" in telemetry, and the user saw the wrong path label on ADR-0012 validation dashboards.

Separately, `handleTransportError` dropped the in-flight turn from BOTH `VoiceTurn` history AND `ai_request_log`. The pendingReport flush pipeline never ran on a transport drop, and no VoiceTurn error row was persisted — ADR 0015's cap-reversal trigger query (count of `error`-typed rows per session) missed these entirely, underestimating the `turnComplete_timeout` / `transport_error` signal that gates the Premium cap-reversal decision.

## Decision

`refreshSession(reason:)` returns a typed `RefreshOutcome` enum: `.skipped | .success | .preCommitFailure | .postCommitFailure`. `handleTransportError` dispatches on the outcome:

- `.success` → settle to `.ready` if we were mid-turn; do NOT persist a VoiceTurn row (the turn might still have been processed by Gemini before the drop — unknowable).
- `.postCommitFailure` → state is already `.error`, old transport is closed inside refresh; record the lost turn via the new `recordTurnAsTransportError()` helper.
- `.preCommitFailure` / `.skipped` → old transport errored and refresh didn't recover; advance to `.error` and record the lost turn.

`recordTurnAsTransportError()` persists user + model `VoiceTurn` rows with `resultType=.error, errorCode="transport_error"` via the same `persistVoiceTurnPairSafely` path `finalizeTurn` uses, and flushes any pending usage report with `sessionClosed` drain reason so `ai_request_log` captures the partial turn.

## Alternatives considered

- **Inspect `stateMachine.state` after refresh to infer outcome** — Rejected: refresh leaves state alone on success (preserves whatever the caller was in), which makes `.success` and `.skipped` indistinguishable from inspection alone. The typed return makes the invariant compile-time enforced.
- **Separate `refreshSessionWithOutcome()` wrapper** — Rejected as indirection for no gain. The handful of callers all want the outcome or tolerate the `@discardableResult` annotation if they don't.
- **Keep `handleTransportError`'s unconditional `.error` advance, rely on VM to detect success via a parallel notification** — Rejected: adds a second signal path to keep in sync with state. The outcome dispatch is one source of truth.

## Consequences

### Positive

- Transient WS drops that refresh recovers stay on Live. No spurious C.3 fallback telemetry, no confusing UX of "voice still works but the dashboard says it fell back."
- ADR 0015's cap-reversal trigger signal now captures transport-error turns, not just watchdog-synthesized ones.
- `RefreshOutcome` is Sendable and tests exercise the `.skipped` path directly; `.preCommitFailure` / `.postCommitFailure` require a mock WS harness (deferred).

### Negative

- Public-ish API shape change: `refreshSession` now returns a value. Callers inside `RealtimeSession` that don't care use `@discardableResult`. External callers (there are none today outside the class) would need to update.
- `recordTurnAsTransportError` duplicates the shape of `finalizeTurn`'s persist + flush logic. Refactoring shared scaffolding is deferred to the larger extraction noted in §Deferred.

### Tradeoffs

Returning a typed enum instead of inspecting state after-the-fact costs one extra line per call site but makes the recovery contract legible without running the state machine in your head. Worth it on a path this hot and this full of race-sensitive handoffs.

## Notes

- `recordTurnAsTransportError` sets both user AND model rows to `.error` (vs. watchdog's pattern of user=`.normal`, model=`.error`) because transport errors compromise the in-flight turn in both directions — unlike watchdog, where the user did speak successfully and only the model's response was truncated.
- Test coverage: `RealtimeSessionRecoveryTests.test_refreshSession_returnsSkipped_when{State}` pins the `.skipped` path. `.success` and failure paths need a mock WS — tracked in §Deferred.
