# Step 6 — Cheap-half Gemini Live drift check

**Run date:** 2026-04-19 (multiple iterations across the day)
**Environment:** Supabase Edge Function `spike-oauth-mint-probe` on prod project `ktqajarcomzplnpbczfo`.
**Final status:** ✅ Passed. Mint + full voice round-trip validated.

## TL;DR

- Gemini Live is reachable from the Stir backend and produces working ephemeral tokens via API-key auth.
- Two pre-body gates had to be satisfied before mint would accept any request, and each gate masks the other by returning the same opaque `400 INVALID_ARGUMENT`: (1) paid-tier billing on the GCP project, (2) legacy `AIzaSy…` API key format. The misdiagnosis cycle consumed most of the day.
- Recommended model for v1: `gemini-3.1-flash-live-preview` (568 ms TTFA, comfortable headroom against the 1 s p95 target).
- CLAUDE.md sharp-edges #16, #17, #18 updated with the real facts. ADR 0006 (OAuth service-account mint) marked Rejected with full post-mortem.

## Diagnosis history (short form, for future future-Claude)

1. **Initial hypothesis (wrong):** `auth_tokens` endpoint rejects API-key auth; need OAuth service-account. Built on empirical `400 INVALID_ARGUMENT` across every body shape, while `models.list` + `generateContent` worked on the same key. Decided to build an OAuth path. Got as far as working OAuth access tokens and a clean helper (7 unit tests green).
2. **OAuth path also returned `400 INVALID_ARGUMENT`** on `auth_tokens`. Same error. Sanity probe showed `models.list` with OAuth returning `ACCESS_TOKEN_SCOPE_INSUFFICIENT` → OAuth fundamentally incompatible with `generativelanguage.googleapis.com`.
3. **Tested the official `@google/genai` SDK with API-key auth directly.** Same `400 INVALID_ARGUMENT`. Even an empty body (`{}`) returned identical error. Ruled out body-shape bugs categorically.
4. **Checked for gated-preview:** Google docs say no allowlist. Model appears in `models.list`.
5. **Re-checked GCP project setup:** API key was on `stir-ai-dinner-copilot`, same project as the SA. Billing enabled.
6. **Discovered model-name drift** (separate issue): `gemini-3-flash` returns 404 NOT_FOUND. Real name is `gemini-3-flash-preview`. The entire backend had been configured with phantom model names. Fixed in a separate commit.
7. **Daniel identified billing-tier gate:** free-tier billing doesn't unlock `auth_tokens`. Flipped to paid tier. Mint still 400.
8. **Daniel identified key-format gate:** new-format keys (`AQ.xxx`, 53 chars) fail `auth_tokens` despite working elsewhere. Legacy `AIzaSy…` format works. Google forum thread 141133 documents the bug. Generated a fresh legacy key.
9. **Swapped prod secret to legacy key.** Mint succeeds. Full voice round-trip validates.

## Final working configuration

- **Mint endpoint:** `POST https://generativelanguage.googleapis.com/v1alpha/auth_tokens`
- **Mint auth:** `x-goog-api-key: <GEMINI_API_KEY>` (same header as every other Gemini call)
- **Mint body** (flat camelCase — NOT snake_case, NOT wrapped in `{ authToken: … }`):
  ```json
  {
    "expireTime": "…",
    "newSessionExpireTime": "…",
    "uses": 1,
    "bidiGenerateContentSetup": {
      "model": "models/gemini-3.1-flash-live-preview",
      "generationConfig": {
        "responseModalities": ["AUDIO"],
        "speechConfig": { "voiceConfig": { "prebuiltVoiceConfig": { "voiceName": "Aoede" } } },
        "maxOutputTokens": 150,
        "thinkingConfig": { "thinkingLevel": "minimal" }
      },
      "systemInstruction": { "parts": [{ "text": "…" }] },
      "tools": [],
      "realtimeInputConfig": {
        "automaticActivityDetection": { "disabled": false },
        "turnCoverage": "TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO"
      }
    }
  }
  ```
- **Mint response:** `{ "name": "auth_tokens/<hex>" }` — the `.name` IS the access token value for the WebSocket connection.
- **WebSocket URL:** `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained?access_token=<token-name>`
- **WebSocket method:** `BidiGenerateContentConstrained` when using ephemeral token (not `BidiGenerateContent`). API version `v1alpha` in the path (not `v1beta`).

## TTFA comparison (single-run observations on Supabase Edge Function → Google)

| Metric | `gemini-3.1-flash-live-preview` | `gemini-2.5-flash-native-audio-latest` |
|---|---|---|
| Setup latency (open + setupComplete) | 249 ms | 305 ms |
| **TTFA** (client turn sent → first audio frame) | **568 ms** | 1 186 ms |
| Total round-trip (turn sent → turnComplete) | 1 299 ms | 1 195 ms |
| Streamed frames in response | 11 (fine-grained audio chunks) | 4 (bundled chunks) |
| Text-injection API | `realtimeInput.text` (clientContent is history-only — sharp-edge #11) | `clientContent.turns` |
| Thoughts tokens billed | 0 (`thinkingLevel: minimal` honored) | 42 (no equivalent suppression) |
| Prompt tokens (observed) | not yet surfaced in usageMetadata for first-turn | 348 |

**Choice for v1:** `gemini-3.1-flash-live-preview`. 568 ms TTFA comfortably clears the 1 s p95 target and leaves room for network variability. Zero thoughts-token overhead. All existing spec references (cost model, Architecture doc, system prompt) are already keyed on this model. The `realtimeInput.text` constraint is already documented in CLAUDE.md sharp-edge #11.

The 2.5 native-audio family is a viable tail-risk fallback if 3.1 Flash Live Preview is ever pulled — but would require retuning the TTFA budget and the cost model.

## Resulting CLAUDE.md updates

- **#14** (mint endpoint): path corrected to `/v1alpha/auth_tokens` (snake_case); body documented as flat camelCase with canonical field list.
- **#16** (mint auth): rewritten to say "API-key auth works, same `GEMINI_API_KEY`." OAuth service-account path retained in ADR 0006 as Rejected with full post-mortem.
- **#17** (billing gate): new — paid-tier billing required on the owning GCP project; free-tier gates mint with opaque 400.
- **#18** (key format): new — mint rejects `AQ.xxx` new-format keys; use legacy `AIzaSy…`. Links forum thread 141133.

## What's still deferred to step 6 expensive-half validation gate

This doc confirms the cheap-half is green. The expensive-half (CLAUDE.md Voice validation plan) runs after the iOS side is wired. All five criteria remain untested:

1. TTFA p95 < 1.0 s across 20 real iPhone turns on Wi-Fi. Backend-side latency here (568 ms) is a lower bound; iPhone + network variance will add.
2. Preamble-present rate ≥ 70 % across 50 tool calls. Not tested.
3. Pre-recorded filler clip fires within 150 ms of `toolCall` frame. Not tested — iOS-only.
4. Pruning via `session.update` holds input tokens at ~950/turn across 20 turns. Not tested.
5. Session refresh silent at 10 min / 15 turn boundary. Not tested.

## Cleanup state

- `Backend/supabase/functions/spike-oauth-mint-probe/` — local + prod, to be deleted after this doc lands.
- `STIR_SPIKE_SECRET` — to be unset from prod secrets after cleanup.
- `config.toml` `[functions.spike-oauth-mint-probe]` block — to be removed.
- GCP service account `stir-live-mint@stir-ai-dinner-copilot.iam.gserviceaccount.com` and its `aiplatform.user` binding — created during the OAuth-path misdiagnosis; now unused. **Safe to delete** via `gcloud iam service-accounts delete stir-live-mint@stir-ai-dinner-copilot.iam.gserviceaccount.com` if Daniel wants a clean GCP surface. Zero cost if retained.
- `scripts/spike/gemini_live_drift_check.ts` — kept. Useful for re-running this drift check locally when a real `AIzaSy…` key is available in the shell env.
