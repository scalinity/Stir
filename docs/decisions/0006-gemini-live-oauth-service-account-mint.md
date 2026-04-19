# ADR 0006: Gemini Live ephemeral-token mint uses OAuth service-account auth, not API-key auth

- **Status**: Rejected
- **Date**: 2026-04-19
- **Owner-step**: Step 6 (Cook Mode voice)
- **Rejected on**: 2026-04-19 (same day — within hours of "Accepted")
- **Supersedes**: nothing
- **Superseded by**: API-key mint (same `GEMINI_API_KEY`) once sharp-edges #17 (paid-tier billing) and #18 (legacy `AIzaSy…` key format) are satisfied. See CLAUDE.md §Gemini Live sharp-edges.
- **Related**: `docs/validation/step-6-cheap-half-drift-check.md` · CLAUDE.md §Gemini Live sharp-edges #14, #16, #17, #18

## Why this ADR is kept

Per the decisions-system rules (README §Statuses): rejected ADRs stay in the tree so the same idea doesn't cycle back unexamined. If a future Claude or engineer re-discovers that API-key mint returns 400, they'll find this ADR before spending a day building an OAuth path a second time.

## What we thought the problem was

Empirical probes from the Supabase Edge Function environment observed `POST /v1alpha/auth_tokens` returning opaque `400 INVALID_ARGUMENT` with API-key auth across every request-body shape (empty, minimal, full camelCase, wrapped in `authToken`). Every other Gemini endpoint accepted the same key. We concluded the mint endpoint specifically rejected API-key auth and that the fix was server-side OAuth via a Google Cloud service account.

## Why that conclusion was wrong

Same-day continued diagnosis revealed two orthogonal gates that together produced the opaque 400:

1. **Paid-tier billing** on the GCP project owning the API key was not enabled. `generateContent` and `models.list` work on free tier; `auth_tokens` does not. No billing-specific error is returned — just `INVALID_ARGUMENT`. (CLAUDE.md sharp-edge #17.)
2. **API key format**. The key in use was the new AI Studio default (`AQ.xxx`, 53 chars). The `auth_tokens` endpoint specifically rejects these with `400 INVALID_ARGUMENT`. Legacy-format keys (`AIzaSy…`, 39 chars) work. `generateContent` accepts both formats, which masked the issue. Google is aware (forum thread 141133); no fix timeline. (CLAUDE.md sharp-edge #18.)

Once both were fixed, API-key mint via the same `GEMINI_API_KEY` used elsewhere returned a real ephemeral token in ~250 ms, and a full voice round-trip via WebSocket completed at 568 ms TTFA.

## Decision (original)

Use OAuth service-account auth for mint. Provision a GCP service account with `aiplatform.user`, download JSON, store as `GCP_SERVICE_ACCOUNT_JSON` in Supabase secrets. Exchange JWT for OAuth access token at mint time; cache in memory with TTL-skew.

## What was actually built and then removed

- `Backend/supabase/functions/_shared/google_oauth.ts` (JWT signing + token exchange + in-memory cache) — written, tested (7 green unit tests), then deleted.
- `Backend/supabase/tests/google_oauth_test.ts` — deleted.
- `docs/runbooks/gemini-service-account-provisioning.md` — deleted.
- `CLAUDE.md §env vars` — `GCP_SERVICE_ACCOUNT_JSON` line reverted.
- GCP service account `stir-live-mint@stir-ai-dinner-copilot.iam.gserviceaccount.com` — retained for now (harmless; zero-cost if unused) but should be deleted along with its IAM binding in a cleanup pass. Optional follow-up for Daniel.

## Lesson worth keeping

When a Google API returns `INVALID_ARGUMENT` without a `details` field, the rejection is happening *before* request-body parse. Auth / billing / project-gate issues surface with the same error code and message as a malformed-body error. Before assuming wire-shape drift, verify the pre-body gates.

Sharp-edges #17 (billing) and #18 (key format) are the specific manifestations of this rule for Gemini Live.

## Notes

- The OAuth code path worked correctly in isolation (7/7 unit tests passed, including a real RSA sign/verify round-trip against a locally-generated service-account key). Rejection is about necessity, not correctness.
- If Google ever changes the mint endpoint to reject API keys categorically, this ADR's context + the rejected code path remain a starting point. Re-activate by restoring from this commit's predecessor (e2c5c98).
