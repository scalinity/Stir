# ADR 0011: Native barge-in deferred; keep half-duplex gate; tight cooldown only

- **Status**: Deferred
- **Date**: 2026-04-22
- **Owner-step**: Step 6 → revisit at step 8 (telemetry) or step 9 (beta), whichever produces real user data first
- **Related**: CLAUDE.md §Gemini Live sharp-edges, ADR 0010 (token cap), `Stir/Integrations/GeminiLive/RealtimeSession.startMicForwarding`, `Stir/Integrations/GeminiLive/LiveAudioPipeline`

## Context

Users compare Stir's voice to ChatGPT Realtime, which supports barge-in: the user can speak over the model mid-response and the model stops instantly. On 2026-04-22 Daniel asked: "is there any way to add barge in … without having to mute the mic?"

The current Stir implementation half-duplex-mutes the mic whenever `state == .modelSpeaking` or `pendingPlaybackBuffers > 0` (from AVAudioPlayerNode's `.dataPlayedBack` completion callback), plus a 0.5 s post-playback cooldown for AEC adapt. This makes true barge-in impossible — the mic is physically closed while the model is speaking.

The half-duplex gate exists because prior attempts to keep the mic hot during playback produced catastrophic echo loops: Gemini Live's server-side VAD fires on echo (the model hears its own prior response played through the iPhone speaker, transcribes it as user input — "heat until", "step", "stick", "then" — and generates a new turn responding to its own ghost words). Observed across four separate sessions. iOS `AVAudioSession.mode = .voiceChat` provides hardware AEC, but it's not aggressive enough to suppress speaker output below the server's VAD threshold in kitchen conditions (loud speaker, ambient noise, device proximity).

## Decision

Keep the half-duplex gate. Ship a tight post-playback cooldown (0.5 s) so the mic opens fast after the model stops, giving users natural responsiveness for follow-up questions. Do NOT implement native barge-in (mic-open during model speech) in step 6.

## Alternatives considered

- **Native barge-in via Gemini's `automaticActivityDetection`** — leave mic hot during modelSpeaking; Gemini's server VAD cuts its own output when it detects user speech. **Rejected (for now)** because iOS AEC is the bottleneck: Gemini's VAD fires on echo above our AEC's suppression floor, creating infinite self-talk loops. We verified this empirically four separate sessions in April 2026.
- **On-device voice activity detection pre-filter** — run an on-device VAD (`AVAudioSession.recordPermission`, voice-clarity frameworks, or a small ML model) that distinguishes user speech from speaker echo BEFORE sending audio to Gemini. If the detected energy matches what we just played through the speaker (time-aligned cross-correlation), suppress. **Deferred** — this is a meaningful iOS engineering project (~1-2 weeks) that belongs post-launch.
- **iOS 18+ Voice Isolation API** — newer hardware AEC with ML-based speaker separation. **Deferred** — untested in our kitchen-environment workflow, and min deployment is iOS 17. Revisit when iOS 18+ is our floor.
- **Tap-to-barge-in UX** — tap the mic button during model speech = cancelSpeaking + open mic. **Partially acceptable** — the existing button behavior closes the session on tap during `.busy` states, which loses the user's session context. A dedicated "interrupt, don't close" tap gesture is a viable add but wasn't the primary ask (user wanted voice-only barge-in, not tap).
- **Keep the long 2.5 s cooldown** — rejected on 2026-04-22 in favor of 0.5 s. The 2.5 s felt like an awkward pause; users wanted to speak the moment the model stopped. 0.5 s is tight without being reckless (pendingPlaybackBuffers already nails the "playback done" moment; 0.5 s just covers AEC adapt).

## Consequences

### Positive

- Zero echo-loop risk. Half-duplex gate is a hard correctness guarantee.
- Responsiveness improved from 2.5 s cooldown → 0.5 s cooldown. Natural follow-up cadence.
- Sets a clear "voice quality" milestone for D.1 validation: if the 0.5 s cooldown still feels slow in real kitchen testing, we know AEC + VAD isolation is the next investment.

### Negative

- Cannot interrupt the model mid-sentence. If the model starts a wrong answer, user has to wait for it to finish (up to ~12 s with the 400-token cap) before correcting.
- UX gap vs ChatGPT Realtime. Users who've experienced that UX will notice.

### Tradeoffs

- Reliability of the current flow > novelty of native barge-in. A kitchen user would rather wait 2 s to speak than have the model talk to itself in a loop and waste their time.

## Trigger to revisit

Any ONE of:

1. iOS 18 becomes our minimum deployment target AND Voice Isolation API is measured to reduce echo signal below Gemini's VAD threshold in kitchen conditions.
2. Real user telemetry (step 8) shows > 5 % of sessions include a user correcting the model within 2 s of speech start — indicates barge-in demand.
3. Gemini Live API adds server-side echo cancellation or VAD gating that distinguishes "audio sent to the server" from "audio played on the client and fed back through the mic". Would remove the iOS-side AEC burden entirely.
4. A dedicated on-device VAD + echo-subtraction pipeline is scoped as a post-launch project.

## Notes

- `pendingPlaybackBuffers` (counted via `.dataPlayedBack` completion callback) is the single source of truth for "playback is happening right now". Accurate to within one audio buffer (~20–50 ms). This is the component that made the tight 0.5 s cooldown viable.
- Tap-to-interrupt (separate from tap-to-close) can be layered on as a small UX feature if users want mid-response cancel without closing the whole session. Not in scope for step 6.
