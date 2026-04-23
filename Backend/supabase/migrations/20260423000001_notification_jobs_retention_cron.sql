-- Retention sweep for notification_jobs — 7-day delete after terminal state.
--
-- Why: notification_jobs.payload_json holds the raw extracted recipe text
-- (URL-fetched HTML, paste, OCR output — up to ~2 MiB) for the async
-- recipe-import dispatcher. Without retention, that user content sits in
-- operational Postgres indefinitely, violating the CLAUDE.md north-star
-- "user content lives in CloudKit, not Supabase." 7 days matches the
-- async-import UX SLA — jobs that haven't completed in a week are
-- unrecoverable and can be dropped.
--
-- Mirrors ai_response_cache's pg_cron pattern (20260418000014). Idempotent
-- re-schedule via the unschedule-then-schedule dance so re-running this
-- migration doesn't duplicate the job.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-cleanup-notification-jobs') THEN
    PERFORM cron.unschedule('stir-cleanup-notification-jobs');
  END IF;

  -- Hourly. Cheap — batch DELETE with ctid subquery so the plan can use
  -- the state + processed_at partial index.
  PERFORM cron.schedule(
    'stir-cleanup-notification-jobs',
    '17 * * * *',
    $job$
      DELETE FROM notification_jobs
      WHERE ctid IN (
        SELECT ctid FROM notification_jobs
        WHERE state IN ('completed', 'failed')
          AND processed_at IS NOT NULL
          AND processed_at < now() - interval '7 days'
        LIMIT 1000
      );
    $job$
  );
END
$$;

COMMENT ON TABLE notification_jobs IS
  'Async dispatch queue. payload_json can hold raw recipe content (up to ~2 MiB); '
  'stir-cleanup-notification-jobs pg_cron job deletes terminal rows after 7 days '
  'to enforce the CloudKit-data-boundary rule.';
