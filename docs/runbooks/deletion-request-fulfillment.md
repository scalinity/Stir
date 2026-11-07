# Deletion-request fulfillment runbook

**Owner:** Daniel (ops). **Last updated:** 2026-05-08 (SCA-88).

This runbook covers operational handling of CCPA / right-to-delete
fulfillment after a user submits via Settings → Delete my data and an
admin approves the request in the ops console.

Pairs with:
- `Backend/supabase/functions/users-deletion-fulfill/index.ts` (worker)
- `Backend/supabase/migrations/20260508000006_deletion_fulfill_cron.sql` (schedule)
- `docs/decisions/0033-deletion-fulfillment-ordering.md` (subsystem ordering ADR; renumbered from 0031 in SCA-249)
- `docs/legal/privacy-policy.md` §6 + §7.2 + §7.7 (the legal commitments)

## Lifecycle at a glance

```
iOS submit ──► pending ──admin approve──► approved ──cron tick──► processing ──► completed
                                                                              ╲
                                                                               ╲──► failed (re-pickup on next tick OR ops triage)
```

Cron schedule `stir-deletion-fulfill` runs every 5 minutes. Most rows
complete in a single tick; a partial failure preserves
`external_refs_json` so the next tick resumes from the failure point.

## Subsystem walkthrough (ordered)

The worker walks subsystems in this order and writes per-step status to
`deletion_requests.external_refs_json`. Postgres is LAST so the audit
anchor lives on a separate table.

### 1. PostHog person, event and recording deletion

Await `POST /api/projects/{project}/persons/bulk_delete/` with
`distinct_ids: [canonical_user_key_hash]`, `delete_events: true` and
`delete_recordings: true`. Requires `POSTHOG_PERSONAL_API_KEY` with
`person:write`, `POSTHOG_PROJECT_ID`, and an optional allowlisted
`POSTHOG_API_HOST` (`https://us.posthog.com` or `https://eu.posthog.com`).
The public event-capture key cannot authorize this operation.

- **Verify:** a 202 plus empty `deletion_errors` and the requested queue
  flags proves submission only. `submitted_at` records that boundary;
  `requires_manual_action` remains until processor completion is verified.
- **Missing configuration/failure:** retains a stable manual-action reason
  without `completed_at`. The normal Postgres sweep can continue after the
  outstanding check is durably recorded.
- **Operator action:** find `deletion_requests.external_actions_pending`
  or `deletion_requests.fulfilled` in `audit_log` by the hashed target.
  Inspect `after_json.external_refs.posthog`. Use the project's person
  deletion controls and verify completion; do not treat a `$delete_person`
  capture event as erasure. Do not put personal API credentials in notes.
- **API reference:** https://posthog.com/docs/api/persons

### 2. Sentry — bulk issue deletion (NOT full PII erasure — see scope note)

**Scope note (SCA-225):** this step deletes Sentry *issues* matching
the user-hash query. It does NOT expunge user PII from event metadata
in older issues stored before the user-hash tag was attached. Full
GDPR/CCPA "forget me" requires Sentry's Data Privacy Requests flow
(SCA-238 v1.1). For v1 we accept best-effort posture: this call covers
recent issues attributed to the user_hash; remaining PII is workspace-
level data-scrubbing's job, plus the manual UI step below.

Best-effort `DELETE` against
`sentry.io/api/0/projects/{org}/{project}/issues/?query=user.id:{hash}`.
Requires `SENTRY_AUTH_TOKEN` + `SENTRY_ORG_SLUG` + `SENTRY_PROJECT_SLUG`
in the function env.

- **Verify (issue deletion):** Sentry → Issues → search `user.id:<hash>`;
  should return zero matches after fulfillment.
- **Required manual follow-up for full PII erasure:** Sentry → Settings
  → Security & Privacy → "Data Privacy" → submit a "Forget User"
  request for the user_hash. This is the auditor-grade erasure step
  the API call above doesn't perform. Track the manual completion in
  the deletion-request ops log alongside the automated `external_refs`
  state.
- **Without secrets:** worker marks
  `external_refs.sentry.requires_manual_action = true`. Manual fix:
  Sentry workspace owner runs the data-scrubbing UI for that user_id
  hash AND submits the Data Privacy "Forget User" request.
- **Timeout (SCA-224):** AbortError after 8s yields
  `requires_manual_action: true` with `error: 'sentry_timeout_8s'`.
  The postgres sweep still runs; ops can replay later via the
  documented `state='approved'` path.

### 3. RevenueCat alias cleanup

`DELETE /v1/subscribers/{app_user_id}` against the canonical_user_key
(RC alias-forward keeps every prior install id under that subscriber
row). Requires `REVENUECAT_SECRET_API_KEY`.

- **Verify:** RevenueCat → Customers → search the canonical_user_key;
  should return 404.
- **Without secrets:** worker marks
  `external_refs.revenuecat.requires_manual_action = true`. Manual fix:
  RevenueCat dashboard → Customers → delete subscriber.

### 4. Household-scoped Core Data / CloudKit removal

The confirmed client flow removes the exact selected household's child
content after backend request acceptance. A durable local identity/cutoff
marker and empty tombstoned household roots route late imports back through
cleanup. No whole-zone purge or sign-out/forced process exit is used.

- **Verify local:** selected-household content and App Group snapshots are
  absent, session credentials are cleared, and relaunch shows local-deletion
  acknowledgement rather than creating a replacement household.
- **Verify cloud:** a successful export must match the affected persistent
  store and start after the deletion save. Its start and end must be observed
  under the same resolved identity; an account switch or unknown start leaves
  the status pending. The UI labels it as a subsequent
  export; it is not a per-record erase receipt or proof that offline devices
  have synchronized. Late content is removed on merge and invalidates the
  previous export state when further deletion changes are saved.
- **Backend boundary:** `external_refs.cloudkit.requires_client_action` is
  retained because the worker has no authenticated CloudKit completion
  receipt. Local removal never marks this server-side check complete.
- **Start over:** explicit acknowledgement permits a new post-cutoff local
  household without canceling the outstanding backend request. Other iCloud
  accounts' graphs remain separate. ADR 0040 defines the exact boundaries.

### 5. Postgres row sweep (LAST)

Preserves outstanding external actions first in an idempotent
`deletion_requests.external_actions_pending` audit record, then runs
`DELETE FROM app_users WHERE canonical_user_key = $1`. Only after that
delete succeeds does it insert `deletion_requests.fulfilled`. The cascade fans out across:

- `device_installations`
- `entitlement_snapshots`
- `usage_counters`
- `ai_request_log`
- `notification_jobs`
- `deletion_requests` ← itself (so the audit_log row is the surviving anchor)

- **Verify:** `SELECT COUNT(*) FROM app_users WHERE canonical_user_key
  = $1` returns 0; `SELECT * FROM audit_log WHERE action =
  'deletion_requests.fulfilled' AND target_id = $hash` returns the
  fulfillment row with full `external_refs` snapshot in `after_json`.

## Common ops tasks

### Manually trigger a sweep tick

For draining the queue between cron ticks (e.g., after approving a
batch in the ops console):

```sql
SELECT public.stir_deletion_fulfill_trigger_once();
-- returns a pg_net request_id; poll net._http_response for the result.
```

### Inspect a failed row

```sql
SELECT id, canonical_user_key_hash, state, failure_reason,
       external_refs_json
FROM deletion_requests
WHERE state = 'failed'
ORDER BY started_at DESC
LIMIT 10;
```

`external_refs_json` shows which subsystems completed before the
failure; the next sweep tick re-runs only the failed steps.

### Replay a failed row

Flip back to `approved` and let the next tick re-pickup:

```sql
UPDATE deletion_requests
SET state = 'approved', failure_reason = NULL
WHERE id = '<uuid>';
```

The `uq_deletion_requests_in_flight` partial unique index allows this —
the row is non-terminal, so flipping back doesn't violate the
single-in-flight constraint.

### 30-day SLA escalation

Privacy Policy §7.2 commits to a 30-day fulfillment SLA from the user's
submission. Daily ops query for SLA risk:

```sql
SELECT id, canonical_user_key_hash, requested_at, state, failure_reason
FROM deletion_requests
WHERE state IN ('pending', 'approved', 'processing', 'failed')
  AND requested_at < now() - interval '23 days';
```

Anything returned needs urgent attention. Pending = admin hasn't
approved yet. Approved/processing = worker hasn't drained yet.
Failed = repeated subsystem failures, manual fix required.

### Unconfigured external services

In dev / first-deploy, `SENTRY_AUTH_TOKEN` and
`REVENUECAT_SECRET_API_KEY` may be absent. The worker marks each as
`requires_manual_action: true` and continues — the Postgres sweep still
runs, so the privacy-promise minimum is met. Manual catch-up:

1. Set the missing secret: `supabase secrets set ... --project-ref
   ktqajarcomzplnpbczfo`.
2. Sweep the audit_log for completed fulfillments where the affected
   subsystem is marked manual:
   ```sql
   SELECT after_json -> 'external_refs' -> 'sentry'
   FROM audit_log
   WHERE action = 'deletion_requests.fulfilled'
     AND after_json -> 'external_refs' -> 'sentry' ->> 'requires_manual_action' = 'true';
   ```
3. For each, manually erase the user via the Sentry / RevenueCat
   dashboards.

## Telemetry signals

PostHog events:
- `deletion_request_completed` (distinct_id = canonical_user_key_hash)
  — fired after Postgres sweep completes. Properties:
  `had_manual_actions`, `requires_client_action`.
- `deletion_request_failed` (same distinct_id) — fired on subsystem
  blocking error or postgres_sweep_error. Property: `failure_reason`.

A spike in `_failed` over 24h means a subsystem (likely RevenueCat or
Sentry API) is unhealthy — check the dashboards before re-triggering.

Sentry alerts:
- `stir_deletion_request_sla_alert_dispatch()` runs every 15 minutes.
- It emits a Sentry store event when a row remains `approved` for more
  than 24 hours.
- It emits a Sentry store event when a row remains `failed` for more
  than 12 hours.
- Each row/state alerts once; dispatch markers are stored under
  `external_refs_json.alerts`.

## What's NOT in scope (yet)

- Email confirmation that fulfillment completed. Privacy Policy §7.7
  promises an email; deferred until SES/Postmark integration lands.
