# ADR 0006: Gemini Live ephemeral-token mint uses OAuth service-account auth, not API-key auth

- **Status**: Accepted
- **Date**: 2026-04-19
- **Owner-step**: Step 6 (Cook Mode voice)
- **Related**: CLAUDE.md §Gemini Live sharp-edges #14, #16 · `docs/validation/step-6-cheap-half-drift-check.md` · `Backend/supabase/functions/ai-realtime-session/` (to be created) · Specs/Stir-Cook-Mode-Architecture.md §3

## Context

Gemini Live requires minting an ephemeral per-session auth token server-side (CLAUDE.md invariant: no provider API keys on iOS, ever). The April 17 2026 spike saw `POST /v1alpha/authTokens` return opaque `400 INVALID_ARGUMENT` with API-key auth. The April 19 2026 re-run from the Supabase Edge Function environment — where the real `GEMINI_API_KEY` lives and where step-6 backend code will run — confirmed the same failure, regardless of request body shape (including the SDK-correct camelCase flat body, a minimal body, and an empty body). Every other Gemini endpoint (`models.list`, `models/*:generateContent`) accepts the same API key without issue, so the key is valid; the `/v1alpha/auth_tokens` endpoint specifically rejects API-key auth.

Two unblocking paths are available. Choosing one is load-bearing: it determines how the Cook Mode voice session opens, which is the single most user-visible piece of step 6.

## Decision

**Use an OAuth service-account credential server-side to mint Gemini Live ephemeral tokens.** Create a Google Cloud service account in a dedicated project, grant it the minimum role needed to call `GenerativeLanguage.CreateAuthToken`, download the JSON key, and store it in Supabase Edge Function secrets as `GCP_SERVICE_ACCOUNT_JSON`. The Edge Function exchanges the service-account JWT for a short-lived OAuth access token (1h TTL, cached in memory), then calls `POST /v1alpha/auth_tokens` with `Authorization: Bearer <access_token>`. iOS continues to connect to Gemini Live directly over WebSocket using the minted ephemeral token via the `access_token=` query parameter.

## Alternatives considered

- **API-key auth on the mint endpoint.** Rejected — does not work. Confirmed empirically twice (April 17 spike, April 19 re-run from the Edge Function itself). The endpoint returns opaque 400 INVALID_ARGUMENT regardless of body shape or key validity.

- **Backend-proxied WebSocket** (Edge Function holds the Gemini Live WebSocket; iOS connects to the Edge Function over its own WebSocket). Rejected because:
  1. Adds +100–300 ms TTFA for every voice turn — the one latency number we've explicitly committed to keeping under 1.0s p95.
  2. Requires a new spike to validate that long-lived WebSockets survive Supabase / Deno Deploy request limits (per-HTTP-request timeouts are ~400s on Deno Deploy; the 30-min Cook Session hard limit would almost certainly blow past that).
  3. Introduces a new failure mode: Function restart drops the active voice session silently. No clean recovery path.

- **Move the mint endpoint to Google Cloud Run (or another long-running compute target).** Rejected for v1 — would split the backend across two providers for one endpoint's sake. Revisit only if Option A becomes untenable.

- **Run Cook Mode voice through a higher-level SDK (e.g., Python `google-genai`) in a hosted notebook / service.** Rejected — same split-backend downside, plus we'd be importing a large SDK just to get the OAuth flow that is ~40 lines of Deno.

## Consequences

### Positive

- Keeps the provider API key off the client (invariant preserved).
- Zero TTFA penalty — iOS still connects to Gemini Live directly after mint.
- Matches what the Google SDKs do internally (the `client.authTokens.create()` calls in `js-genai` / `python-genai` use OAuth under the hood when a service account is configured). Building on a path Google officially maintains.
- Access-token exchange is cached in memory for 55 min; added per-request latency on a cache-miss is ~200 ms for the JWT sign + OAuth token fetch, and ~0 ms on the hot path.

### Negative

- **New secret rotation surface** — `GCP_SERVICE_ACCOUNT_JSON` needs the same rotation discipline as the RevenueCat webhook secret. New runbook required alongside `docs/runbooks/gemini-service-account-rotation.md`.
- **New GCP project + billing attachment** — the service account needs a Google Cloud project. Cost stays with the existing Gemini billing account; the GCP project is the administrative unit only.
- **~40 lines of Deno for the signing flow** — RS256 JWT signed via `crypto.subtle`, POSTed to `https://oauth2.googleapis.com/token`. Self-contained, but it's code we own.
- **If the service account is ever compromised**, the blast radius is the Gemini API budget tied to the account. Mitigated via project-level API budget alerts and the one-click revoke in the GCP console.

### Tradeoffs

The rotation-surface cost is small relative to the risk of Option B's timeout-related lifecycle failures. Voice is Premium's single biggest sell; any path that adds unpredictable drop behavior is unacceptable. The +2h provisioning cost is a one-time investment.

## Notes

- Drift findings are in `docs/validation/step-6-cheap-half-drift-check.md`.
- Required IAM role: `roles/aiplatform.user` OR `roles/generativelanguage.admin` (the Generative Language API's role name is under some flux; the ADR will be amended with the exact role name once provisioning confirms it).
- `Authorization: Bearer <access_token>` for **mint**; `Authorization: Token <ephemeral>` or `access_token=<ephemeral>` query param for the **WebSocket** connection itself. Two different auth schemes; do not confuse them.
- CLAUDE.md §Gemini Live sharp-edges #14 and #16 updated in the same commit as this ADR to reflect: (a) path is `/v1alpha/auth_tokens` (snake_case), (b) body is flat camelCase, (c) auth is OAuth Bearer not API-key.
