-- SCA-278 (S12 from /review-5) — RAISE NOTICE when stir_claim_deletion_requests
-- silently clamps p_limit to the [1, 20] range.
--
-- Pre-fix `v_limit := GREATEST(1, LEAST(COALESCE(p_limit, 1), 20));`
-- silently clamped any out-of-range input. The internal worker always
-- passes 5 (well within bounds), but a manual ops invocation passing
-- 50 would get 20 with no warning — confusing partial result, no
-- evidence in the function output that the clamp fired.
--
-- Forward fix: add a `RAISE NOTICE` when the clamp actually changes
-- the value. NOTICE level surfaces in the standard Postgres client
-- output without raising an exception (rejecting the call is too
-- aggressive; the clamped value still does useful work).
--
-- Original migration (20260508000007) untouched per immutable-
-- migration policy. CREATE OR REPLACE FUNCTION upserts the body.

CREATE OR REPLACE FUNCTION stir_claim_deletion_requests(
  p_limit INTEGER
)
RETURNS TABLE(
  id UUID,
  canonical_user_key TEXT,
  attempt_count INTEGER,
  external_refs_json JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_limit INTEGER;
BEGIN
  v_limit := GREATEST(1, LEAST(COALESCE(p_limit, 1), 20));
  -- SCA-278 (S12 from /review-5): surface the clamp event so manual
  -- ops invocations passing >20 (or NULL → defaulted to 1) don't get
  -- a confusing partial result. NOTICE rather than EXCEPTION because
  -- the clamped value is still useful work and rejecting would break
  -- existing internal callers; the message just makes the policy
  -- audible.
  IF p_limit IS DISTINCT FROM v_limit THEN
    RAISE NOTICE 'stir_claim_deletion_requests: p_limit % clamped to % (allowed range 1..20)', p_limit, v_limit;
  END IF;
  RETURN QUERY
    UPDATE deletion_requests
       SET state          = 'processing',
           started_at     = COALESCE(started_at, now()),
           attempt_count  = COALESCE(attempt_count, 0) + 1
     WHERE deletion_requests.id IN (
       SELECT dr.id
         FROM deletion_requests AS dr
        WHERE dr.state = 'approved'
        ORDER BY dr.requested_at ASC
        FOR UPDATE SKIP LOCKED
        LIMIT v_limit
     )
     RETURNING
       deletion_requests.id,
       deletion_requests.canonical_user_key,
       deletion_requests.attempt_count,
       deletion_requests.external_refs_json;
END
$$;

COMMENT ON FUNCTION stir_claim_deletion_requests(INTEGER) IS
  'SCA-88: atomic claim of approved deletion_requests for the cron worker. SKIP LOCKED for concurrency-safe multi-worker support. SCA-278: emits a NOTICE when p_limit gets clamped to [1, 20] so manual ops invocations with out-of-range inputs are visible.';
