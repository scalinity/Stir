# CCPA deletion runbook (legal/compliance side)

**Owner:** Daniel · **SLA:** 30 days from approved request to user confirmation · **Linear:** SCA-214 (parent SCA-58)

The compliance-facing companion to the operational runbooks. Distinguishes:

- `docs/runbooks/ccpa-deletion-workflow.md` — workflow (what the user does, what the admin does)
- `docs/runbooks/deletion-request-fulfillment.md` — fulfillment (what the cron worker does)
- **this file** — legal commitments, SLA tracking, audit-trail verification, user communication templates

Read this before responding to a regulator inquiry, a privacy auditor, or a 30-day-SLA breach incident. The two operational runbooks cover the "how"; this file covers the "what we promise + how we prove it."

---

## Legal commitments (verbatim references)

The product surface that anchors deletion is **Privacy Policy §7 + §7.7 + §6** and **ToS §7**. Every change to deletion behavior must update those documents in lockstep — divergence between policy text and runbook is what regulators look for.

| Commitment | Source | Operative |
|---|---|---|
| 30-day max from approved request to deletion completion | Privacy Policy §7.4 ("within 30 days, subject to operational and legal exceptions") | Cron `stir-deletion-fulfill` runs every 5 min; worst-case row that gets stuck in `failed` is triaged before 30 days |
| In-app submission as primary path | Privacy Policy §7.7 ("In-app (primary): open Stir > Settings > Delete my data") | `Stir/Features/Settings/...` (SCA-61) |
| Email submission as fallback | Privacy Policy §7.7 ("If you cannot use the in-app option, email privacy@getstir.app") | Manual admin row creation; same fulfillment path |
| Subscription auto-renew canceled at submit | Privacy Policy §7.7 ("Subscription auto-renew is canceled automatically") | RevenueCat alias cleanup runs as part of fulfillment |
| Refund management via App Store | Privacy Policy §7.7 ("refunds are managed via the App Store") | We do not initiate refunds |
| Subprocessor forwarding | Privacy Policy §7.7 ("Third-party processors (PostHog, Sentry, RevenueCat): we forward deletion requests to each subprocessor and they process per their own SLA") | Deletion fulfillment includes PostHog `$delete` event, Sentry data-privacy-request POST (currently bulk-issue-delete, GDPR data-privacy-request API migration tracked under SCA-238 v1.1), RevenueCat alias cleanup |
| Operational-and-legal exceptions retained | Privacy Policy §7.4 ("e.g., we may retain transaction records for tax purposes per applicable law") | StoreKit receipts retained per IRS / state tax requirements; not user-deletable |
| Backend retention 30 days for AI request logs | Privacy Policy §6 | `stir-audit-log-retention` cron deletes >30d rows; runs independently of deletion-request worker |

If any commitment above is in flux, **the policy text is authoritative**. Runbook adapts; user-facing copy does not change without lawyer review (SCA-212).

---

## 30-day SLA tracking + escalation

Deletion-request rows have these timestamp columns:

- `created_at` — submission time (in-app or admin-created from email)
- `approved_at` — admin approval (cannot start fulfillment without)
- `completed_at` — terminal success (set by fulfillment worker on `state = 'completed'`)

The 30-day SLA clock starts at `approved_at`, not `created_at`. If admin review takes a week, that's a separate operational issue — but the SLA stops counting until approval lands.

### Daily check (during beta + first month after launch)

```sql
-- Rows approaching SLA breach: approved >25d ago, not yet completed
SELECT id, canonical_user_key_hash, state, approved_at,
       (now() - approved_at) AS age_since_approval,
       external_refs_json
FROM deletion_requests
WHERE state IN ('approved', 'processing', 'failed')
  AND approved_at < now() - interval '25 days'
ORDER BY approved_at ASC;
```

Any row returned needs hands-on triage before day 30. The cron worker re-picks-up `failed` rows on the next tick, but if a row is repeatedly failing the same subsystem step, the cron alone won't resolve it — see operational runbook for the per-subsystem replay procedure.

### Escalation path

1. **Day 25 from `approved_at`**: query above runs daily; any hit gets admin attention same day.
2. **Day 28**: if still not completed, draft + send the user a "fulfillment in progress" email (template below) — keeps the audit trail clean even if SLA slips.
3. **Day 30**: if still not completed, the row is an SLA violation. Document in `audit_log` with `action='deletion_sla_breach'` and `request_id` matching the row. Send the user a notification + apology + ETA. Continue fulfillment but treat as an incident — file a `Sev-2` Linear ticket under Stir for post-mortem.
4. **Regulator inquiry**: pull all `audit_log` rows where `action LIKE 'deletion_%' AND request_id = <id>` — that's the canonical timeline. Combined with `deletion_requests.external_refs_json` for the per-subsystem detail.

---

## Audit-trail verification

Every deletion produces, in this order:

1. `deletion_requests` row state transitions: `pending → approved → processing → completed | failed`. State-change timestamps live in `state_changed_at` (or in `external_refs_json.history` if the schema preserves the change list — verify per the migration ADR).
2. `audit_log` rows for each significant transition (approval, per-subsystem step start, per-subsystem step success/failure, terminal state).
3. PostHog event `deletion_request_submitted` (server-emitted by `users-delete-request`, distinct_id = `canonical_user_key_hash`, per ADR 0027 + `docs/telemetry/canonical-properties.md`).
4. PostHog `$delete` profile-deletion event sent during fulfillment (deletes the user's PostHog history per their privacy commitment).

To verify a single deletion's audit trail end-to-end:

```sql
-- All audit-log rows for this deletion request
SELECT created_at, action, ip_bucket_hash, details_json
FROM audit_log
WHERE request_id = '<deletion_request_id>'
ORDER BY created_at ASC;
```

```sql
-- The deletion request itself + its current state + per-subsystem refs
SELECT id, state, created_at, approved_at, completed_at, external_refs_json
FROM deletion_requests
WHERE id = '<deletion_request_id>';
```

```
# PostHog query (UI or API)
event = 'deletion_request_submitted'
person.distinct_id = '<canonical_user_key_hash>'
```

If any of these three sources is missing data for the request, the audit trail is incomplete. Flag in the post-mortem and trace through the worker logs to find the gap.

---

## User communication templates

### Completion email (terminal success)

> **Subject:** Your Stir data has been deleted
>
> Hi,
>
> This is to confirm that your deletion request submitted on `[YYYY-MM-DD]` has been completed. Your data has been removed from Stir's systems and from each of our subprocessors (PostHog, Sentry, RevenueCat) per the timeline in our Privacy Policy.
>
> Specifically:
> - Your CloudKit data (pantry, saved meals, cook history, voice turns) was removed when you confirmed deletion in the app — that step was on-device and immediate.
> - Your operational records on our backend (entitlements, usage counters, AI request logs, audit log) have been removed.
> - PostHog received a profile-deletion request and processed it on `[YYYY-MM-DD]`.
> - Sentry received a data-privacy request and processed it on `[YYYY-MM-DD]`.
> - RevenueCat alias cleanup completed on `[YYYY-MM-DD]`.
>
> StoreKit receipts (transaction records) are retained per applicable tax law and cannot be deleted. They contain no personally identifying information beyond what Apple already holds for the purchase.
>
> If you have any questions, reply to this email or write to privacy@getstir.app.
>
> Daniel
> Stir

### Partial failure email (some subsystems still pending)

Used when fulfillment is in `failed` state past day 28 — keeps the user informed before the SLA boundary.

> **Subject:** Update on your Stir data deletion request
>
> Hi,
>
> This is to update you on your deletion request submitted on `[YYYY-MM-DD]`. Most of your data has been removed already, but one or more subprocessors are still processing the request:
>
> - `[subsystem]` — `[reason — e.g., "rate-limited; retrying within 24h"]`
>
> We'll send a final confirmation as soon as all subsystems complete. The 30-day SLA in our Privacy Policy still applies; we expect to be within it.
>
> If you have questions, reply to this email or write to privacy@getstir.app.
>
> Daniel
> Stir

### SLA breach email (day 30+)

If the 30-day SLA has been missed, the user gets an apology + status + new ETA. This is incident communication, not routine; tone should match.

> **Subject:** Your Stir data deletion is taking longer than promised — update + apology
>
> Hi,
>
> Our Privacy Policy commits to completing deletion requests within 30 days of approval. Your request submitted on `[YYYY-MM-DD]` has not yet completed end-to-end — I'm sorry about the delay.
>
> Current status:
> - `[completed-subsystems-list]` — done
> - `[pending-subsystem]` — `[specific blocker + ETA]`
>
> I'm working on this directly. You'll get a confirmation email as soon as the remaining subsystem completes. If you'd like more detail, reply here or write to privacy@getstir.app.
>
> Daniel
> Stir

---

## When to update this runbook

- **Subsystem added or removed** (new subprocessor; one removed): update the §"Legal commitments" subprocessor row + the operational runbooks + Privacy Policy §7.7 in the same change.
- **30-day SLA changes** (regulator pressure, lawyer guidance): update Privacy Policy §7.4 first, then this runbook.
- **Audit log schema changes**: update the §"Audit-trail verification" SQL.
- **PostHog identifier changes** (e.g., move from `canonical_user_key_hash` to a different identity field): update the PostHog query in §"Audit-trail verification" + ADR 0027.

Cross-references that must stay in sync:
- `docs/legal/privacy-policy.md` §6, §7.4, §7.7 (commitments)
- `docs/legal/terms-of-service.md` §7 (account termination)
- `docs/runbooks/ccpa-deletion-workflow.md` (workflow)
- `docs/runbooks/deletion-request-fulfillment.md` (fulfillment worker)
- `docs/decisions/0033-deletion-fulfillment-ordering.md` (subsystem ordering)
- `docs/launch/release-gate.md` §8 Legal (the gate row points here)

---

## Provenance

- Linear: SCA-214 (parent SCA-58)
- Step-9 plan Phase 6 Task 6.4
- Pairs with: SCA-61 (in-app surface + endpoint + table + ops admin tab) + SCA-88 (cross-system erase worker)
- Sentry deletion API migration: SCA-238 (v1.1; current path is bulk-issue-delete, target is data-privacy-request)
