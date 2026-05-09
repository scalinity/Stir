-- SCA-125 — extract pgmq-dispatch reclaim sweep to a SQL stored proc.
--
-- Background:
--   The two-part reclaim sweep that recovers stuck `notification_jobs`
--   rows (state='processing' with stale updated_at) lives inline in
--   `Backend/supabase/functions/pgmq-dispatch/index.ts`. That coupling
--   forces sweep tests through the edge-runtime HTTP path, which
--   complicates isolated-worktree verification (Path A contamination
--   per `docs/runbooks/isolated-worktree-verification.md`) and adds
--   network latency/flake to a logically-pure DB operation.
--
-- This migration moves the sweep into a stored procedure so tests can
-- invoke it via `svc.rpc('stir_pgmq_reclaim_sweep')` against any
-- service-role-authenticated client, bypassing the edge runtime
-- entirely. The TS dispatcher (`pgmq-dispatch/index.ts`) calls the
-- same RPC instead of running the inline UPDATEs.
--
-- Behavior is semantically identical to the prior TS implementation:
--
--   Part A — reclaim to pending (retryable):
--     state='processing' AND attempt_count <  MAX_ATTEMPTS
--                       AND updated_at  <  (now() - p_stale_minutes)
--     → state='pending', error_message='reclaimed after stuck processing window'
--
--   Part B — dead-letter to failed (terminal):
--     state='processing' AND attempt_count >= MAX_ATTEMPTS
--                       AND updated_at  <  (now() - p_stale_minutes)
--     → state='failed', error_message='reclaim_max_attempts_reached'
--
-- Constants are passed as arguments (defaults match the prior TS values:
-- 5 stale-minutes, 3 max attempts) so tests can shorten the window
-- without time travel. The function returns a JSONB summary so the TS
-- dispatcher can log the same shape it logged previously.
--
-- Auth posture: SECURITY DEFINER with the standard search_path = public
-- pin. Service role is the only legitimate caller (pg_cron-via-dispatch
-- and pgmq-dispatch handler). REVOKEs at the bottom enforce that.

CREATE OR REPLACE FUNCTION public.stir_pgmq_reclaim_sweep(
  p_stale_minutes INTEGER DEFAULT 5,
  p_max_attempts  INTEGER DEFAULT 3
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_cutoff           TIMESTAMPTZ;
  v_reclaimed_count  INTEGER := 0;
  v_dead_lettered    INTEGER := 0;
BEGIN
  -- Negative or zero stale-window is a programmer error; clamp to >= 1
  -- so a misuse can't accidentally flip ALL processing rows to pending
  -- mid-tick.
  IF p_stale_minutes IS NULL OR p_stale_minutes < 1 THEN
    p_stale_minutes := 5;
  END IF;
  IF p_max_attempts IS NULL OR p_max_attempts < 1 THEN
    p_max_attempts := 3;
  END IF;

  v_cutoff := now() - (p_stale_minutes || ' minutes')::interval;

  -- ---- Part A: reclaim to 'pending' for retry.
  -- Rows still under the retry budget (attempt_count < MAX) get
  -- another shot. The matching `error_message` records *why* the
  -- reclaim happened so ops can correlate against worker crash logs.
  WITH reclaimed AS (
    UPDATE notification_jobs
       SET state = 'pending',
           error_message = 'reclaimed after stuck processing window',
           updated_at = now()
     WHERE state = 'processing'
       AND attempt_count < p_max_attempts
       AND updated_at < v_cutoff
    RETURNING id
  )
  SELECT COUNT(*) INTO v_reclaimed_count FROM reclaimed;

  -- ---- Part B: dead-letter to 'failed'.
  -- Rows that already burned the retry budget (attempt_count >= MAX)
  -- before crashing get terminal failure rather than retry. Pre-fix
  -- (review C11) these stayed wedged in 'processing' forever because
  -- the reclaim filter excluded attempt_count == MAX.
  WITH dead_lettered AS (
    UPDATE notification_jobs
       SET state = 'failed',
           error_message = 'reclaim_max_attempts_reached',
           updated_at = now(),
           processed_at = now()
     WHERE state = 'processing'
       AND attempt_count >= p_max_attempts
       AND updated_at < v_cutoff
    RETURNING id
  )
  SELECT COUNT(*) INTO v_dead_lettered FROM dead_lettered;

  RETURN jsonb_build_object(
    'reclaimed_count',     v_reclaimed_count,
    'dead_lettered_count', v_dead_lettered,
    'cutoff',              v_cutoff,
    'stale_minutes',       p_stale_minutes,
    'max_attempts',        p_max_attempts
  );
END $$;

COMMENT ON FUNCTION public.stir_pgmq_reclaim_sweep(INTEGER, INTEGER) IS
  'SCA-125: pgmq-dispatch reclaim sweep extracted from TS. Part A reclaims state=processing rows under the retry budget back to pending; Part B dead-letters rows at attempt_count >= max to failed. Returns {reclaimed_count, dead_lettered_count, cutoff, stale_minutes, max_attempts}. Service-role only.';

REVOKE ALL ON FUNCTION public.stir_pgmq_reclaim_sweep(INTEGER, INTEGER)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stir_pgmq_reclaim_sweep(INTEGER, INTEGER)
  TO service_role;
