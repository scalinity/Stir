-- SCA-157: read pgmq-dispatch shared secret from Supabase Vault.
--
-- Background: managed Supabase blocks `ALTER DATABASE postgres SET
-- "app.stir_pgmq_dispatch_secret" = ...` (ERROR 42501 — only the
-- platform's superuser can grant settability for the `app.*` GUC
-- class). The cron registration in 20260508000003 / 000004 reads
-- this GUC; with the GUC unsettable, the cron has no way to send the
-- `X-Stir-Cron-Secret` header. The moment SCA-157 set the matching
-- function-side env (`STIR_PGMQ_DISPATCH_SECRET`), every cron tick
-- started 401-ing.
--
-- Verified prod state pre-this-migration:
--   * Function env: STIR_PGMQ_DISPATCH_SECRET is set
--   * GUC: NULL (platform-blocked)
--   * Cron command: bare `Content-Type: application/json` header
--   * net._http_response: every cron tick returning 401
--
-- Fix: Supabase Vault (`vault.decrypted_secrets`) is enabled on the
-- project and is queryable from SECURITY DEFINER functions without
-- needing the `app.*` GUC settability. Move the secret read there.
--
-- This migration:
--   1. Defines `public._register_pgmq_dispatch_cron()` reading from
--      `vault.decrypted_secrets` for the secret. Hardcoded URL stays
--      (per ADR 0031); only the secret read changes.
--   2. Calls the function at apply time. Behavior:
--        - Vault entry missing → registers cron with bare header
--          (same fail-open posture as 000003/000004; queue drains
--          unauthenticated until the operator inserts the secret).
--        - Vault entry present → registers cron with X-Stir-Cron-Secret
--          header carrying the Vault value.
--   3. Updates `stir_pgmq_dispatch_trigger_once` to read from Vault
--      too, so cron + manual paths are symmetric.
--
-- Operator follow-up (manual, run from the Supabase SQL editor as
-- service_role / project owner):
--
--   -- 1. Insert the shared secret into Vault. Use the SAME value
--   --    currently set on the function-side `STIR_PGMQ_DISPATCH_SECRET`
--   --    env var. If you don't have that value, generate a new 32-byte
--   --    hex (`openssl rand -hex 32`), insert it here, then update the
--   --    function env to match via `supabase secrets set`.
--   SELECT vault.create_secret(
--     '<32-byte-hex-secret>',
--     'stir_pgmq_dispatch_secret',
--     'pgmq-dispatch cron-to-function shared secret. Rotated quarterly. SCA-157.'
--   );
--
--   -- 2. Re-register the cron now that the secret exists in Vault.
--   --    The function will read `vault.decrypted_secrets` and rebuild
--   --    the cron command with the X-Stir-Cron-Secret header.
--   SELECT public._register_pgmq_dispatch_cron();
--
--   -- 3. Confirm the cron now succeeds (give it 30s after re-register
--   --    so the next tick fires):
--   SELECT status_code, count(*)
--   FROM net._http_response
--   WHERE created > now() - interval '5 minutes'
--   GROUP BY status_code;
--   -- Expect: 200 (or whatever the function returns on a healthy
--   -- empty-queue tick) — NOT 401.
--
-- Rotation procedure (for the SCA-149 quarterly runbook):
--   1. Generate a new 32-byte hex.
--   2. UPDATE vault.secrets WITH the new value:
--        SELECT vault.update_secret(
--          (SELECT id FROM vault.secrets WHERE name='stir_pgmq_dispatch_secret'),
--          '<new-32-byte-hex>'
--        );
--   3. SELECT public._register_pgmq_dispatch_cron();
--   4. supabase secrets set STIR_PGMQ_DISPATCH_SECRET=<same-new-hex>
--   5. Verify via the net._http_response query above.

-- Idempotent function. Replaces the inline DO block from migration
-- 000004 — that block ran once at apply time only. This function is
-- callable on demand to re-register after a Vault rotation.
CREATE OR REPLACE FUNCTION public._register_pgmq_dispatch_cron()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_url      TEXT := 'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch';
  v_dispatch_secret TEXT;
  v_headers         JSONB;
  v_command         TEXT;
  v_existing        TEXT;
BEGIN
  IF current_database() != 'postgres' THEN
    RETURN format('skipped: database=%s, not prod', current_database());
  END IF;

  -- Read the secret from Vault. NULL if not yet inserted.
  SELECT decrypted_secret
  INTO v_dispatch_secret
  FROM vault.decrypted_secrets
  WHERE name = 'stir_pgmq_dispatch_secret';

  IF v_dispatch_secret IS NULL OR v_dispatch_secret = '' THEN
    v_headers := '{"Content-Type": "application/json"}'::jsonb;
    RAISE NOTICE 'pgmq-dispatch: vault entry stir_pgmq_dispatch_secret missing — registering with bare header (fail-open).';
  ELSE
    v_headers := jsonb_build_object(
      'Content-Type',       'application/json',
      'X-Stir-Cron-Secret', v_dispatch_secret
    );
  END IF;

  v_command := format(
    $job$
          SELECT net.http_post(
            url := %L,
            headers := %L::jsonb,
            body := '{}'::jsonb,
            timeout_milliseconds := 25000
          );
        $job$,
    v_target_url,
    v_headers::text
  );

  -- Idempotent re-registration.
  SELECT command INTO v_existing
  FROM cron.job
  WHERE jobname = 'stir-pgmq-dispatch';

  IF v_existing IS NOT NULL AND v_existing = v_command THEN
    RETURN 'no-op: cron already registered with current secret state';
  END IF;

  IF v_existing IS NOT NULL THEN
    PERFORM cron.unschedule('stir-pgmq-dispatch');
  END IF;

  PERFORM cron.schedule(
    'stir-pgmq-dispatch',
    '*/30 * * * * *',
    v_command
  );

  IF v_dispatch_secret IS NULL THEN
    RETURN 'registered: cron with bare header (Vault entry missing)';
  ELSE
    RETURN 'registered: cron with X-Stir-Cron-Secret header from Vault';
  END IF;
END
$$;

COMMENT ON FUNCTION public._register_pgmq_dispatch_cron() IS
  'SCA-157: idempotent cron re-registration. Reads stir_pgmq_dispatch_secret from vault.decrypted_secrets. Run after vault.create_secret() / vault.update_secret() to pick up new values.';

-- Apply at migration time. If Vault is empty (first-apply state), this
-- registers the bare-header cron — same as the prior migration's
-- behavior. Operator follow-up populates Vault and re-runs.
DO $$
DECLARE
  v_result TEXT;
BEGIN
  v_result := public._register_pgmq_dispatch_cron();
  RAISE NOTICE 'pgmq-dispatch register result: %', v_result;
END
$$;

-- Update the manual-trigger function to read from Vault too. Cron and
-- manual paths share the same secret source — no split-brain.
CREATE OR REPLACE FUNCTION public.stir_pgmq_dispatch_trigger_once()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_target_url      TEXT := 'https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/pgmq-dispatch';
  v_dispatch_secret TEXT;
  v_headers         JSONB;
  v_request_id      BIGINT;
BEGIN
  -- Local-dev override: only honor app.supabase_url GUC on non-prod.
  IF current_database() != 'postgres'
     AND current_setting('app.supabase_url', TRUE) IS NOT NULL
     AND current_setting('app.supabase_url', TRUE) != '' THEN
    v_target_url := current_setting('app.supabase_url') || '/functions/v1/pgmq-dispatch';
  END IF;

  -- Read secret from Vault on prod. On non-prod databases (where Vault
  -- isn't typically populated), this will be NULL and we'll fall through
  -- to the bare-header path — matching the local-dev convention.
  IF current_database() = 'postgres' THEN
    SELECT decrypted_secret
    INTO v_dispatch_secret
    FROM vault.decrypted_secrets
    WHERE name = 'stir_pgmq_dispatch_secret';
  END IF;

  IF v_dispatch_secret IS NULL OR v_dispatch_secret = '' THEN
    v_headers := '{"Content-Type": "application/json"}'::jsonb;
  ELSE
    v_headers := jsonb_build_object(
      'Content-Type',         'application/json',
      'X-Stir-Cron-Secret',   v_dispatch_secret
    );
  END IF;

  -- Defense-in-depth against session-scope GUC override (CWE-918).
  RESET app.supabase_url;

  SELECT net.http_post(
    url := v_target_url,
    headers := v_headers,
    body := '{"trigger": "manual"}'::jsonb,
    timeout_milliseconds := 25000
  ) INTO v_request_id;

  RETURN format('dispatched manual pgmq-dispatch request id=%s url=%s', v_request_id, v_target_url);
END
$$;

COMMENT ON FUNCTION public.stir_pgmq_dispatch_trigger_once() IS
  'SCA-157: manual pgmq-dispatch trigger. Prod uses literal URL + Vault-backed secret read. Local dev honors app.supabase_url GUC. RESETs app.supabase_url at entry to defend against session-scope override (CWE-918).';
