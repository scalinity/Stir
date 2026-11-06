# ADR 0041: Direct voice connections and the mint authorization boundary

- **Status**: Accepted
- **Date**: 2026-11-06
- **Owner-step**: standing
- **Related**: ADR 0038, ADR 0010, ADR 0015, ADR 0017, review SA2-C1/C2

## Context

Stir gives the iOS app a short-lived OpenAI Realtime client secret and the app opens its WebSocket directly to OpenAI. OpenAI permits a secret to create multiple sessions before expiry and permits the client connection to override attached configuration. A mint service therefore cannot enforce one upstream connection per quota charge or an immutable output cap.

## Decision

Keep direct iOS-to-OpenAI voice for this personal app. Enforce account eligibility, current paid entitlement, mint rate limits, monthly charged starts and bounded refresh authorization at Stir's mint endpoint. Treat the 120-second secret expiry as a connection window, and the configured 400-token output cap, tools and truncation as the supported client's defaults. These settings are not a security boundary against a modified client.

Quota-free refresh requires an owned, ready predecessor for the same cooking session, a server-recorded original charge, a root start within two hours and a predecessor minted within 65 minutes. Claim one pending successor atomically; a pending mint cannot authorize another refresh. Provider failure aborts the claim and restores the predecessor only if the pending claim still owns the open slot. Legacy ownership rows lack charge proof and cannot authorize an exempt continuation.

## Alternatives considered

- **Server-owned WebSocket relay** — would control connection creation and session updates, but adds a continuously available streaming host, connection lifecycle and network dependency for one local principal. Do not build it in this design.
- **Provider-enforced single-session, immutable client credentials** — use only if the provider adds and verifies that capability; the current client-secret API does not offer it.
- **Shorter expiry as replay protection** — rejected: it shortens the connection window but cannot prevent multiple connections or revoke established sessions.

## Consequences

The standard app retains direct streaming and existing voice capability. Server quotas bound admitted mint operations; they do not bound downstream connections or total upstream spend after a secret is released. Closing a Stir ownership row stops usage-report admission but does not revoke the upstream secret or connection. SA2-C1 is an accepted, documented design boundary, not a repaired single-session security guarantee. Reconsider the connection boundary before exposing these credentials to untrusted principals or if downstream reuse creates a concrete cost problem.

## Sources

[OpenAI client-secret API reference](https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create), checked 2026-11-06: secrets may create multiple sessions until expiry; established sessions may outlive expiry; the client can override attached session configuration.
