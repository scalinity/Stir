# CCPA Deletion Workflow Runbook

**Owner:** Daniel (solo until ops scales)
**SLA:** 30-day max from request to deletion confirmation
**Trigger:** User submits in-app or email deletion request

This runbook covers the operational flow for honoring CCPA deletion requests, per Privacy Policy §7 + spec §11 + ToS §7. Tested end-to-end before beta opens to external testers.

---

## User-facing entry points

### In-app (primary path)
1. Settings > Privacy > Delete my data
2. iOS confirms via standard alert: "Permanently delete all your data?"
3. On confirm, iOS calls `POST /v1/ops/admin/users/delete-request` (Daniel: this endpoint to be added in Phase 3.5 or v1.1; alternative path: in-app submits via email if not yet wired)

### Email (fallback)
- privacy@getstir.app
- Body: user references their canonical_user_key (printed in Settings > About) OR their Apple ID email

---

## Process

### 1. Request received

**In-app path:**
- Backend creates a `deletion_requests` row with `status='pending'`
- Email confirmation sent to the user's registered email (if available via StoreKit receipt)
- APNs push: "Deletion request received. Your data will be removed within 30 days."

**Email path:**
- Daniel manually creates a `deletion_requests` row via ops console (or direct SQL until ops console handles it)
- Replies to the user confirming receipt + stating 30-day SLA

### 2. Admin review (within 5 business days)

1. Open ops console > Users > [user] > Deletion Requests tab
2. Cross-check the request:
   - If from email: confirm Apple ID matches a known canonical_user_key
   - If from in-app: identity is implicit (request was authenticated)
   - Any anomaly (mismatch, suspected impersonation): contact user directly, halt deletion
3. Click "Approve deletion"

### 3. Backend executes deletion

The approval enqueues a deletion job (via pgmq) that processes each subprocessor:

#### CloudKit (user content)

iOS app handles this side: when the user installs and signs in to iCloud after a deletion approval, the app marks their local Core Data store for cascade-delete to CloudKit. CloudKit propagates the deletion across user's devices.

If the user has uninstalled before deletion: their CloudKit container persists until their iCloud account itself is deleted by Apple (out of our control). Privacy Policy §7.2 acknowledges this limitation.

#### Supabase (operational backend)

Hard-delete from all ops tables keyed on `canonical_user_key`:
- `app_users`: HARD-DELETE per CCPA (do NOT use `status='merged'` or `status='banned'` — those are audit trails for non-deleted users)
- `device_installations`
- `entitlement_snapshots`
- `usage_counters`
- `ai_request_log`
- `notification_jobs`
- `voice_session_owners`
- `voice_turn_usage`
- `audit_log` rows authored by this user (admin-action audit_log entries about this user are retained — they're admin records, not user data)
- `ops_flagged_outputs` rows submitted by this user

Verify with:
```sql
SELECT 'app_users' AS tbl, COUNT(*) FROM app_users WHERE canonical_user_key = $1
UNION ALL SELECT 'device_installations', COUNT(*) FROM device_installations WHERE canonical_user_key = $1
UNION ALL SELECT 'entitlement_snapshots', COUNT(*) FROM entitlement_snapshots WHERE canonical_user_key = $1
UNION ALL SELECT 'usage_counters', COUNT(*) FROM usage_counters WHERE canonical_user_key = $1
UNION ALL SELECT 'ai_request_log', COUNT(*) FROM ai_request_log WHERE canonical_user_key = $1
-- etc.
```

Expected return: 0 across all rows after deletion.

#### PostHog

API call: `POST /api/projects/{project_id}/persons/delete_async/?distinct_ids=<canonical_user_key>`

PostHog processes asynchronously; verification via dashboard within 14 days.

#### Sentry

API call: `DELETE /api/0/users/{user_id}/` — but Sentry doesn't store our `canonical_user_key` in user form. Instead, we delete events with `user.id == canonical_user_key` via Sentry's "Data Deletion" workflow (settings.sentry.io > Privacy > User Data Erasure).

#### RevenueCat

Subscription history must be retained for tax purposes (Apple's billing records are the controlling document, not RevenueCat's). RevenueCat Customer Center supports "delete user" which:
- Removes the user from RevenueCat's product analytics
- Retains anonymized purchase records for billing reconciliation
- Disconnects the user's identifier from PII

API: `DELETE /v1/subscribers/{app_user_id}` from the RevenueCat REST API.

#### Apple CloudKit, APNs, StoreKit

Apple handles their own data on its standard schedule (governed by Apple's privacy policy, not Stir's). We notify Apple via APNs token deactivation:
- Backend stops sending pushes to the deleted canonical_user_key's tokens
- Apple eventually expires the tokens

### 4. Status tracking

Each deletion job has a status column updated as work completes:
- `cloudkit_acknowledged` (we can't directly verify; user-acknowledged)
- `supabase_deleted`
- `posthog_marked_for_deletion`
- `sentry_marked_for_deletion`
- `revenuecat_deleted`
- `apns_tokens_deactivated`

Final state: `completed` with `deleted_at` timestamp.

### 5. Confirmation

Email to the user (within 30 days):

```
Subject: Your Stir data has been deleted

Hi,

Per your CCPA deletion request, we have removed your Stir data:

✓ App data (cooking sessions, saved recipes, preferences) on your iCloud account
✓ Operational data on Stir's servers (quota counters, AI request logs, push tokens)
✓ Analytics data (PostHog interaction events)
✓ Crash reports (Sentry)
✓ Subscription account on RevenueCat (subscription history retained for tax purposes per applicable law)

Some items take a few extra days to fully propagate:
- iCloud changes propagate when you next sign in on a device
- Analytics partner deletion completes within 14 days
- Sentry deletion completes within 14 days

If you have any questions, reply to this email or contact privacy@getstir.app.

— The Stir team
```

---

## Subprocessor failure handling

If any subprocessor deletion fails:

| Subprocessor | Retry strategy |
|---|---|
| Supabase (in-house) | Retry every 24h; alert Daniel if fails 3 times |
| PostHog | Retry every 48h; if API returns 4xx (e.g., user already deleted), mark as success |
| Sentry | Retry every 48h; if API returns 4xx, mark as success |
| RevenueCat | Retry every 48h; escalate to support@revenuecat.com if persistent |
| CloudKit | Cannot be directly retried — depends on user's device action; mark as `acknowledged` after notification email |
| Apple APNs | Token deactivation is fire-and-forget; mark as success on backend confirmation |

After 30 days, if any subprocessor still pending: send the user a status update with details and an apology, retry indefinitely.

---

## Audit log entries

Every deletion event is logged to `audit_log` for compliance review:

```sql
INSERT INTO audit_log (operation, target, performed_by, request_id, fields)
VALUES ('ccpa_deletion', 'canonical_user_key:<key>', '<admin_user_id>', '<deletion_request_id>',
  '{"approved_at": "<iso>", "completed_at": "<iso>", "subprocessors_completed": [...]}');
```

`audit_log` rows about this user are RETAINED post-deletion (admin-action records are not user data — they're admin records of administrative actions).

---

## Pre-beta end-to-end test (must complete before external beta opens)

1. Create a throwaway Apple ID (not Daniel's primary)
2. Sign in to TestFlight with that Apple ID
3. Sign in to iCloud on a test device
4. Use Stir for a 15-minute session: 3 solves, 1 cook session, 1 saved favorite, 1 grocery export
5. Submit deletion request via Settings > Privacy > Delete my data
6. Verify:
   - Email confirmation arrives
   - APNs push arrives
   - Approving in ops console enqueues deletion
   - All Supabase tables show 0 rows for that canonical_user_key within 24h
   - PostHog persons API returns 200 for the delete request
   - Sentry shows the user marked for deletion in the Data Erasure dashboard
   - Re-signing in to the throwaway Apple ID 24h later: app behaves like a fresh install

Document the test in `docs/qa/ccpa-deletion-test-results.md`.

---

## Runbook maintenance

Re-review when:
- A new subprocessor is added
- A subprocessor changes their deletion API
- A new data category is collected (verify deletion path covers it)
- CCPA / CPRA / other applicable law changes

---

## Internal cross-references

- Spec §11 — Data Lifecycle, retention table
- Spec §19 — Legal & Regulatory Checklist
- `docs/legal/privacy-policy.md` §7 (user-facing)
- `docs/legal/terms-of-service.md` §7 (user-facing)
- `docs/appstore/app-privacy-details.md` (subprocessor list)
