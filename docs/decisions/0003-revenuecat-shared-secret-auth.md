# ADR 0003: RevenueCat webhook uses shared-secret `Authorization` header, not HMAC

- **Status**: Accepted
- **Date**: 2026-04-19
- **Owner-step**: Step 5 (billing + paywall)
- **Related**: `Backend/supabase/functions/_shared/revenuecat.ts` `verifyAuthHeader`, `Backend/supabase/functions/revenuecat-webhook/index.ts`, CLAUDE.md §"Never present anywhere"

## Context

The step-5 implementation plan originally called for HMAC-SHA256 body signing via an `X-RevenueCat-Signature` header, modeled on the pattern most other SaaS webhooks use. On actually consulting the RevenueCat dashboard, RC's model is different: the operator enters a single shared secret into the dashboard, and RC sends it verbatim in the `Authorization` header on every delivery. There is no HMAC, no timestamp signing, no replay protection built in.

## Decision

Match RC's actual protocol. The webhook handler validates the `Authorization` header against `REVENUECAT_WEBHOOK_SECRET` (env var) using a constant-time byte compare. Accept either `Authorization: <secret>` or `Authorization: Bearer <secret>` so RC dashboard config variants don't cause operational drift.

## Alternatives considered

- **HMAC-SHA256 of raw body** — would be our preference but not supported by RC's delivery pipeline.
- **Proxy through our own webhook signer** — rejected: adds a hop (another service we own and have to keep running) to gain protection RC itself doesn't have. Doesn't mitigate the actual threat (secret compromise).
- **Rely on Supabase platform-layer auth (`verify_jwt = true`)** — rejected: Kong expects `Bearer <JWT>`. RC doesn't speak that shape. Would reject every valid delivery before our handler runs.

## Consequences

### Positive

- Matches RC's actual API; zero glue code.
- Constant-time compare correctly defends against timing oracles (CWE-208).
- `Bearer` prefix normalization means dashboard config changes don't cause auth churn.

### Negative

- An attacker who compromises `REVENUECAT_WEBHOOK_SECRET` can forge any entitlement mutation. Same threat model as RC itself.
- No body signing means an attacker with the secret can replay old events with modified `event.id`.
- No built-in freshness check — ADR 0006 (to be written) adds a 5-minute replay window on `event_timestamp_ms` as defense-in-depth.

### Tradeoffs

- Accept RC's security posture in exchange for not owning a custom auth bridge. Layer secondary defenses (idempotency, replay-window, size cap, Zod validation, canonical-key regex) to narrow the blast radius of a secret leak.

## Notes

- Secret length floor: 32 chars (raised from 16 in step-5 review). `openssl rand -hex 32` produces a safe value.
- Rotation runbook lives at `docs/runbooks/revenuecat-webhook-secret-rotation.md`.
- If RC ever adds HMAC support, migration is a one-file change in `_shared/revenuecat.ts:verifyAuthHeader` — document the new signature alongside the existing shared-secret path, then deprecate.
