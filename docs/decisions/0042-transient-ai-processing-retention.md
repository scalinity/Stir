# ADR 0042: Keep brief server processing copies for queued imports and retries

- **Status**: Accepted
- **Date**: 2026-11-06
- **Owner-step**: recipe import and privacy disclosure
- **Related**: SA3-W2, SA3-S1; ADR 0030, ADR 0038; recipe import and idempotency helpers

## Context

Background recipe parsing must finish after the original HTTP request ends. Safe retries and completion retrieval need the already parsed result so the app does not spend quota or invoke the model twice. These are user-content copies even when short-lived; calling the database operational-only without an exception hides the actual storage boundary.

## Decision

Keep saved user content in Core Data / CloudKit. Permit only these server processing copies:

- Queued import text is retained while work is pending/processing, with a ten-minute processing deadline. Admission omits the source URL. Completion/failure removes raw text and any legacy source URL in the same database transaction. Expired unfinished work is failed and scrubbed by the next once-per-minute database cleanup, independently of the Edge dispatcher.
- Parsed AI responses may be replayed or retrieved only within the existing ten-minute response-cache lifetime. A queued import's result lifetime starts at completion. An expired result requires an explicit new attempt; do not extend retention to make silent recovery possible.
- Keep physical cleanup separate from read expiry. The response-cache cron runs every five minutes in batches of 1,000. Backlogs or database outages can retain unreadable rows longer. Queue cleanup normally runs on the next minute tick; an outage can delay it. Do not claim a ten-minute physical erasure guarantee.

Scope result access and idempotency by authenticated canonical identity and request/import ID. Account deletion cascades through queued jobs and cached responses. Do not use these copies for analytics, model training, or a permanent content library. Disclose them in the privacy policy and current architecture documents.

## Alternatives considered

- **Twenty-four-hour parsed-result retrieval** — rejected because the explicit retry flow preserves capability without extending retained content.
- **Remove all response caching** — rejected because network retries would repeat paid work and quota consumption unless a separate durable result mechanism replaced it.
- **Describe transient content as metadata** — rejected because duration does not change the data's content or recipients.

## Consequences

Queued completion and safe network retries remain available with a brief, explicit exception to CloudKit-only content storage. Old results ask for an explicit retry. Logical expiry and scheduled removal have different evidence requirements, and database-outage cleanup needs operational verification.
