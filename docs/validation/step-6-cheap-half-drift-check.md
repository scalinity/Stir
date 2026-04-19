# Step 6 — Cheap-half Gemini Live drift check

**Run date:** 2026-04-19
**Environment:** Supabase Edge Function `spike-gemini-live-probe` on prod project `ktqajarcomzplnpbczfo` (real `GEMINI_API_KEY` from prod secrets).

## Summary

- **Model name `gemini-3.1-flash-live-preview` still exists** and appears in `models.list`.
- **Gemini API key is valid** against `generateContent` and `models.list`.
- **`POST /v1alpha/auth_tokens` rejects API-key auth** with `400 INVALID_ARGUMENT`. This is the same failure mode observed in the April 17 2026 spike (CLAUDE.md sharp-edge #16).
- **Empty body, minimal body, full body all return the same opaque 400.** The server is not telling us which field is wrong; the rejection is happening at the auth layer before body validation.
- **Every other URL variant (`authTokens` camelCase, `auth-tokens` hyphenated, `/v1beta/*`) returns 404.** `/v1alpha/auth_tokens` (snake_case) is the only reachable path — matches the `js-genai` SDK source at `src/tokens.ts`.

## Incidental docs corrections

CLAUDE.md §"Gemini Live sharp-edges" and `Specs/Stir-Cook-Mode-Architecture.md` need correction. Actual wire facts discovered today:

| Fact | CLAUDE.md says | Real |
|---|---|---|
| Mint endpoint path | `/v1alpha/authTokens` | `/v1alpha/auth_tokens` (underscore, not camelCase) |
| Body wrapper | `{ authToken: { … } }` | flat top level; no `authToken` wrapper |
| Body casing | snake_case (`expire_time`, `bidi_generate_content_setup`, `response_modalities` …) | **camelCase** (`expireTime`, `bidiGenerateContentSetup`, `responseModalities` …) |
| Body `bidiGenerateContentSetup` | single-level | per SDK converter it's wrapped as `bidiGenerateContentSetup.setup.*`, then the SDK's `convertBidiSetupToTokenSetup` unwraps it. Wire shape = flat (no inner `setup` key) |
| `turn_coverage` field | `TURN_INCLUDES_ALL_INPUT` | **unknown** — can't validate yet (blocked by auth) |

## Verdict

**API-key auth will not work for mint from the server.** Matches the April 17 spike. Two fallback designs are already in CLAUDE.md #16:

### Option A — OAuth service-account credential server-side

- Create a GCP service account with the `Generative Language API User` role.
- Download the service account JSON key; store as a new Supabase secret (`GCP_SERVICE_ACCOUNT_JSON`).
- Edge Function mints OAuth access tokens from the SA JSON on demand (1h TTL) and caches in memory.
- Use the OAuth token as `Authorization: Bearer <access_token>` when calling `/v1alpha/auth_tokens`.
- iOS still connects to Gemini Live directly via WebSocket with the ephemeral token (`access_token=` query param).

**Cost:** ~2 hours setup. +1 secret rotation surface. No TTFA impact.

### Option B — Backend-proxied WebSocket

- Edge Function holds the Gemini Live WebSocket; iOS connects to the Edge Function over its own WebSocket.
- `GEMINI_API_KEY` stays server-side (already does today).

**Cost:** +100–300 ms TTFA. **Potentially blocked** by Supabase / Deno Deploy long-lived-WebSocket limits (Cook Sessions run up to 30 min; per-request HTTP handlers on Deno Deploy have ~400 s limits, but long-lived WebSocket behavior is not independently verified). Would require its own spike before committing.

## Recommendation

**Option A — OAuth service-account.** Rationale:

1. Option B introduces a new failure mode (Edge Function lifecycle drops the session), plus needs its own spike to validate it's even feasible.
2. Option A is the documented path the Gemini SDKs use, and keeps the key-off-client invariant cleanly.
3. Option A's setup is small and well-documented. iOS-side architecture is unchanged.

## Next step

Surface to Daniel before proceeding with `/v1/ai/realtime-session`. Either:

1. Confirm Option A — I'll add GCP service account setup as a step 6.0 and proceed.
2. Direct me to pursue Option B — I'll first spike whether long-lived WebSockets work on Supabase Edge Functions.
3. Pursue a different angle (e.g., Google Cloud Run for the mint endpoint instead of a Supabase Edge Function, keeping the rest of the backend on Supabase).

## Spike artifact

Final probe output captured in `/tmp/spike_final_output.json`. Reproduced here:

```json
{
  "mint_probe": [
    { "label": "v1alpha_full", "url": ".../v1alpha/auth_tokens", "status": 400, "body": { "error": { "code": 400, "status": "INVALID_ARGUMENT", "message": "Request contains an invalid argument." } } },
    { "label": "v1alpha_minimal", "status": 400, "body": "same opaque 400 INVALID_ARGUMENT" },
    { "label": "v1alpha_empty",   "status": 400, "body": "same opaque 400 INVALID_ARGUMENT" },
    { "label": "v1beta_minimal",  "status": 404, "body": "" }
  ],
  "models_probe": {
    "status": 200,
    "live_models": [{ "name": "models/gemini-3.1-flash-live-preview", "displayName": "Gemini 3.1 Flash Live Preview" }]
  }
}
```

## Cleanup

- `Backend/supabase/functions/spike-gemini-live-probe/` deleted (local + prod).
- `STIR_SPIKE_SECRET` unset from prod secrets.
- `config.toml` `[functions.spike-gemini-live-probe]` block removed.
- `scripts/spike/gemini_live_drift_check.ts` kept in the tree for future drift re-checks (useful when a real key is available locally).
