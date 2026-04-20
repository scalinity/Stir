-- Stir operational schema — notification_jobs
-- Durable job queue for async work dispatched by Edge Functions and drained
-- by a pg_cron-scheduled dispatcher function (see companion migration).
--
-- Used by step 7 for:
--   - recipe_import_async: large OCR/paste (>`recipe_import_async_threshold`)
--                          queues rather than blocking the handler.
--   - push_send: future step-8 reactivation campaigns.
--
-- Spec §3 §4 name this as `notification_jobs` with the column shape:
--   id PK, canonical_user_key, kind, scheduled_at, state, payload_json.
-- This migration matches that shape and adds two bookkeeping columns the
-- worker needs (`processed_at`, `error_message`) + `updated_at` for lock
-- stealing detection. Adding columns, not renaming spec ones.
--
-- State machine:
--   pending   - fresh insert; eligible for claim
--   processing - dispatcher has claimed; worker is running
--   completed - worker succeeded; `processed_at` set
--   failed    - worker failed terminally; `error_message` populated
-- Transitions enforced by handler code (application-level), not triggers.
--
-- Claiming: dispatcher picks ONE pending row with
--   SELECT ... WHERE state='pending' AND scheduled_at <= now()
--   FOR UPDATE SKIP LOCKED LIMIT N
-- then UPDATE ... SET state='processing', updated_at=now()
-- The SKIP LOCKED clause lets multiple dispatcher invocations run in
-- parallel without the N+1 contention of conventional row locking.
--
-- RLS: enabled, service-role-only (no `authenticated` policy). Users
-- never read job rows directly — iOS polls `ai_response_cache` keyed on
-- (canonical_user_key, request_id) for the job's output once state flips.

CREATE TYPE notification_job_state AS ENUM (
  'pending',
  'processing',
  'completed',
  'failed'
);

CREATE TYPE notification_job_kind AS ENUM (
  'recipe_import_async',
  'push_send'
);

CREATE TABLE IF NOT EXISTS notification_jobs (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_user_key  TEXT NOT NULL REFERENCES app_users(canonical_user_key) ON DELETE CASCADE,
  kind                notification_job_kind NOT NULL,
  state               notification_job_state NOT NULL DEFAULT 'pending',
  scheduled_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  payload_json        JSONB NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  processed_at        TIMESTAMPTZ,
  error_message       TEXT,
  attempt_count       INTEGER NOT NULL DEFAULT 0
);

-- Primary claim path: dispatcher reads pending jobs ready-to-run, ordered
-- oldest-first. Partial index keeps it tiny (mostly completed rows).
CREATE INDEX IF NOT EXISTS idx_notification_jobs_claim
  ON notification_jobs(scheduled_at ASC)
  WHERE state = 'pending';

-- For user-scoped diagnostic queries ("did my import finish?") and for
-- the completion-poll path on iOS.
CREATE INDEX IF NOT EXISTS idx_notification_jobs_user_kind
  ON notification_jobs(canonical_user_key, kind, created_at DESC);

ALTER TABLE notification_jobs ENABLE ROW LEVEL SECURITY;
-- Intentionally no `authenticated` policy. Service-role only. iOS reads
-- the async result from `ai_response_cache` (which IS user-scoped via
-- step-3 RLS) keyed on the import_id passed back in the queued response.

COMMENT ON TABLE  notification_jobs                 IS 'Durable job queue. Drained by pgmq-dispatch Edge Function scheduled via pg_cron.';
COMMENT ON COLUMN notification_jobs.kind            IS 'recipe_import_async (step 7) | push_send (step 8).';
COMMENT ON COLUMN notification_jobs.state           IS 'pending -> processing -> completed|failed. Enforced in application code.';
COMMENT ON COLUMN notification_jobs.scheduled_at    IS 'Earliest run time. For delayed jobs; defaults to now() for immediate.';
COMMENT ON COLUMN notification_jobs.payload_json    IS 'Job-specific payload. See handler per `kind` for shape.';
COMMENT ON COLUMN notification_jobs.processed_at    IS 'Set when state flips to completed|failed. NULL while pending/processing.';
COMMENT ON COLUMN notification_jobs.error_message   IS 'Set on state=failed. Truncated to 1024 chars in worker.';
COMMENT ON COLUMN notification_jobs.attempt_count   IS 'Incremented per claim. Jobs with attempt_count >= 3 are NOT retried.';
