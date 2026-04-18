-- Stir operational schema — ai_response_cache + pg_cron cleanup
--
-- Idempotency cache for /v1/ai/pantry-parse and /v1/ai/dinner-solve.
-- Client sends client_request_id / solve_request_id; if we see the same
-- ID within the TTL window (10 min), we replay the cached response body
-- instead of re-calling Gemini.
--
-- Why 10 minutes: covers network retries, transient connectivity loss,
-- app backgrounding. Long enough that a user doesn't rage-tap and burn
-- quota; short enough that stale data doesn't serve after a genuine
-- context change.
--
-- RLS: deny-all for authenticated role → service role only.
--
-- Cleanup: pg_cron job runs every 5 minutes and batches DELETE 1000
-- rows per pass. Batched to keep transaction size bounded even if the
-- cache grows large under unusual load (e.g. retry storms).

CREATE TABLE IF NOT EXISTS ai_response_cache (
  request_id     TEXT PRIMARY KEY,
  response_body  JSONB NOT NULL,
  status_code    INTEGER NOT NULL,
  feature_key    TEXT NOT NULL,                    -- for observability; which endpoint cached this
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_response_cache_created
  ON ai_response_cache(created_at);

ALTER TABLE ai_response_cache ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE  ai_response_cache              IS 'Idempotency cache for /v1/ai/* endpoints. 10 min TTL. Ops-only; RLS deny-all for authenticated.';
COMMENT ON COLUMN ai_response_cache.request_id   IS 'client_request_id / solve_request_id from the request body.';
COMMENT ON COLUMN ai_response_cache.status_code  IS 'HTTP status that was returned. Replay must honor this (cache an AI-02 response too, not just 2xx).';

-- ---------------------------------------------------------------------------
-- pg_cron cleanup job
-- ---------------------------------------------------------------------------
-- Enable pg_cron extension (already present on Supabase hosted and local).
-- If the extension isn't available (exotic local dev), the migration
-- fails loudly rather than silently — pg_cron is expected infrastructure.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Idempotent re-schedule. cron.schedule errors on duplicate job names.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-cleanup-ai-response-cache') THEN
    PERFORM cron.unschedule('stir-cleanup-ai-response-cache');
  END IF;

  PERFORM cron.schedule(
    'stir-cleanup-ai-response-cache',
    '*/5 * * * *',
    $job$
      DELETE FROM ai_response_cache
      WHERE ctid IN (
        SELECT ctid FROM ai_response_cache
        WHERE created_at < now() - interval '10 minutes'
        LIMIT 1000
      );
    $job$
  );
END
$$;

COMMENT ON EXTENSION pg_cron IS 'Scheduled jobs. Used for ai_response_cache TTL sweep; later steps may add more.';
