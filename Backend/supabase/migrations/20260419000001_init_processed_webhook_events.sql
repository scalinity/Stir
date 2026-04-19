-- Stir operational schema — processed_webhook_events
--
-- RevenueCat retries any webhook delivery that doesn't return 2xx. Their
-- server also occasionally sends duplicates on the same event after
-- network blips, even when the first delivery succeeded. The idempotency
-- invariant is: given the same `event.id`, the handler must update
-- entitlement_snapshots exactly once.
--
-- Strategy: INSERT `event_id` into this table in the same transaction as
-- the entitlement row mutation. PK violation on a duplicate → handler
-- short-circuits and returns 200 immediately without touching
-- entitlement_snapshots again. No SELECT-then-INSERT race window.
--
-- RLS: deny-all for authenticated role → service role only (ops table).
--
-- Cleanup: no TTL. event_id rows are small (~60B each) and stale rows
-- aren't strictly unsafe — if RC ever replays an event 90+ days later,
-- re-processing it would re-write the same entitlement state, which is
-- fine but noisy in the audit trail. The webhook_log table (migration 2)
-- has the 90-day TTL for raw payloads; this table can grow forever.

CREATE TABLE IF NOT EXISTS processed_webhook_events (
  event_id      TEXT PRIMARY KEY,
  event_type    TEXT NOT NULL,            -- RC event.type (INITIAL_PURCHASE, RENEWAL, ...)
  processed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Lookup by recent processing (support debugging: "did we process <event_id>?").
CREATE INDEX IF NOT EXISTS idx_processed_webhook_events_processed_at
  ON processed_webhook_events(processed_at);

ALTER TABLE processed_webhook_events ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE  processed_webhook_events              IS 'RevenueCat webhook idempotency. PK on event.id. Service-role only; RLS deny-all for authenticated.';
COMMENT ON COLUMN processed_webhook_events.event_id     IS 'RC event.id. PK — duplicate inserts fail with SQLSTATE 23505 and the handler treats that as "already processed".';
COMMENT ON COLUMN processed_webhook_events.event_type   IS 'RC event.type at time of processing. Kept for audit / filtering the idempotency log by event class.';
