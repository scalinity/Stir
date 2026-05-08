-- SCA-223 — atomic claim RPC for deletion_requests.
--
-- Replaces the unbounded `.update().limit()` PostgREST pattern in
-- users-deletion-fulfill with FOR UPDATE SKIP LOCKED + LIMIT, matching
-- the sibling `stir_claim_pending_jobs` model from
-- migration 20260419000019. Without this, concurrent cron ticks (and
-- arbitrary batch-approve flows) could flip every approved row to
-- 'processing' and strand them — there is no reclaim sweep for
-- deletion_requests, so a stranded row never advances.
--
-- Contract:
--   Input:  p_limit INTEGER (clamped 1..20) — max rows to claim per call
--   Output: full deletion_requests row shape including external_refs_json
--           so the caller has resume state without a second read.
--
-- Why RPC not raw SQL: PostgREST can't express FOR UPDATE SKIP LOCKED
-- inline. supabase-js's `.update().limit()` translates to a CTE only
-- when an explicit `.order()` is provided, and even then doesn't carry
-- SKIP LOCKED — so two parallel ticks can lock-wait on each other or
-- both claim the same row depending on PostgREST version. The stored
-- proc is the only race-safe shape.

CREATE OR REPLACE FUNCTION stir_claim_deletion_requests(
  p_limit INTEGER
) RETURNS TABLE(
  id                       UUID,
  canonical_user_key       TEXT,
  canonical_user_key_hash  TEXT,
  external_refs_json       JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_limit INTEGER;
BEGIN
  v_limit := GREATEST(1, LEAST(COALESCE(p_limit, 1), 20));

  RETURN QUERY
  WITH claimed AS (
    SELECT dr.id
      FROM deletion_requests dr
     WHERE dr.state = 'approved'
     ORDER BY dr.requested_at ASC
     LIMIT v_limit
       FOR UPDATE SKIP LOCKED
  ),
  flipped AS (
    UPDATE deletion_requests dr
       SET state = 'processing',
           started_at = now(),
           updated_at = now()
     WHERE dr.id IN (SELECT c.id FROM claimed c)
     RETURNING dr.id,
               dr.canonical_user_key,
               dr.canonical_user_key_hash,
               dr.external_refs_json
  )
  SELECT f.id,
         f.canonical_user_key,
         f.canonical_user_key_hash,
         f.external_refs_json
    FROM flipped f;
END
$$;

REVOKE ALL ON FUNCTION stir_claim_deletion_requests(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION stir_claim_deletion_requests(INTEGER) FROM authenticated;
REVOKE ALL ON FUNCTION stir_claim_deletion_requests(INTEGER) FROM anon;
GRANT EXECUTE ON FUNCTION stir_claim_deletion_requests(INTEGER) TO service_role;

COMMENT ON FUNCTION stir_claim_deletion_requests(INTEGER) IS
  'SCA-223: atomic claim of up to N approved deletion_requests. Flips state to processing + sets started_at. Returns the post-flip row shape needed by users-deletion-fulfill (id, canonical_user_key, canonical_user_key_hash, external_refs_json). FOR UPDATE SKIP LOCKED makes concurrent ticks race-safe. service-role only.';
