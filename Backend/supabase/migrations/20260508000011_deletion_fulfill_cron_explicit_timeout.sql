-- SCA-257 (W9 from /review-5) — add explicit `timeout_milliseconds`
-- to both `net.http_post` callsites in the deletion-fulfill cron path.
--
-- The original migration (20260508000006_deletion_fulfill_cron.sql)
-- omitted the timeout. pg_net's cluster default varies across
-- Supabase tiers (some clusters ship with 5s, others with 30s); a
-- silent default change at the platform layer would skew how often
-- the cron retries on stalls AND whether two ticks (5min cadence)
-- can overlap. The SLA-alerts migration (20260508000008_*) sets
-- 3000ms explicitly; the deletion-fulfill cron path was the
-- inconsistent sibling.
--
-- 60_000ms (60s) was chosen because:
--   * the worker is bounded by the Edge Function 150s wall, so the
--     cap doesn't need to be tighter than that;
--   * ticks fire every 5 minutes, so a 60s cap leaves >4 minutes of
--     slack before the next tick — overlap risk is zero;
--   * a 60s no-response is solid evidence of an Edge Function stall
--     worth retrying on the next tick rather than waiting 150s.
--
-- Re-applies via CREATE OR REPLACE on the manual trigger function +
-- a paired unschedule/reschedule on the cron job. Idempotent.

-- Re-schedule the cron with the new body containing the timeout.
DO $$
BEGIN
  -- Drop and re-add (cron.schedule errors on duplicate names; this
  -- is the same idempotent dance the original migration uses).
  PERFORM cron.unschedule('stir-deletion-fulfill') WHERE EXISTS (
    SELECT 1 FROM cron.job WHERE jobname = 'stir-deletion-fulfill'
  );

  PERFORM cron.schedule(
    'stir-deletion-fulfill',
    '*/5 * * * *',
    $job$
      SELECT
        net.http_post(
          url := current_setting('app.supabase_functions_url', true) || '/users-deletion-fulfill',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'X-Stir-Cron-Secret', current_setting('app.stir_pgmq_dispatch_secret', true)
          ),
          body := '{}'::jsonb,
          timeout_milliseconds := 60000
        );
    $job$
  );
END
$$;

-- Re-create the manual trigger with the same explicit timeout.
CREATE OR REPLACE FUNCTION public.stir_deletion_fulfill_trigger_once()
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  request_id bigint;
BEGIN
  SELECT net.http_post(
    url := current_setting('app.supabase_functions_url', true) || '/users-deletion-fulfill',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'X-Stir-Cron-Secret', current_setting('app.stir_pgmq_dispatch_secret', true)
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  ) INTO request_id;
  RETURN request_id;
END
$$;

REVOKE ALL ON FUNCTION public.stir_deletion_fulfill_trigger_once() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_deletion_fulfill_trigger_once() TO service_role;

COMMENT ON FUNCTION public.stir_deletion_fulfill_trigger_once() IS
  'SCA-88: ops manual trigger for users-deletion-fulfill. SCA-257: explicit 60_000ms timeout. Returns pg_net request_id; check net._http_response for the result. Cron schedule "stir-deletion-fulfill" runs the same function every 5 min.';
