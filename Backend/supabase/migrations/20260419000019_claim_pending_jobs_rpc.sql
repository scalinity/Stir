-- Stir operational schema — stir_claim_pending_jobs RPC
--
-- Atomic claim of up to N pending notification_jobs, using FOR UPDATE
-- SKIP LOCKED so concurrent dispatcher invocations don't step on each
-- other. The selected rows are immediately flipped to state='processing'
-- in the same statement, returning the pre-flip row snapshot so the
-- caller has everything needed without a second read.
--
-- Contract:
--   Input:  p_limit INTEGER (1..20) — max rows to claim per call
--   Output: id, canonical_user_key, kind, state (always 'pending' on
--           the returned snapshot), attempt_count, payload_json.
--
-- Why RPC not raw SQL from the Edge Function:
--   - PostgREST can't express FOR UPDATE SKIP LOCKED inline.
--   - attempt_count increment must happen in the same transaction as
--     the state flip, otherwise a worker crash could leave a row
--     'processing' with an un-incremented counter.

CREATE OR REPLACE FUNCTION stir_claim_pending_jobs(
  p_limit INTEGER
) RETURNS TABLE(
  id                 UUID,
  canonical_user_key TEXT,
  kind               TEXT,
  state              TEXT,
  attempt_count      INTEGER,
  payload_json       JSONB
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_limit INTEGER;
BEGIN
  -- Clamp input to protect against runaway batch sizes.
  v_limit := GREATEST(1, LEAST(COALESCE(p_limit, 1), 20));

  RETURN QUERY
  WITH claimed AS (
    SELECT nj.id
      FROM notification_jobs nj
     WHERE nj.state = 'pending'
       AND nj.scheduled_at <= now()
       AND nj.attempt_count < 3
     ORDER BY nj.scheduled_at ASC
     LIMIT v_limit
       FOR UPDATE SKIP LOCKED
  ),
  flipped AS (
    UPDATE notification_jobs nj
       SET state = 'processing',
           attempt_count = nj.attempt_count + 1,
           updated_at = now()
     WHERE nj.id IN (SELECT c.id FROM claimed c)
     RETURNING nj.id,
               nj.canonical_user_key,
               nj.kind::TEXT AS kind,
               nj.state::TEXT AS state,
               nj.attempt_count,
               nj.payload_json
  )
  SELECT f.id,
         f.canonical_user_key,
         f.kind,
         'pending'::TEXT AS state,   -- caller sees the pre-flip snapshot
         f.attempt_count - 1 AS attempt_count,  -- and the pre-increment count
         f.payload_json
    FROM flipped f;
END
$$;

REVOKE ALL ON FUNCTION stir_claim_pending_jobs(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION stir_claim_pending_jobs(INTEGER) FROM authenticated;
REVOKE ALL ON FUNCTION stir_claim_pending_jobs(INTEGER) FROM anon;

COMMENT ON FUNCTION stir_claim_pending_jobs(INTEGER) IS
  'Atomic claim of up to N pending notification_jobs. Flips state to processing + increments attempt_count. Returns pre-flip snapshot. service-role only.';
