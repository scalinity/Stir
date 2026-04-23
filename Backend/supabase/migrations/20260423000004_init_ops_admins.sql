-- Stir operational schema — ops_admins + is_admin()
-- Step 8 foundation: link table between Supabase Auth users and Stir admin
-- role. See ADR 0023 "Admin auth via Supabase Auth + ops_admins" for the
-- full rationale.
--
-- Authorization shape:
--   - Ops console users log in via Supabase Auth magic link. Their JWT
--     carries a standard Supabase `sub` claim (UUID from auth.users.id).
--   - `ops_admins` is a link table: presence = admin. Absence = not admin.
--   - `is_admin()` reads auth.uid() and checks membership. It's STABLE
--     SECURITY DEFINER so it can be safely called from RLS USING clauses
--     on ops-only tables (ops_flagged_outputs, audit_log, cost_anomalies).
--
-- Separation from iOS session JWTs:
--   - iOS session JWTs carry `canonical_user_key` in `sub` (a string like
--     `ck:<record>` or `install:<uuid>`), which is NOT a UUID. Supabase's
--     `auth.uid()` casts sub to UUID and raises SQLSTATE 22P02 on non-UUID
--     input. is_admin() catches that exception and returns false.
--   - Double gate: Edge Functions also call _shared/admin_auth.verifyAdminAuth
--     which explicitly rejects iOS session JWTs at the boundary (iss claim
--     mismatch). See ADR 0023 for the aud + iss + ops_admins layering.
--
-- Provisioning: manual only. Add admins via:
--   INSERT INTO ops_admins (auth_user_id, email, notes)
--   VALUES ('<uuid>', 'admin@example.com', 'seeded 2026-04-23');
-- No self-signup flow in v1. See docs/runbooks/ops-admin-provisioning.md.

CREATE TABLE IF NOT EXISTS ops_admins (
  auth_user_id UUID         PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  email        TEXT         NOT NULL,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  notes        TEXT
);

-- Supports fast lookup by email when we only know the admin's login
-- (e.g., manual provisioning verification).
CREATE INDEX IF NOT EXISTS idx_ops_admins_email ON ops_admins(email);

ALTER TABLE ops_admins ENABLE ROW LEVEL SECURITY;

-- An admin can SELECT their own row (used by the ops SPA's "am I admin?"
-- probe that decides whether to render the "not authorized" page or
-- proceed to the dashboard). Service role (and is_admin-gated RPCs)
-- bypass RLS.
CREATE POLICY ops_admins_self_select ON ops_admins
  FOR SELECT
  TO authenticated
  USING (auth_user_id = auth.uid());

-- Non-SELECT grants are deliberately omitted. Admin lifecycle (add /
-- remove / rename) goes through the SQL editor or a service-role Edge
-- Function, never through PostgREST-authenticated calls.

-- ---------------------------------------------------------------------------
-- is_admin()
-- ---------------------------------------------------------------------------
--
-- Defensive against non-UUID `sub` claims: iOS session JWTs carry
-- sub = canonical_user_key (e.g. `install:<uuid>` or `ck:<record>`), which
-- is NOT a UUID. PostgREST's `auth.uid()` helper casts request.jwt.claim.sub
-- to UUID and raises `invalid_text_representation` (SQLSTATE 22P02) on
-- non-UUID input. We catch that case and return false rather than letting
-- the exception bubble up through RLS USING clauses and 500 the request.

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, auth
AS $$
DECLARE
  caller UUID;
BEGIN
  -- Broad fail-closed guard. auth.uid() can raise on at least two paths:
  --   1. request.jwt.claim.sub is a non-UUID string (iOS session JWT).
  --   2. request.jwt.claims JSONB contains sub="" (observed with the
  --      service-role demo JWT in some Supabase releases — empty string
  --      gets coalesced back onto the ::uuid cast).
  -- Any failure here means "we can't confirm the caller is an admin" —
  -- which is exactly the state we want is_admin() to return false in.
  -- Rather than enumerate SQLSTATEs, catch OTHERS. The function is only
  -- used for authorization checks; fail-closed is the only correct posture.
  --
  -- RAISE WARNING surfaces unexpected exceptions in Postgres logs without
  -- masking bugs. Expected cases (iOS JWT, service-role demo JWT) still
  -- emit the warning; accept that noise — the cost of missing a real bug
  -- by silent-catch is worse than the cost of a busy log line.
  -- Documented in ADR 0023 Notes.
  BEGIN
    caller := auth.uid();
  EXCEPTION
    WHEN OTHERS THEN
      RAISE WARNING 'is_admin() caught exception from auth.uid() (SQLSTATE %): %',
        SQLSTATE, SQLERRM;
      RETURN false;
  END;

  IF caller IS NULL THEN
    RETURN false;
  END IF;

  RETURN EXISTS (
    SELECT 1 FROM public.ops_admins
    WHERE auth_user_id = caller
  );
END $$;

-- Grant EXECUTE so RLS USING (is_admin()) clauses can evaluate under
-- the authenticated role's session. The function itself is SECURITY
-- DEFINER so the ops_admins lookup runs with owner privileges (not
-- the caller's; the authenticated role can only see own row via RLS).
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
-- Service role already has ALL privileges; explicit grant is a no-op
-- but documents intent.
GRANT EXECUTE ON FUNCTION public.is_admin() TO service_role;

COMMENT ON TABLE  ops_admins                 IS 'Stir admin link table. Row = admin. Provisioned manually. See ADR 0023.';
COMMENT ON COLUMN ops_admins.auth_user_id    IS 'Supabase auth.users.id. ON DELETE RESTRICT prevents orphaning admin rows if an auth user is removed — drop the admin row first.';
COMMENT ON COLUMN ops_admins.email           IS 'Snapshot of admin email at provisioning time. For display only; source of truth is auth.users.';
COMMENT ON COLUMN ops_admins.notes           IS 'Free-form provisioning notes (e.g., "founder seed 2026-04-23", "rotated in for oncall 2026-07").';
COMMENT ON POLICY ops_admins_self_select      ON ops_admins IS 'Authenticated admins can only SELECT their own row. Enables SPA "am I admin?" probe; no cross-admin enumeration.';
COMMENT ON FUNCTION public.is_admin()         IS 'Returns true iff auth.uid() has a matching ops_admins row. SECURITY DEFINER so RLS USING clauses can call it without needing direct SELECT on ops_admins. iOS session JWTs lack a valid auth.users sub → returns false.';
