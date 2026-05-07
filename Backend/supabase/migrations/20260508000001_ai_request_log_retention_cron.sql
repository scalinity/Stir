-- Retention sweep for ai_request_log — 30-day delete from row insertion.
--
-- Why: Privacy Policy §6 commits to a 30-day operational-log retention
-- window for "AI request logs" (covers all feature_key values including
-- `cook_mode_realtime` voice turns, which the Privacy Policy lists
-- separately as "voice turn metadata" — they live in this same table
-- per the SCA-44 / step-6 wiring; voice-turn-usage handler writes rows
-- with feature_key='cook_mode_realtime' rather than to a separate
-- voice_turn_usage table).
--
-- Substitution events + outcome feedback are CloudKit-only entities
-- per CLAUDE.md data-ownership boundary; the Privacy Policy table that
-- listed them as "Stir backend" was incorrect — corrected in the
-- companion §6 update.
--
-- Mirrors the notification_jobs cleanup pattern (20260423000001) and
-- ai_response_cache cleanup (20260418000014). Idempotent re-schedule
-- via the unschedule-then-schedule dance so re-running this migration
-- doesn't duplicate the job.
--
-- Cadence: hourly with a 1000-row LIMIT batch. ai_request_log is
-- append-only at the request-completion site; expected steady-state
-- write rate at v1 launch (~10-20 active users) is well under 1000
-- rows/hour, so a single hourly pass keeps the table within the
-- 30-day window without ever spiking. At beta scale (≥100 active
-- users) this may need bumping — revisit when ai_request_log row
-- count crosses ~250k.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-cleanup-ai-request-log') THEN
    PERFORM cron.unschedule('stir-cleanup-ai-request-log');
  END IF;

  -- Hourly at :23 — off-peak relative to other Stir crons:
  --   :00 stir-cleanup-ai-response-cache (existing)
  --   :17 stir-cleanup-notification-jobs (existing)
  --   :23 stir-cleanup-ai-request-log     (new)
  --   :41 stir-cleanup-webhook-log        (existing)
  PERFORM cron.schedule(
    'stir-cleanup-ai-request-log',
    '23 * * * *',
    $job$
      DELETE FROM ai_request_log
      WHERE ctid IN (
        SELECT ctid FROM ai_request_log
        WHERE created_at < now() - interval '30 days'
        LIMIT 1000
      );
    $job$
  );
END
$$;

COMMENT ON TABLE ai_request_log IS
  'Cost + reliability log; subject to 30-day retention via the '
  'stir-cleanup-ai-request-log pg_cron job. Privacy Policy §6 commits '
  'to this window for both general AI request logs and voice turn '
  'metadata (the latter being rows with feature_key=cook_mode_realtime).';
