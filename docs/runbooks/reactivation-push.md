# Runbook: reactivation push campaign

**Owner:** Daniel. **ADR:** 0026.

## Schedule

- pg_cron `stir-reactivation-scan` fires daily at 18:00 UTC (~10 AM Pacific DST-adjusted).
- Scan SELECTs users with `last_seen_at` between 14 and 21 days ago, active status, non-null push_token, opt-in to reactivation, no reactivation send within last 30 days.
- Each matching user → INSERT into `notification_jobs` kind=push_send, template=reactivation.
- pgmq-dispatch drains the queue via APNs (`_shared/apns.ts::sendAPNsPush`).

## Disable temporarily

```sql
-- Pause the cron job:
SELECT cron.unschedule('stir-reactivation-scan');

-- Re-enable (copy the original schedule from migration 20260423000010):
SELECT cron.schedule('stir-reactivation-scan', '0 18 * * *', $job$
  SELECT public.stir_ops_reactivation_enqueue();
$job$);
```

## Manual send (support case)

To force-enqueue a reactivation push for a specific user (e.g., they reached out asking for recommendations):

```sql
-- Use the same RPC with a 0-day window so that one user qualifies:
-- (don't actually do that globally; instead, single-user:)
INSERT INTO notification_jobs (canonical_user_key, kind, payload_json)
SELECT u.canonical_user_key,
       'push_send'::notification_job_kind,
       jsonb_build_object(
         'template',    'reactivation',
         'title',       'What''s for dinner?',
         'body',        'Support team reached out about your Stir usage — see what tonight''s dinner could be.',
         'deep_link',   'stir://tonight?trigger=reactivation&source=support',
         'apns_token',  di.push_token,
         'environment', di.apns_environment
       )
  FROM app_users u
  JOIN device_installations di USING (canonical_user_key)
 WHERE u.canonical_user_key = 'ck:_<record>'
   AND di.push_token IS NOT NULL;
```

pgmq-dispatch picks it up within 30s.

## Monitoring

- **Open rate:** PostHog — `reactivation_notification_opened` event volume vs send volume (send volume = `notification_jobs` rows inserted with template='reactivation' on the day).
- **Bad tokens:** PostHog / Supabase logs — `pgmq_dispatch.push_token_dead` events indicate the token was invalidated; we auto-null it on `device_installations`.
- **Cron health:** `SELECT * FROM cron.job_run_details WHERE jobname = 'stir-reactivation-scan' ORDER BY start_time DESC LIMIT 10;`

## Copy experimentation

Title + body live in the SQL `stir_ops_reactivation_enqueue()` function. To A/B test:

1. Write migration that splits the function into two branches based on `user_id % 2` (deterministic).
2. Both branches emit `template='reactivation'` but different title/body strings.
3. Tag PostHog events with the branch via the payload (add `variant` key to `data` → iOS forwards on open).

## Opt-out

iOS respects `notification_prefs_json.reactivation = false` via `/v1/push/register`. The enqueue query skips users with that flag. iOS Settings → Notifications toggle updates the pref.

## Edge: duplicate sends

The enqueue RPC has a `NOT EXISTS` clause against `notification_jobs` rows of same template within 30 days. Even if the cron fires twice (manual + scheduled on the same day), the second run is a no-op.
