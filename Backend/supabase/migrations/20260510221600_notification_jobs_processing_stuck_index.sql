-- SCA-304 (/review-5) — partial index covering the reclaim-sweep WHERE.
--
-- The `stir_pgmq_reclaim_sweep` proc (migration 20260509145809) scans
-- `notification_jobs` twice per tick (Part A reclaim, Part B dead-letter)
-- with the predicate `state = 'processing' AND updated_at < cutoff` plus
-- a comparison on `attempt_count`. The existing `idx_notification_jobs_claim`
-- partial index from 20260419000013 covers `state = 'pending' …` for the
-- claim path but leaves the `processing`-state scan unindexed — every
-- reclaim tick burned a sequential scan over the full table (small today,
-- but grows linearly with notification volume).
--
-- This migration adds a partial composite index keyed on
-- `(updated_at, attempt_count) WHERE state = 'processing'`. Both reclaim
-- branches filter by `state = 'processing'` first (matches the partial
-- WHERE), then by `updated_at < cutoff` (range-scannable on the leading
-- index column), then by `attempt_count {<,>=} max` (covered by the
-- second index column — index-only-scan friendly).
--
-- IMPORTANT — DO NOT add `CONCURRENTLY` to the CREATE INDEX statement.
-- The Supabase migration runner wraps each migration file in a single
-- BEGIN/COMMIT transaction. `CREATE INDEX CONCURRENTLY` is forbidden
-- inside a transaction block and aborts the entire migration with
-- "CREATE INDEX CONCURRENTLY cannot run inside a transaction block".
-- The non-concurrent form is the only valid shape here. Acceptable
-- because notification_jobs is a low-write operational table and any
-- exclusive-lock window during build is brief.

CREATE INDEX IF NOT EXISTS idx_notification_jobs_processing_stuck
  ON notification_jobs (updated_at, attempt_count)
  WHERE state = 'processing';

COMMENT ON INDEX idx_notification_jobs_processing_stuck IS
  'SCA-304: Covers stir_pgmq_reclaim_sweep WHERE state=processing AND updated_at<cutoff [AND attempt_count {<,>=} max]. Plain (non-CONCURRENT) CREATE INDEX is required — migration runner wraps each file in a transaction and CONCURRENTLY cannot run inside a transaction block.';
