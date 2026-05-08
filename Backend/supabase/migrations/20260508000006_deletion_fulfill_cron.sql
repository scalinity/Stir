-- SCA-88 — deletion_requests fulfillment worker scheduling.
--
-- SCA-61 shipped the in-app surface + endpoint + table + ops admin tab.
-- That landed `pending → approved` transitions but no automated fulfillment.
-- This migration adds the cron schedule that invokes
-- `users-deletion-fulfill` every 5 minutes, plus a manual-trigger RPC for
-- ops console use.
--
-- Implementation choice: a separate edge function (not a kind in
-- pgmq-dispatch) because deletion_requests is a state machine on its own
-- table, not a notification_jobs queue row. The state-machine claim
-- pattern (SELECT FOR UPDATE SKIP LOCKED) lives directly in the worker
-- against deletion_requests.
--
-- Schedule rationale: Privacy Policy §7.2 commits to a 30-day fulfillment
-- SLA. 5-minute cadence is conservative — most fulfillments complete in
-- one tick. The `processing` state is short-lived; failures land in
-- `failed` for ops triage rather than retrying indefinitely.
--
-- Auth: same `STIR_PGMQ_DISPATCH_SECRET` shared-secret pattern as
-- pgmq-dispatch. pg_cron sets the `X-Stir-Cron-Secret` header from the
-- vault config (set by migration 20260504000001).

DO $$
BEGIN
  -- Only schedule if the cron extension is reachable. Local supabase
  -- start may run before pgmq/pg_cron extensions land; failing here
  -- with "schema cron does not exist" would block local dev.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    RAISE NOTICE 'pg_cron not installed; skipping stir-deletion-fulfill schedule.';
    RETURN;
  END IF;

  -- Idempotent re-schedule. cron.schedule errors on duplicate job names.
  PERFORM cron.unschedule('stir-deletion-fulfill')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-deletion-fulfill');

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
          body := '{}'::jsonb
        );
    $job$
  );
END
$$;

-- Manual ops trigger: invoked from ops console / runbook to drain the
-- queue between cron ticks (e.g. after approving multiple requests).
-- Service-role only.
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
    body := '{}'::jsonb
  ) INTO request_id;
  RETURN request_id;
END
$$;

REVOKE ALL ON FUNCTION public.stir_deletion_fulfill_trigger_once() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_deletion_fulfill_trigger_once() TO service_role;

COMMENT ON FUNCTION public.stir_deletion_fulfill_trigger_once() IS
  'SCA-88: ops manual trigger for users-deletion-fulfill. Returns pg_net request_id; check net._http_response for the result. Cron schedule "stir-deletion-fulfill" runs the same function every 5 min.';
