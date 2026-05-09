-- IN-PLACE EDIT (SCA-283, correctness-blocks-fresh-init exception per
-- CLAUDE.md §Schema truth):
--   Original SCA-278 body had substantial unintended drift from the
--   SCA-223 original in `20260508000007_stir_claim_deletion_requests.sql`:
--
--     1. RETURNS TABLE: changed `canonical_user_key_hash TEXT` to
--        `attempt_count INTEGER`. Postgres `CREATE OR REPLACE FUNCTION`
--        rejects OUT/RETURNS shape changes (42P13) — fresh
--        `supabase start` / `db reset` aborts here. Prod was unaffected
--        only because the same 42P13 rejected `supabase db push`, so
--        000009-000012 were never landed on prod.
--     2. Caller mismatch: `users-deletion-fulfill/index.ts:402,428`
--        consumes `row.canonical_user_key_hash`. If the broken shape
--        had ever applied (via DROP+CREATE), every deletion-fulfill
--        tick would silently null out canonicalUserKeyHash in
--        audit_log + PostHog distinct_id. Worse-than-fresh-init bug.
--     3. SET clause dropped `updated_at = now()` and added a spurious
--        `attempt_count = COALESCE(attempt_count, 0) + 1` increment.
--
--   The intended SCA-278 change was just adding the
--   `IF clamp THEN RAISE NOTICE` block — drift in (1)/(2)/(3) was
--   accidental.
--
--   Fix: revert RETURNS TABLE / RETURNING / SET clause to match
--   the SCA-223 original exactly, keeping the new RAISE NOTICE
--   block. With matching shape, CREATE OR REPLACE works (the live
--   prod function is byte-identical to 000007's body); only the
--   NOTICE block changes.
--
--   No new dated migration was viable because the broken migration
--   ABORTS fresh init, so a forward fix could never run.
--
-- ---------------------------------------------------------------------------
--
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

COMMENT ON FUNCTION stir_claim_deletion_requests(INTEGER) IS
  'SCA-88: atomic claim of approved deletion_requests for the cron worker. SKIP LOCKED for concurrency-safe multi-worker support. SCA-278: emits a NOTICE when p_limit gets clamped to [1, 20] so manual ops invocations with out-of-range inputs are visible.';
