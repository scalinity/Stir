# Spike scripts

Throwaway Deno scripts for validating external contract assumptions before
production code. Not part of the app.

## `gemini_live_drift_check.ts`

**When:** Start of build step 6 (Cook Mode voice). Re-validates Gemini Live
API surface against CLAUDE.md §"Gemini Live — the sharp-edges section" so
implementation can safely proceed.

**Run:**

```
cd /path/to/Stir
deno run --allow-net --allow-env --allow-read scripts/spike/gemini_live_drift_check.ts
```

Reads `Backend/supabase/.env` for `GEMINI_API_KEY`.

**Tests:**

1. Mint `/v1alpha/authTokens` with `x-goog-api-key` header — confirms
   CLAUDE.md sharp-edge #14 (endpoint version) and #16 (auth mode).
2. Mint with `turn_coverage: TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO` —
   new default post-April-2026 spike.
3. Open WebSocket to
   `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent`
   with `Authorization: Token <ephemeral>` — confirms sharp-edge #13.
4. Send a tiny text turn (not audio — cheap) and await model response.
5. Inspect `usageMetadata` for 25 tokens/second audio metering + the
   undocumented ~200 token AUDIO-mode overhead per sharp-edge #15.

**Exit codes:**

- `0` — no drift; safe to proceed with production code.
- `1` — drift detected; output documents what failed. Update CLAUDE.md
  + the Cook Mode Architecture doc before writing production code.

**Expected output shape:** structured JSON printed to stdout plus a
pass/fail line. Drift findings include the exact HTTP status / error
body so the decision on fallback (OAuth service account vs
backend-proxied WebSocket) can be made immediately.
