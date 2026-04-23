# ADR 0019: Post-commit refresh failure pins C.3 (SpeechFallbackService) for the remainder of the Cook Mode entry

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 6 (voice)
- **Related**: P1-K / CA2-H3 from step-6 review 2026-04-23; `RealtimeSession.onVoiceFallbackRequired`; `CookModeViewModel.pinFallbackForCookSession`; `CookModeRoot.buildVoiceDriver(forceFallback:)`; ADR 0007 (C.3 is SpeechFallbackService — Phase C.3 per step-6 plan); ADR 0018 (RefreshOutcome); ADR 0014 (session refresh)

## Context

**C.3** refers to the `SpeechFallbackService` driver — the on-device `SFSpeechRecognizer` (STT) + `AVSpeechSynthesizer` (TTS) + HTTP `/v1/ai/cook-turn` text path built in Phase C.3 of step 6 (see ADR 0007). It is the always-available fallback when the Gemini Live WebSocket path (C.2, `RealtimeSession`) is unavailable. "Pinning C.3" means routing the VM's voice-driver rebuild to SpeechFallbackService without attempting a fresh Live preWarm.

When a session refresh fails AFTER the transport swap committed — mint succeeded, new WS opened, but setup handshake timed out or returned an unexpected frame — the session is unrecoverable on the Live path. The VM's existing rebuild flow (on next tap) runs `buildVoiceDriver`, which calls `RealtimeSession.preWarm()`. Fresh preWarm after a post-commit handshake failure has high correlation with another post-commit failure: same device, same network, same prompt, same Gemini preview-API state. The user perceives a ~2s handshake attempt on every tap that falls through to C.3 anyway.

## Decision

On post-commit refresh failure (`RefreshOutcome.postCommitFailure`), `RealtimeSession` fires `onVoiceFallbackRequired(reason: String)`. `CookModeViewModel.setPinFallbackForCookSession(reason:)` records a boolean flag scoped to the current Cook Mode VM instance. `CookModeRoot.onRequestNewVoiceSession` reads that flag and passes `forceFallback: true` into `buildVoiceDriver`, which short-circuits to `tryC3Fallback` and never attempts Live preWarm again for the rest of this Cook Mode entry. The flag resets naturally on Cook Mode exit (new VM instance on re-entry).

**Why Cook-Mode-scope, not per-turn reevaluation.** Two reasons a future reader should know. (1) Post-commit refresh failure is highly correlated with the next preWarm attempt within minutes — same device, same network, same prompt version — so per-turn retry produces a ~2s Live-handshake-into-C.3-fallback ping-pong that the user experiences as latency on every tap. (2) Mid-cook Live ↔ C.3 switching changes the voice identity (Gemini voice vs. Samantha TTS) audibly; users read that as malfunction, not recovery. Pinning C.3 for the duration of the Cook Mode entry gives consistent voice and predictable latency. Exiting Cook Mode and re-entering is the natural recovery window — fresh VM, fresh attempt at Live.

## Alternatives considered

- **Session-scoped backoff** (retry Live with exponential delay) — Rejected: adds complexity for a scenario where the failure is highly correlated with the next attempt. Better UX to fall back once than thrash.
- **Process-scoped or user-scoped pin** — Rejected: too sticky. A user who restarts the app or starts a new Cook Mode entry should get Live back. Cook-Mode-scope matches the blast radius of the observed failure.
- **No pin; let the VM retry Live freely** — This was the prior behavior. Rejected because it produces ~2s of wasted handshake latency per tap for the remainder of the Cook Mode session.

## Consequences

### Positive

- Users hit C.3 immediately after a post-commit failure rather than ping-ponging through Live handshakes that will fail.
- Pin is transient — doesn't affect future Cook Mode entries.
- Observable: the `reason` string ("refresh_post_commit_failure" today) is logged on every pin, so ops can see how often this fires.

### Negative

- One-way transition within a Cook Mode entry. If Gemini recovers mid-session, the user stays on C.3 until they exit Cook Mode and re-enter. Tradeoff: avoiding the re-attempt cost > the rare recovery window.
- New cross-cutting callback surface (`onVoiceFallbackRequired`) that subsequent extraction refactors have to preserve.

### Tradeoffs

Binding the pin to Cook Mode VM scope is the narrowest unit that still prevents per-tap ping-pong. Users who want Live back can exit and re-enter — a one-tap recovery that's still under 5 seconds end-to-end.

## Notes

- Trigger today: only `RefreshOutcome.postCommitFailure` from `refreshSession`. Other Live-path failure classes (preWarm failure, initial mint failure) already route to C.3 via `buildVoiceDriver`'s catch block; they don't need the pin because they fail BEFORE any Cook Mode UI is live.
- If a future failure class emerges that would benefit from the same pin (e.g., repeated transport drops within one session), extend by firing `onVoiceFallbackRequired` from that path with a distinct reason string.
