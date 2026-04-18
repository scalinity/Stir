# Gemini Live — Spike Findings

Durable reference for the Cook Mode voice API validation work. Supersedes ad-hoc notes; step 6 kickoff reads this first.

Last updated: 2026-04-18.

---

## April 2026 full-spike (completed)

The full-spike validation ran in April 2026 against `gemini-3.1-flash-live-preview` at `thinkingLevel: minimal`. Results informed the Cook Mode architecture in `Specs/Stir-Cook-Mode-Architecture.md`.

**Validated:**
- WebSocket round-trip against `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`.
- Audio token metering at 25 tokens/sec in both directions (matches published pricing).
- `usageMetadata` frames contain per-turn accumulation — the signal the client uses to detect pruning regressions.
- Preamble pattern works when explicitly prompted; spontaneous preambles are weaker than OpenAI's but the prompt-level instruction lands most of the time at MINIMAL.
- Explicit `max_output_tokens: 150` and `session.update` pruning bound per-turn input audio to ~950 tokens after the third turn.

**Discovered (200-token audio overhead):**
- Audio frames carry a fixed ~200-token overhead per turn that doesn't show up in the raw PCM bit-rate math. Cost model in `CLAUDE.md` and `Specs/Stir-Cook-Mode-Architecture.md` §2 already accounts for this via the carried-context line (825 tokens for 3 prior turns @ ~275 tokens each, which bakes in the overhead).

---

## Unresolved from April spike — step 6 MUST re-validate

**`POST /v1alpha/authTokens` returned `400 INVALID_ARGUMENT` when authenticating with an API key in the spike environment.**

- The ephemeral-token minting flow documented in `Specs/Stir-Cook-Mode-Architecture.md` §3 assumes `x-goog-api-key: <Gemini API key>` header works against the `auth-tokens` endpoint.
- Spike environment returned a generic `400 INVALID_ARGUMENT` — may be API shape drift, API-key policy change, or required OAuth gating on that specific endpoint.
- **Re-test from the actual Supabase Edge Function** at step 6 kickoff — environment may matter (Supabase-hosted Deno vs local curl).

If the re-test still returns `400`, two mitigation paths, both of which keep the Gemini API key server-side:

| Path | Summary | Architectural impact |
| --- | --- | --- |
| **OAuth service-account auth** | Use a GCP service account's ID token instead of a raw API key for the `auth-tokens` endpoint. iOS still connects directly to Gemini Live with the returned ephemeral token. | Small — one helper that mints service-account ID tokens (Deno has `google-auth-library` equivalent). Architecture unchanged downstream. |
| **Backend-proxied WebSocket** | iOS opens a WebSocket to a Supabase Edge Function (not to Gemini). Supabase proxies audio frames upstream to Gemini Live over its own WebSocket, authenticated with the raw API key. | Large — changes the transport story in `Specs/Stir-Cook-Mode-Architecture.md` §4 from "iOS↔Gemini direct" to "iOS↔Supabase↔Gemini". Introduces a new hop with its own latency budget and failure modes. Also removes Supabase Edge Function stateless-ness for voice sessions. |

---

## Step-6 drift re-check (cheap half)

Runs at step 6 kickoff, ~1 hour of curl + Deno script. Purpose: catch API drift between the April 2026 full spike and step-6 start. Do not skip.

Checklist:

1. `curl POST /v1beta/auth-tokens` (or `/v1alpha/authTokens` if path moved) with `model: "models/gemini-3.1-flash-live-preview"` and a minimal `bidi_generate_content_setup` block. **Confirm 200.** If 400 → log whether the re-test reproduces the April `INVALID_ARGUMENT` finding above.
2. Open WebSocket at `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent` with the returned token. Confirm setup-complete frame.
3. Send one PCM16 16kHz test audio frame as `realtimeInput.audio`. Confirm server acknowledges.
4. Parse `usageMetadata` frame. Confirm 25 tokens/sec audio rate still holds both directions.
5. Pricing cross-check at [ai.google.dev/gemini-api/docs/pricing](https://ai.google.dev/gemini-api/docs/pricing). Confirm:
   - `$0.75` text input per 1M
   - `$3.00` audio input per 1M
   - `$4.50` text output per 1M
   - `$12.00` audio output per 1M
6. If any drift: stop and update both `Specs/Stir-Full-Spec.md` §12 and `CLAUDE.md` before proceeding to step 6 build work.

---

## References

- `Specs/Stir-Cook-Mode-Architecture.md` — full voice architecture (Cook Mode research).
- `Specs/Stir-Full-Spec.md` §12 — AI component audit, including cost model.
- `CLAUDE.md` § "Voice validation plan" — the invariant-level pre-commit to run this before any step-6 code.
- [Gemini Live API docs](https://ai.google.dev/gemini-api/docs/live)
- [Gemini Live ephemeral tokens](https://ai.google.dev/gemini-api/docs/ephemeral-tokens)
