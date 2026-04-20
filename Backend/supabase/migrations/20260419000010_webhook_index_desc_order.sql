-- Performance tuning: step-5 follow-up (CA3 audit).
--
-- `processed_webhook_events` was seeded (migration 20260419000001) with a
-- simple BTREE on `processed_at`. The only read pattern against this index
-- is debug/ops lookup of recent events ("did we process <event_id>?",
-- "show the most recent 100 webhooks"). Those queries scan in reverse
-- chronological order.
--
-- BTREE default is ASC; Postgres can scan either direction but prefers the
-- stored order for forward-only operators (ORDER BY ... DESC LIMIT N picks
-- a backward scan, which is fine functionally but marginally slower and
-- harder for the planner to combine with secondary index predicates).
-- Storing the index in DESC order matches the read pattern exactly, and
-- mirrors `idx_webhook_log_status_nonaccepted` which already uses
-- `processed_at DESC`.
--
-- Volume today: well below the threshold where this matters. Landing the
-- change alongside the step-5 CA3 audit so every ops-lookup index across
-- the webhook surface uses the same shape.

DROP INDEX IF EXISTS idx_processed_webhook_events_processed_at;
CREATE INDEX IF NOT EXISTS idx_processed_webhook_events_processed_at
  ON processed_webhook_events(processed_at DESC);

COMMENT ON INDEX idx_processed_webhook_events_processed_at IS
  'Ops debug lookup ("recent events") — DESC matches the read pattern and the webhook_log status index shape.';
