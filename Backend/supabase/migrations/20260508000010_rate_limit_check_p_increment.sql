-- SCA-248 (C5 from /review-5) — add `p_increment BOOLEAN DEFAULT TRUE`
-- parameter to stir_rate_limit_check so callers stacking multiple
-- rate-limit gates can do a check-without-commit on the first gate
-- and only increment buckets once both have passed.
--
-- Problem: ops-admin/index.ts ran two gates (ip:ops_admin_hourly +
-- user:ops_admin_minutely), each calling checkAndIncrement which
-- checked AND incremented unconditionally on the allowed path. When
-- the user-gate tripped at request N, the IP bucket had already
-- incremented for that request — the docstring's "first-to-trip
-- wins" framing was a half-truth: both gates always charge a unit
-- of work. Result: legit triage admins burn IP allowance ~30× faster
-- than tuning intended; one compromised admin can soak the IP cap
-- to nudge other admins on the same egress IP toward 429.
--
-- Forward fix: new optional `p_increment` parameter, default TRUE so
-- every existing caller is backward-compatible. When FALSE, the
-- function still acquires the advisory lock and computes the same
-- (allowed, current_count, reset_at, retry_after_seconds) tuple but
-- skips the INSERT…ON CONFLICT block. ops-admin's first gate now
-- calls with p_increment:=FALSE; only the second gate (after both
-- have passed) does the increment. Full atomicity is preserved by
-- the two-phase pattern: read-then-write under the same advisory
-- lock domain (per (scope,bucket)).
--
-- Immutable-migration policy: the original 20260418000013 stays;
-- this migration uses CREATE OR REPLACE FUNCTION to upsert the new
-- definition. The new ARITY is 5 args; PostgreSQL keeps both
-- function signatures resolvable (the 4-arg form remains as a
-- backward-compat overload via DEFAULT, since SQL function
-- overloading on default-arg arity behaves like an additional
-- signature). All existing callers keep working unchanged.

CREATE OR REPLACE FUNCTION stir_rate_limit_check(
  p_scope_key      TEXT,
  p_bucket_key     TEXT,
  p_window_seconds INTEGER,
  p_max_count      INTEGER,
  p_increment      BOOLEAN DEFAULT TRUE
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

  -- Under cap. SCA-248: when p_increment is FALSE (composite-gate
  -- check-only call), skip the bucket-row write entirely. The
  -- caller is expected to invoke us a second time with p_increment
  -- TRUE once all stacked gates have cleared their check phase.
  IF p_increment THEN
    v_window_start := date_trunc('minute', now());
    INSERT INTO rate_limit_buckets (scope_key, bucket_key, window_start, count)
         VALUES (p_scope_key, p_bucket_key, v_window_start, 1)
    ON CONFLICT (scope_key, bucket_key, window_start)
    DO UPDATE SET count = rate_limit_buckets.count + 1;

    v_reset_at := COALESCE(v_oldest_ws, v_window_start) + make_interval(secs => p_window_seconds);
    v_retry_secs := GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_reset_at - now())))::INTEGER);

    allowed := TRUE;
    current_count := v_current_count + 1;
  ELSE
    -- Check-only path: no bucket row inserted. current_count reflects
    -- pre-increment state. reset_at is computed against the oldest
    -- existing window (or now() if none exist), so the caller gets a
    -- coherent retry hint even on the no-write path.
    v_reset_at := COALESCE(v_oldest_ws, now()) + make_interval(secs => p_window_seconds);
    v_retry_secs := GREATEST(0, CEIL(EXTRACT(EPOCH FROM (v_reset_at - now())))::INTEGER);

    allowed := TRUE;
    current_count := v_current_count;
  END IF;

  reset_at := v_reset_at;
  retry_after_seconds := v_retry_secs;
  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION stir_rate_limit_check(TEXT, TEXT, INTEGER, INTEGER, BOOLEAN) IS
  'Atomic sliding-window rate-limit check (and optionally increment). p_increment defaults TRUE for backward compat with the original 4-arg signature; pass FALSE for the first gate of a layered/composite policy so only the winning gate writes a bucket row. Advisory-locked on (scope,bucket) for concurrency safety. SCA-248.';
