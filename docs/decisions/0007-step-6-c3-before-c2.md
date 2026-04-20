# ADR 0007: Build SpeechFallbackService (C.3) before Gemini Live (C.2)

- **Status**: Accepted
- **Date**: 2026-04-19
- **Owner-step**: Step 6 (Cook Mode voice)
- **Related**: CLAUDE.md §Gemini Live sharp-edges · `docs/validation/step-6-cheap-half-drift-check.md` · Phase C.2 (pending) · Phase C.3 (this ADR)

## Context

Step 6 has two iOS voice paths: Gemini Live primary (phase C.2) and a Speech-STT / `/v1/ai/cook-turn` / AVSpeechSynthesizer text fallback (phase C.3). Spec §10.2 and CLAUDE.md Voice validation plan position the fallback as degraded mode. The natural reading order is C.2 first because Live is the headline Premium feature.

Three forces push against that ordering once you hit real implementation:

1. **Validation-gate risk.** CLAUDE.md's "Voice validation plan" lists five pass/fail criteria for Live (TTFA p95 < 1 s, preamble rate ≥ 70 %, filler timing, pruning holds, silent refresh). Criteria 1 and 4 are explicitly tagged as escalate-not-tune failures. If C.2 ships first and fails either, fallback becomes the primary voice path for v1 — and now it's the LESS-tested one.
2. **Shared infrastructure.** Both paths need the same mic permission primer, `AVAudioSession` configuration, voice-active UI state machine, `VoiceTurn` persistence shape, and PostHog telemetry shell. Building C.2 first creates these ad-hoc; the fallback then either duplicates them or awkwardly retrofits. Building C.3 first establishes them as a stable base C.2 layers on top of.
3. **Complexity gradient.** C.3 is ~1 hour of straightforward iOS primitives (SFSpeechRecognizer + AVSpeechSynthesizer + two repository writes). C.2 is ~4-8 hours of concurrent WebSocket + PCM16 audio pipeline + state machine + pruning + refresh. Scaffolding that C.2 will depend on deserves a clean-room first pass.

## Decision

**Build Phase C.3 (SpeechFallbackService) before Phase C.2 (GeminiLive RealtimeSession).** Land C.3 as a stand-alone checkpoint with its own unit tests green, then build C.2 on top of the shared `AVAudioSession`, `VoiceSessionState`, `VoiceTurn` persistence, and telemetry shell that C.3 establishes.

## Alternatives considered

- **C.2 first, C.3 after** (the natural reading order). Rejected — reverses the risk asymmetry. A failed Live validation gate would leave the fallback path as the primary voice UX without ever having been stress-tested.
- **Concurrent in one long session.** Rejected — the state machine + audio pipeline shared between paths needs a single-builder attention window; interleaving tempts short-circuits that show up later as integration bugs.
- **Ship C.2 behind a feature flag, validate both paths at beta.** Rejected — `disable_cook_realtime` is a kill switch, not a validation surface. Beta is too late to rethink the fallback architecture.

## Consequences

### Positive

- Voice has a working end-to-end path as soon as C.3 lands — even if Live never works. Premium is not a Live-or-nothing bet.
- Shared AVAudioSession config, state machine skeleton, VoiceTurn persistence, and telemetry are built once and reused by C.2. No retrofit.
- Each phase ships as its own commit with its own tests.
- If Live validation gate fails, the fallback is already validated. Premium is shippable without rescoping.

### Negative

- Voice-session UX lags; C.3 is tap-to-speak, so the Premium "hands-free" promise only lands with C.2.
- Two commits where one might have done. Small cost; the separation also helps reviewability.

### Tradeoffs

An extra commit boundary is a small price for the risk-management win. The shared infrastructure C.3 establishes (AVAudioSession config, state machine skeleton, VoiceTurn shape, path-discriminated telemetry) is code C.2 would have needed anyway.

## Notes

- C.2 stays deferred until C.3 is green.
- Memory entry `step-6-c2-deferred.md` mirrors this decision so future sessions pick up the thread without re-deriving it.
- The validation gate runs only once — at the end of C.2 — against both paths. C.3's correctness bar is unit tests + an in-app smoke on a free-tier simulator where Live isn't wired.
