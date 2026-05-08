# ADR 0031: Deletion fulfillment subsystem ordering — Postgres sweep last

- **Status**: Accepted
- **Date**: 2026-05-08
- **Owner-step**: Pre-public-launch (SCA-88)
- **Related**: SCA-61 (in-app surface, ops admin tab), SCA-88 (this worker), `docs/runbooks/deletion-request-fulfillment.md`, `Backend/supabase/migrations/20260508000002_init_deletion_requests.sql`, ADR 0027 (canonical_user_key_hash audit anchor)

## Context

SCA-61 shipped the in-app right-to-delete surface and the ops admin
approve flow. Approval lands an `approved` row in `deletion_requests`
but no automated fulfillment — the actual cross-system erase was
runbook-only. Privacy Policy §7.2 commits to a 30-day SLA, which
puts the manual approach on a clock.

The fulfillment worker (SCA-88) walks five subsystems:
1. PostHog identify-merge
2. Sentry user erase
3. RevenueCat alias cleanup
4. CloudKit zone-delete trigger
5. Postgres row sweep

The order is load-bearing. Two options were live during design:

- **Option A** — Postgres FIRST. Wipe operational data immediately;
  treat external services as best-effort cleanup. Pro: minimum-window
  privacy-promise compliance. Con: deletes the row that holds the
  user's canonical_user_key, so the worker has no key to use against
  PostHog / Sentry / RevenueCat for the rest of the chain.
- **Option B** — Postgres LAST. Run external-service cleanup first
  while the user's identity is still resolvable, then sweep Postgres.
  Pro: every external step has the canonical_user_key to address.
  Con: a CloudKit-trigger or RevenueCat failure mid-chain leaves
  operational data in place; user's data lives on slightly longer.

## Decision

**Postgres sweep runs LAST.** Plus a key sub-decision (revised 2026-05-08
under SCA-222): the worker inserts the durable `audit_log` row AFTER
the `DELETE FROM app_users` succeeds, not before. Originally we
inserted the audit row first because the cascade was about to delete
`deletion_requests` and we wanted a surviving anchor — but that
ordering had two reachable bugs (the audit row outliving a failed
DELETE; duplicate audit rows on retry). Inserting after success means:
- Failed deletions leave NO audit row (the `deletion_requests.failed`
  row is the only record).
- Retries can't produce duplicates.
- `audit_log.actor_id ON DELETE SET NULL` already keeps the audit row
  alive across the cascade — there's no "anchor must exist before
  cascade" constraint that justified the earlier ordering.

The trade-off is intentional: Option A's "external services run with
no canonical key" is a worse failure mode than Option B's "operational
data persists for one retry tick." If RevenueCat is unreachable,
Option B preserves the canonical key for the next sweep; Option A
loses the only retry handle.

**Pre-step on app_users.merged_into RESTRICT (SCA-222):**
`app_users.merged_into REFERENCES app_users(canonical_user_key) ON
DELETE RESTRICT`. Any user who absorbed a CloudKit alias-merge has
inbound `merged_into` rows pointing at their canonical_user_key.
Without intervention the DELETE raises 23503. Worker pre-NULLs those
inbound refs in the same step before issuing DELETE — the merged_into
chain is a forward alias and the dangling alias rows have nothing
useful to point to once the canonical row is gone.

## Why CloudKit can't be server-side

Apple's CloudKit Web Services API exposes only the public DB.
Private-DB writes are unreachable from any server-side context — the
keys live in the user's iCloud account and are addressable only by
code running in the user's app process. We mark
`external_refs.cloudkit.requires_client_action=true`; iOS sees this on
next launch and triggers `CKContainer.privateCloudDatabase
.deleteRecordZone(zoneID)`.

If the user never relaunches, their CloudKit data persists. Privacy
Policy §6 documents this asymmetry. CloudKit data is the user's own
iCloud, not Stir-controlled — the same boundary that lets a user
delete a Stir-saved recipe by signing out of iCloud entirely.

## Why audit_log lives on a separate table

`deletion_requests.canonical_user_key REFERENCES app_users(canonical_user_key) ON DELETE CASCADE`.
When the Postgres sweep runs `DELETE FROM app_users`, the cascade
deletes the deletion_requests row too. The "completed" state never
lands on the row — it's wiped a millisecond later.

The audit_log table has `actor_id REFERENCES auth.users(id) ON DELETE
SET NULL` (not CASCADE) — it survives the user's deletion as a
durable record. We insert the audit row **after** the DELETE succeeds
(SCA-222 — see Decision section above for why), keyed on the
canonical_user_key_hash anchor:

```
audit_log row:
  action       = 'deletion_requests.fulfilled'
  target_table = 'app_users'
  target_id    = canonical_user_key_hash    -- ADR 0027 anchor
  before_json  = { canonical_user_key_hash }
  after_json   = { deletion_request_id, external_refs }
```

This means a completed deletion has TWO records:
- `audit_log` row — durable, queryable by hash forever.
- `deletion_requests` row — gone (cascade).

Failed deletions have ONLY the `deletion_requests` row, in the
`failed` state. The audit_log row is only written on the success
path. (Earlier draft had the audit insert BEFORE the DELETE; that
introduced two reachable bugs — audit row outliving a failed
DELETE, plus duplicate audit rows on the documented ops replay
path. Revised under SCA-222.)

## Resume semantics

`external_refs_json` records per-subsystem state across retries. A
subsystem that completed in tick N skips on tick N+1; only failed or
not-yet-attempted subsystems run on retry.

This is why each subsystem function checks for `completed_at` (or
`requires_client_action` for CloudKit, `requires_manual_action` for
secret-gated subsystems) at the top of the function and short-circuits
if present.

The persisted `external_refs_json` update happens BEFORE the Postgres
sweep. If the sweep itself fails, the row flips back to `failed` with
the full subsystem state preserved — next sweep tick resumes only the
failed step.

## Sentry erasure scope limitation (SCA-225)

`stepSentry` calls Sentry's bulk-issue-delete endpoint:
`DELETE /api/0/projects/{org}/{project}/issues/?query=user.id:{hash}`.
That deletes Issue rows attributed to the user-hash query but does
NOT expunge user PII from event metadata in older issues stored
before the user-hash tag was attached. Full GDPR/CCPA "forget me"
requires Sentry's `POST /api/0/organizations/{org}/data-privacy-requests/`
flow (async, polling).

For v1 we accept best-effort posture:
- The bulk-issue-delete call covers the recent attribution window.
- Workspace-level data-scrubbing handles existing PII in retained
  event metadata.
- The runbook documents a manual Data Privacy UI follow-up step
  the operator runs alongside the automated call.

Tracked as v1.1 follow-up in SCA-238: switch to the data-privacy-
requests API (async-polling shape, request_id stored in
`external_refs.sentry.privacy_request_id`).

Reviewed and accepted under SCA-225 (corroborated W1 finding from the
post-launch /review-2 pass).

## Alternatives considered

- **Single transaction across all subsystems** — Rejected. PostHog,
  Sentry, RevenueCat, and CloudKit are external HTTP services with no
  transaction semantics. A failure mid-chain can't be atomically
  rolled back.

- **Decouple via pgmq queue with one job per subsystem** — Rejected
  for v1 complexity. The current single-row state machine is easier to
  reason about: one row, one status, partial state in JSON. Revisit if
  per-subsystem retry intervals diverge sharply.

- **Block on missing external secrets** — Rejected. Privacy Policy
  §7.2 commits to a 30-day SLA. If RevenueCat's API key is rotated and
  the new value hasn't landed in Edge Function secrets, blocking the
  whole deletion compounds the SLA risk. Instead: mark
  `requires_manual_action`, run Postgres sweep (privacy-promise
  minimum), surface the manual catch-up in the runbook.

## Consequences

**Positive:**
- 30-day SLA achievable without manual ops work for the happy path.
- audit_log row survives the cascade, so deletions remain queryable
  for compliance audits.
- Resume-from-failure preserves work; ops triage time bounded.

**Negative:**
- Postgres data lives slightly longer than Option A would allow (one
  retry tick = 5 min). Acceptable: 5 min vs 30-day SLA is noise.
- CloudKit asymmetry — user's private DB persists until they relaunch
  the app. Documented in Privacy Policy §6 as known.

## Triggers to revisit

- 30-day SLA missed by an automated row (not just an admin-approve
  delay) → reconsider the sweep cadence (5 min may be too coarse, or
  worker may be silently failing).
- A new subsystem joins (e.g., Slack integration for ops alerts, or a
  new third-party billing partner) — reorder if the new subsystem's
  failure mode pushes Postgres sweep ordering.
- CloudKit Web Services API gains private-DB-delete capability →
  remove the requires_client_action path, run server-side.
