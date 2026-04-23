-- Stir operational schema — pg_cron jobs (step 8)
--
-- Three scheduled jobs land in this migration:
--
--   stir-cost-anomaly-scan      every 15 min     → stir_ops_cost_anomaly_scan()
--   stir-reactivation-scan      daily 18:00 UTC  → stir_ops_reactivation_enqueue()
--   stir-audit-log-retention    nightly 09:30    → trims audit_log > 90 days
--
-- Schedule rationale:
--   - Cost anomaly: 15 min cadence is the fastest that still lets a
--     daily-spend aggregate form a stable reading. Faster would thrash
--     on sub-hour spend spikes; slower would let a runaway user burn
--     ~$2-3 more before detection.
--   - Reactivation: 18:00 UTC = 11:00 PT (PDT) / 10:00 PT (PST). Accept
--     the ±1h DST ambiguity; reactivation is a daily email-style nudge,
--     not a punctual event. See ADR 0026 (Reactivation push schedule).
--   - Audit retention: 09:30 UTC offsets from the 03:00 webhook_log
--     cleanup + 03:17 ai_response_cache cleanup so nightly maintenance
--     doesn't stack.
--
-- Idempotency: unschedule-then-reschedule per the existing webhook_log
-- cleanup pattern (migration 20260419000002). Re-running the migration
-- is safe; the DO block resolves name conflicts via cron.unschedule.
--
-- pg_cron runs inside the DB with postgres-role privileges, which
-- bypasses EXECUTE grants on our service_role-only RPCs. No extra
-- setup needed.

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ---------------------------------------------------------------------------
-- stir_ops_cron_job_info — ops-visibility RPC
-- ---------------------------------------------------------------------------
-- Returns one cron.job row's metadata so the ops SPA + tests can confirm
-- a schedule is wired without granting SELECT on the cron schema directly.
-- Admin-gated via is_admin() OR service_role (same pattern as other ops RPCs).

CREATE OR REPLACE FUNCTION public.stir_ops_cron_job_info(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, cron
AS $$
DECLARE
  v_row cron.job;
BEGIN
  IF NOT (public.is_admin() OR COALESCE(auth.jwt() ->> 'role', '') = 'service_role') THEN
    RAISE EXCEPTION 'not admin' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO v_row FROM cron.job WHERE jobname = p_name;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'jobname',  v_row.jobname,
    'schedule', v_row.schedule,
    'command',  v_row.command,
    'active',   v_row.active
  );
END $$;

REVOKE ALL ON FUNCTION public.stir_ops_cron_job_info(TEXT) FROM PUBLIC, authenticated, anon;
GRANT EXECUTE ON FUNCTION public.stir_ops_cron_job_info(TEXT) TO service_role;

COMMENT ON FUNCTION public.stir_ops_cron_job_info(TEXT) IS
  'Ops-visibility wrapper returning a single cron.job row. Used by the ops SPA cron-health page + Phase 1.6 tests.';

-- ---------------------------------------------------------------------------
-- stir-cost-anomaly-scan (every 15 min)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-cost-anomaly-scan') THEN
    PERFORM cron.unschedule('stir-cost-anomaly-scan');
  END IF;

  PERFORM cron.schedule(
    'stir-cost-anomaly-scan',
    '*/15 * * * *',
    $job$
      SELECT public.stir_ops_cost_anomaly_scan();
    $job$
  );
END
$$;

-- ---------------------------------------------------------------------------
-- stir-reactivation-scan (daily 18:00 UTC)
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-reactivation-scan') THEN
    PERFORM cron.unschedule('stir-reactivation-scan');
  END IF;

  PERFORM cron.schedule(
    'stir-reactivation-scan',
    '0 18 * * *',
    $job$
      SELECT public.stir_ops_reactivation_enqueue();
    $job$
  );
END
$$;

-- ---------------------------------------------------------------------------
-- stir-audit-log-retention (nightly 09:30 UTC, 90-day window)
-- ---------------------------------------------------------------------------
-- Matches the webhook_log retention pattern. Batched LIMIT 10000 per tick
-- to bound transaction size if retention ever accumulates a large backlog.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'stir-audit-log-retention') THEN
    PERFORM cron.unschedule('stir-audit-log-retention');
  END IF;

  PERFORM cron.schedule(
    'stir-audit-log-retention',
    '30 9 * * *',
    $job$
      DELETE FROM public.audit_log
      WHERE ctid IN (
        SELECT ctid FROM public.audit_log
        WHERE created_at < now() - interval '90 days'
        LIMIT 10000
      );
    $job$
  );
END
$$;
