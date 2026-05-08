-- SCA-58 review follow-ups for deletion_requests:
--
-- 1. CR1-W5 / SA1-I3: pin the 1024-char truncation contract on
--    `failure_reason` as a SQL CHECK so the (still-deferred) SCA-88
--    fulfillment worker can't silently insert a megabyte Gemini
--    error trace and bloat the row. Mirrors the pattern from
--    `ops_flagged_outputs.flag_reason` size-cap CHECKs.
--
-- 2. CA3-M1: add a non-partial supporting index for the ops
--    `deletion_requests.list` default filter. The list handler
--    queries with state IN ('pending','approved','processing',
--    'failed') ordered by requested_at DESC; the existing partial
--    index `idx_deletion_requests_state_requested` excludes 'failed'
--    so Postgres can't use it for the default IN list and falls back
--    to seq scan + sort once `completed`/`failed` rows accumulate.
--    Keep the partial index (it's correct for the in-flight idempotency
--    hot path) and add a non-partial sibling.
--
-- 3. CA1-W9: defensive guard in case pg_cron isn't installed when
--    a future migration that reads `cron.job` is applied in isolation.
--    `CREATE EXTENSION IF NOT EXISTS pg_cron` is a no-op on prod (already
--    installed); on a fresh isolated branch checkout that runs *this*
--    migration, it materializes pg_cron before the indexes execute.

CREATE EXTENSION IF NOT EXISTS pg_cron;

ALTER TABLE deletion_requests
  ADD CONSTRAINT deletion_requests_failure_reason_check
  CHECK (failure_reason IS NULL OR length(failure_reason) <= 1024);

CREATE INDEX IF NOT EXISTS idx_deletion_requests_state_requested_full
  ON deletion_requests(state, requested_at DESC);

COMMENT ON CONSTRAINT deletion_requests_failure_reason_check ON deletion_requests IS
  'CR1-W5 / SA1-I3: 1024-char cap on fulfillment-worker failure messages. Pins what the migration COMMENT promised; prevents large Gemini-error traces or APNs error blobs from inflating row size.';

COMMENT ON INDEX idx_deletion_requests_state_requested_full IS
  'CA3-M1: covers the ops deletion_requests.list default IN list (pending|approved|processing|failed). The partial-index sibling excludes `failed` and is reserved for the in-flight idempotency probe in users-delete-request.';
