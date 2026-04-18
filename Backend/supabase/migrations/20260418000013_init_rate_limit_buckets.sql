-- Stir operational schema — rate_limit_buckets + stir_rate_limit_check()
--
-- Sliding-window rate limiter backing every /v1/ai/* endpoint from step 3.
-- Per CLAUDE.md §Deferred: lands in step 3 with the first AI handlers.
--
-- Schema: one row per (scope, bucket, window_start) at minute granularity.
-- A 24h daily limit therefore has up to 1440 rows per (scope, bucket).
-- Rows are garbage-collected by a nightly pg_cron job (migration 14).
--
-- RLS: enabled with zero `authenticated` policies → default deny. Service
-- role bypasses. Ops infrastructure; never user-queryable.
--
-- Atomicity: `stir_rate_limit_check()` wraps the read+insert in a
-- transaction-scoped advisory lock keyed on hashtext(scope||':'||bucket).
-- Prevents TOCTOU over-count under concurrent requests for the same
-- (scope, bucket) pair without global table locks or hot-row contention
-- across unrelated buckets.

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
  scope_key    TEXT NOT NULL,
  bucket_key   TEXT NOT NULL,
  window_start TIMESTAMPTZ NOT NULL,
  count        INTEGER NOT NULL DEFAULT 0 CHECK (count >= 0),
  PRIMARY KEY (scope_key, bucket_key, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rlb_scope_bucket_window
  ON rate_limit_buckets(scope_key, bucket_key, window_start DESC);

-- Also index by window_start alone for efficient GC sweep.
CREATE INDEX IF NOT EXISTS idx_rlb_window_start
  ON rate_limit_buckets(window_start);

ALTER TABLE rate_limit_buckets ENABLE ROW LEVEL SECURITY;
-- Intentionally no policies for authenticated role → default deny.

COMMENT ON TABLE  rate_limit_buckets            IS 'Sliding-window rate limiter counters at 1-minute granularity. Ops-only; RLS deny-all for authenticated.';
COMMENT ON COLUMN rate_limit_buckets.scope_key  IS 'Policy scope, e.g. "ip:dinner_solve_daily", "user:dinner_solve_hourly".';
COMMENT ON COLUMN rate_limit_buckets.bucket_key IS 'Bucket within scope — IP address, canonical_user_key, etc.';
COMMENT ON COLUMN rate_limit_buckets.window_start IS 'Minute-truncated window start. Multiple rows per (scope,bucket) cover the sliding window.';

-- ---------------------------------------------------------------------------
-- stir_rate_limit_check(scope, bucket, window_seconds, max_count)
-- ---------------------------------------------------------------------------
-- Atomic check-and-increment using an advisory transaction lock.
-- Returns one row with (allowed, current_count, reset_at, retry_after_seconds).
--
-- Contract:
--   allowed=true  → request is under cap; counter has been incremented
--   allowed=false → request is at/over cap; counter NOT incremented;
--                    retry_after_seconds = seconds until the oldest window row ages out
--
-- Advisory lock is transaction-scoped (pg_advisory_xact_lock), released
-- automatically on commit/rollback. hashtext() maps the string to an int8
-- keyspace that's collision-rare enough for this use case.

CREATE OR REPLACE FUNCTION stir_rate_limit_check(
  p_scope_key      TEXT,
  p_bucket_key     TEXT,
  p_window_seconds INTEGER,
  p_max_count      INTEGER
) RETURNS TABLE(
  allowed              BOOLEAN,
  current_count        INTEGER,
  reset_at             TIMESTAMPTZ,
  retry_after_seconds  INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_cutoff        TIMESTAMPTZ;
  v_current_count INTEGER;
  v_oldest_ws     TIMESTAMPTZ;
  v_window_start  TIMESTAMPTZ;
  v_reset_at      TIMESTAMPTZ;
  v_retry_secs    INTEGER;
BEGIN
  -- Serialize concurrent calls for the same (scope, bucket).
  PERFORM pg_advisory_xact_lock(hashtext(p_scope_key || ':' || p_bucket_key));

  v_cutoff := now() - make_interval(secs => p_window_seconds);

  SELECT COALESCE(SUM(count), 0), MIN(window_start)
    INTO v_current_count, v_oldest_ws
  FROM rate_limit_buckets
  WHERE scope_key = p_scope_key
    AND bucket_key = p_bucket_key
    AND window_start > v_cutoff;

  IF v_current_count >= p_max_count THEN
    -- Reset at = oldest window + window_seconds (when that row ages out).
    v_reset_at := v_oldest_ws + make_interval(secs => p_window_seconds);
    v_retry_secs := GREATEST(1, CEIL(EXTRACT(EPOCH FROM (v_reset_at - now())))::INTEGER);
    allowed := FALSE;
    current_count := v_current_count;
    reset_at := v_reset_at;
    retry_after_seconds := v_retry_secs;
    RETURN NEXT;
    RETURN;
  END IF;

  -- Under cap: increment the current-minute bucket row.
  v_window_start := date_trunc('minute', now());
  INSERT INTO rate_limit_buckets (scope_key, bucket_key, window_start, count)
       VALUES (p_scope_key, p_bucket_key, v_window_start, 1)
  ON CONFLICT (scope_key, bucket_key, window_start)
  DO UPDATE SET count = rate_limit_buckets.count + 1;

  v_reset_at := COALESCE(v_oldest_ws, v_window_start) + make_interval(secs => p_window_seconds);
  v_retry_secs := GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_reset_at - now())))::INTEGER);

  allowed := TRUE;
  current_count := v_current_count + 1;
  reset_at := v_reset_at;
  retry_after_seconds := v_retry_secs;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER) IS
  'Atomic sliding-window rate-limit check-and-increment. Returns (allowed, current_count, reset_at, retry_after_seconds). Advisory-locked on (scope,bucket) for concurrency safety.';
