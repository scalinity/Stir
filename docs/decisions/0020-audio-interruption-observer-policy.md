# ADR 0020: AudioInterruptionObserver — system audio events tear down voice cleanly; no in-place resume

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 6 (voice)
- **Related**: P0-D / CA2-Critical-1 from step-6 review 2026-04-23; `Stir/Integrations/Speech/AudioInterruptionObserver.swift`; `RealtimeSession.handleAudioInterruption`; `SpeechFallbackService.handleAudioInterruption`; CLAUDE.md §Gemini Live sharp-edges (no WebRTC; WebSocket-over-cellular failure modes)

## Context

Prior to this ADR, voice sessions observed zero system audio events. Phone call during a cook, Siri trigger, AirPods yank, or iOS media-services reset all silently broke the session: AVAudioEngine got force-stopped by the OS, the mic tap stopped firing, the WebSocket stayed open, and Gemini's server VAD sat on silence until `idleDisconnectSec` (15 min) fired. No UI cue, no recovery path — users force-quit.

Four relevant AVAudioSession notifications exist: `interruptionNotification` (began / ended), `routeChangeNotification` (reason enum includes `oldDeviceUnavailable`), and `mediaServicesWereResetNotification`. Each can silently break the audio graph; none surfaces naturally as an error on the existing code paths.

## Decision

Introduce `AudioInterruptionObserver` as a shared seam owned by both drivers (RealtimeSession on the Live path, SpeechFallbackService on the C.3 path). The observer emits typed `Event`s; each driver implements its own `handleAudioInterruption` and tears down to `.error` state on every disruption class except `.interruptionEnded`. The `.interruptionEnded` signal is LOGGED but NOT auto-resumed — the user's next tap rebuilds cleanly from the VM's `onRequestNewVoiceSession` path.

Live path: cancel playback, record the in-flight turn as transport-error (if any), advance state to `.error`. C.3 path: cancel recognitionTask + stopSpeaking + advance to `.error`.

## Alternatives considered

- **Attempt in-place resume on `interruptionEnded` with `.shouldResume` hint** — Rejected: SFSpeechRecognizer's post-interruption state is not documented as safe to resume, and Gemini Live's WebSocket after an OS-driven audio session pause can be in a half-valid state where frames transit but VAD boundaries are misaligned. A clean rebuild is more reliable than a gamble.
- **Observe only interruptions, not route changes or media-reset** — Rejected: AirPods yank moves mic + speaker to handset silently, leaving AEC tuning wrong. Media-services-reset invalidates the whole audio graph; ignoring it guarantees a crash on the next playback scheduling.
- **Put observer lifecycle on a global coordinator** — Rejected for now: current usage is per-driver and short-lived. A global coordinator adds ownership ambiguity without eliminating the per-driver handler.

## Consequences

### Positive

- Phone call / Siri / AirPods / media-reset all produce a clean "session ended; tap to restart" UX instead of silent wedging.
- Pattern is symmetric between Live and Fallback paths — one observer type, two handlers.
- Observable: each event fires `voice_live_audio_interruption` / `voice_fallback_audio_interruption` OSLog lines with the event type, so ops can see real-world interruption rates.

### Negative

- No auto-resume means users who get interrupted by Siri must tap the mic again. Acceptable tradeoff vs. the reliability of an automatic resume that isn't guaranteed to work.
- The observer's Task-dispatched handler invocations mean interruption handling is one-MainActor-hop delayed from the notification. Under rapid-fire interruption sequences, this could coalesce multiple events; `handleAudioInterruption` is idempotent by design.

### Tradeoffs

Fail-safe over auto-recovery. Voice assistants that aggressively auto-resume after interruptions are a common source of "why is it listening now?" user confusion. Explicit rebuild is the honest default.

## Notes

- `UIApplication.willEnterForegroundNotification` is observed separately on the Live path (P0-F) to re-check mic permission; it is NOT part of `AudioInterruptionObserver`'s remit because permission state is a user-scope concern, not an audio-graph-scope one.
- If a future requirement changes (e.g., "resume after brief Siri without tap"), extend `.interruptionEnded` handling to conditionally rebuild when the interruption was short and `.shouldResume` was set. Keep the default posture fail-safe.
