# ADR 0040: Remove the selected household locally and track cloud export separately

- **Status**: Accepted
- **Date**: 2026-11-06
- **Owner-step**: privacy deletion
- **Related**: SA3-C1, SA3-W1, SA3-W4; ADR 0033; ADR 0039

## Context

The backend cannot confirm deletion of the app's private CloudKit graph. A server-only marker does not erase local content, and deleting a whole persistent store or CloudKit zone could remove another account's rows on the same device. The confirmed in-app flow already authenticates the exact selected household and can remove it immediately.

## Decision

After the backend accepts the authenticated deletion request, save a durable local marker for the exact canonical identity before removing content. Delete every child graph of that identity's household roots through normal Core Data changes. Keep empty roots with `deletedAt` set so children delivered later by CloudKit retain their identity link and can also be erased. Clear local preferences on those roots, App Group snapshots and pending shares, session JWTs and cached entitlements. Reload widget timelines and remove this app's pending/delivered notifications so stale meal/pantry text is not retained there. Retain the installation identity because it identifies the outstanding backend request; do not rotate it to bypass that request.

On launch and after main-context merges, reapply the marker to roots created no later than its cutoff. Stop bootstrap from recreating a household until the local result is acknowledged. An explicit Start over action allows a new household created after the cutoff and does not cancel the outstanding backend request. Distinct iCloud accounts remain separate.

Report local save and cloud export as separate states. A successful CloudKit export must match the affected store, start after the local deletion save, and have its start and end observed under the same resolved canonical identity. Unknown starts and account changes keep the result pending. This reports that export, not a per-record server erase receipt or deletion on every offline device. A late import resets the export state when further deletion changes are saved. Never purge a whole zone or present queue acceptance as complete cloud deletion.

Submit PostHog person/event/recording deletion through its authenticated API and await the result. HTTP 202 means queued. Missing configuration, failure and unverified completion retain a manual action. Before a Postgres sweep can remove the request row, retain outstanding external actions in the existing audit table with the request UUID as an idempotent insert key. This record says actions are pending; it never claims fulfillment. A separate fulfilled record is written only after the Postgres delete succeeds. Failed pending-record persistence blocks the sweep so its retry handle survives.

Call the existing completed-import 30-day purge at household selection and foreground, scoped to the current household. A failed save retries at the next call; no successful-maintenance timestamp suppresses retry.

## Alternatives considered

- **Whole-zone or whole-store deletion** — rejected because a zone/store is broader than the authenticated household and can contain another account's local rows.
- **Wait for a backend marker after fulfillment** — rejected because fulfillment deletes the request row and the app has no durable authenticated delivery channel for that marker.
- **Delete roots immediately** — rejected because late children would lose their household identity link.

## Consequences

The confirmed action buys immediate local removal and eventual normal CloudKit propagation without waiting for an administrator. Small identity/deletion anchors and the local cutoff marker remain deliberately; they prevent old content from reappearing. Local tests can verify scoping, retries and merge handling. Real CloudKit export, offline-device propagation and processor completion require separate acceptance evidence.
