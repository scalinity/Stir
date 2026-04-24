# ADR 0026: Reactivation push schedule — APNs, daily 18:00 UTC (~10 AM Pacific DST-adjusted), 14–21 day inactivity window, 30-day dedup (supersedes spec §8 Habit window row)

- **Status**: Accepted
- **Date**: 2026-04-24
- **Owner-step**: Step 8 Phase 4
- **Related**: Spec §8 Engagement & Reactivation (amended in same commit as this ADR); `_shared/apns.ts`; `stir_ops_reactivation_enqueue` RPC; pg_cron job `stir-reactivation-scan`; `device_installations.notification_prefs_json.reactivation`

## Context

Spec §8 row "Habit window reactivation" specifies:

> **Trigger:** user skipped their expected cook night (last cooked 7 days ago on a Tue/Wed/Thu).
> **Channel:** local notification.
> **Copy:** "Still wondering about dinner? Three quick options for tonight."
> **Cap:** 1/week.
> **CTA:** Open Stir.
> **Opt-out:** Settings → Notifications.

Three gaps between that spec row and what step 8 can actually ship:

1. **"Last cooked 7 days ago on Tue/Wed/Thu"** requires a historical cook-night signal we don't have. Cook sessions are CloudKit-private; Supabase has `last_seen_at` (any-app-open signal, not cook-specific). Inferring a user's "expected cook night" requires a minimum of 4 weeks of observed cook sessions in operational storage — we have zero production users today.
2. **"Local notification"** requires iOS to own the trigger timing. Local notifications scheduled via `UNUserNotificationCenter` die when the app is killed or the device reboots; they're unreliable for a 7-day-ahead reminder.
3. **No step-1-through-7 infra for push-at-scale:** no APNs signing, no batched enqueue, no preference respect, no observability.

Step 8 ships the operational layer. Picking "right" reactivation reminder timing for Stir-the-product requires real user behavior data that doesn't exist yet.

## Decision

**Step 8 ships a pragmatic v1** that breaks fidelity with spec §8 on three axes, knowingly:

| Dimension | Spec §8 | Step 8 v1 |
| --- | --- | --- |
| Trigger | "7 days since last cook on Tue/Wed/Thu" | `last_seen_at BETWEEN 14 AND 21 days ago` (any day) |
| Channel | Local notification | APNs remote push (signed server-side) |
| Copy | "Still wondering about dinner? Three quick options for tonight." | "What's for dinner? Haven't cooked in a while? See what tonight's dinner could be." |
| Cap | 1/week | 1/30-days (dedup on same template) |
| Timing | Per-user cook-night based | Daily 18:00 UTC scan (~10 AM Pacific DST-adjusted) |

### Implementation

- pg_cron `stir-reactivation-scan` fires daily at 18:00 UTC → calls `stir_ops_reactivation_enqueue()` RPC.
- RPC SELECTs users with `last_seen_at BETWEEN now() - interval '21 days' AND now() - interval '14 days'`, `status='active'`, `push_token IS NOT NULL`, `notification_prefs_json->>'reactivation' = true` (default true per migration `20260419000018`), AND no `notification_jobs` row of kind='push_send' + template='reactivation' within the last 30 days.
- Each matching row → INSERT notification_jobs row with kind=push_send + payload template='reactivation' + deep_link='stir://tonight?trigger=reactivation'.
- pgmq-dispatch consumes the queue → `_shared/apns.ts::sendAPNsPush()` → HTTP/2 POST to APNs.
- iOS handles deep link via `PushDeepLinkRouter` (step 9): navigates to Tonight Home with welcome banner + emits `reactivation_notification_opened` event for the voice_conversion_event funnel (spec §15).

### Spec §8 amendment (same commit as this ADR)

The Habit window row is replaced with a row matching the v1 shape above. The original row is preserved in this ADR as historical context.

## Alternatives considered

- **Ship exactly per spec §8** — blocked on missing historical cook-night signal. To implement would require shipping the telemetry pipeline first, waiting 4+ weeks to accumulate data, THEN running the trigger. Step 8 ships the operational layer; building a product-level observation layer alongside would extend the step by weeks.
- **Don't ship any reactivation in step 8** — leaves retention-loop telemetry empty for the beta. Spec §8 lists reactivation as a required surface for engagement measurement.
- **Use local notifications** — unreliable for 14-day-ahead (dead app, device reboot, low-power mode). APNs is the production-grade channel.
- **Per-user timezone** — would require capturing + storing user TZ. iOS sends locale on bootstrap but not TZ offset reliably. Step 9+ enhancement.

## Consequences

### Positive
- Reactivation loop is LIVE in step 8. `reactivation_notification_opened` event starts emitting as soon as the first push lands, giving us behavioral data for step-9 tuning.
- APNs path exercises the full backend push pipeline (`_shared/apns.ts` + pgmq-dispatch push_send handler), surfacing bugs before trial reminders + import completion pushes land on the same pipeline.
- Dedup key (template + 30-day window) guarantees no user gets more than 1 reactivation push per month even if the cron runs duplicate ticks.

### Negative
- Users in any time zone get a push at a time that might be wrong for them — 18:00 UTC is 3 AM Wellington NZ, 10 AM Los Angeles PT (DST). US launch constraint (spec §22 English / US-only) mitigates the worst case.
- Any-day trigger means a user who's been active but hasn't cooked still gets a reactivation push after 14 days of "last_seen_at" drift. Copy is generic enough ("What's for dinner?") that it doesn't read as false-positive to a regularly-engaged non-cooker.

### Tradeoffs
- We accept fidelity loss against spec §8 to ship a working retention loop early. When we have 4+ weeks of user data in step 9+, revisit whether a cook-night-based trigger would measurably lift opens without losing coverage.

## Trigger to revisit

- Step 9+ when operational storage has 4+ weeks of `cook_session_completed` events — re-evaluate whether cook-night-based triggering outperforms the flat 14–21d window.
- Daily open-rate < 3% on the reactivation category for 2 consecutive weeks — either the copy is wrong or the window is. Adjust one.
- User complaints cross 2 in a single beta-test week about "I got a push when I wasn't inactive" — bug or scheduling mismatch.

## Notes

- APNs provider token is ES256 over `APNS_AUTH_KEY_P8`, cached 30 min per Edge-Function worker. See `_shared/apns.ts`.
- iOS deep link `stir://tonight?trigger=reactivation` is consumed by `PushDeepLinkRouter` (step 9). Parameters other than `trigger` ignored in v1.
- `notification_jobs.payload_json` shape: `{ template, title, body, deep_link, apns_token, environment }`. `apns_token` is null-able only for scheduled jobs that haven't been populated yet (not used in reactivation path — enqueue already has the token).
- Failure modes handled: `bad_device_token` (null out push_token + mark job completed), `rate_limited` / `server_error` (retry w/ exponential backoff), `config_invalid` (page oncall + retry exhaust).
- Single-send guarantee: the 30-day NOT EXISTS clause is evaluated at INSERT time, so even concurrent cron ticks can't insert two rows. The `notification_jobs` table doesn't have a uniqueness constraint on the tuple (canonical_user_key, template, created_at) because the NOT EXISTS gate is sufficient.
