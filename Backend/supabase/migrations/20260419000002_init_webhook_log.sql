-- Stir operational schema — webhook_log
--
-- 90-day audit of every RevenueCat webhook delivery, successful or not.
-- Separate from processed_webhook_events because:
--   - this table stores raw_payload (JSONB) which is ~1–5KB per row;
--   - we want failed / malformed webhooks logged even though they never
--     hit the idempotency table (signature verify failures, Zod rejects,
--     malformed bodies).
--   - 90-day retention is for dispute handling ("user says their
--     subscription didn't renew on this date — did RC tell us?") without
--     retaining raw billing payloads forever.
--
-- RLS: deny-all for authenticated role → service role only (ops table).
--
-- Cleanup: pg_cron job `stir-cleanup-webhook-log` deletes rows older
-- than 90 days in nightly batches of 10000. Batched to keep transaction
-- size bounded if the table ever grows under unusual retry storms.

CREATE TABLE IF NOT EXISTS webhook_log (
  id                   UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  -- RevenueCat's event.id. NULL only when signature verify rejected the
  -- request so early we never parsed the body. Unique when present so a
  -- replay is easy to spot in the log even though processed_webhook_events
  -- already rejected it.
  event_id             TEXT,
  -- RC event.type. NULL for the same early-reject cases.
  event_type           TEXT,
  -- Resolved from the payload's original_app_user_id / app_user_id field.
  -- NULL when the request failed before we could parse it or when the
  -- canonical key in the payload doesn't exist in app_users yet
  -- (SUBSCRIBER_ALIAS first-touch from an install:<uuid>).
  canonical_user_key   TEXT,
  -- One of: 'accepted' | 'duplicate' | 'signature_invalid' | 'validation_failed'
  --        | 'unknown_event' | 'alias_processed' | 'transfer_processed'
  --        | 'error'
  status               TEXT NOT NULL,
  raw_payload          JSONB,
  processed_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_webhook_log_event_id
  ON webhook_log(event_id) WHERE event_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_webhook_log_user
  ON webhook_log(canonical_user_key) WHERE canonical_user_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_webhook_log_processed_at
  ON webhook_log(processed_at);

-- Dashboard / alerting: "any signature_invalid in last hour?"
CREATE INDEX IF NOT EXISTS idx_webhook_log_status_nonaccepted
  ON webhook_log(status, processed_at DESC)
  WHERE status != 'accepted';

ALTER TABLE webhook_log ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE  webhook_log                        IS 'RevenueCat webhook audit log. 90-day retention via stir-cleanup-webhook-log pg_cron job. Service-role only.';
COMMENT ON COLUMN webhook_log.status                 IS 'accepted | duplicate | signature_invalid | validation_failed | unknown_event | alias_processed | transfer_processed | error';
COMMENT ON COLUMN webhook_log.raw_payload            IS 'Parsed JSON body. NULL when signature verify rejected before parse.';

-- ---------------------------------------------------------------------------
-- pg_cron cleanup job
-- ---------------------------------------------------------------------------
-- Nightly batch deletes. Matches the ai_response_cache cleanup pattern in
-- migration 14: unschedule existing, re-schedule idempotently.

CREATE EXTENSION IF NOT EXISTS pg_cron;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-cleanup-webhook-log') THEN
    PERFORM cron.unschedule('stir-cleanup-webhook-log');
  END IF;

  PERFORM cron.schedule(
    'stir-cleanup-webhook-log',
    -- 03:17 UTC nightly — offset from the 03:00 tick to avoid stacking
    -- against anything else scheduled on the hour.
    '17 3 * * *',
    $job$
      DELETE FROM webhook_log
      WHERE ctid IN (
        SELECT ctid FROM webhook_log
        WHERE processed_at < now() - interval '90 days'
        LIMIT 10000
      );
    $job$
  );
END
$$;
