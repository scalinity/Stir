-- Stir operational schema — audit_log
-- Step 8: immutable record of every admin mutation that changes state
-- observable to users (ban / unban, quota reset, force-reauth, prompt
-- rollout, feature flag toggle, flagged-output resolve).
--
-- Append-only posture:
--   - Authenticated admins can SELECT via is_admin() (so the ops SPA
--     Audit Log page works).
--   - No UPDATE policy. No DELETE policy. Audit entries are immutable.
--   - Writes happen only via service-role client from Edge Functions.
--     _shared/audit.ts::writeAudit is the single call site. Never
--     insert from SQL directly.
--
-- Retention: 90-day trim via pg_cron job (lands in migration
-- 20260423000010_scheduled_jobs_step8.sql). Rationale matches
-- webhook_log (migration 20260419000002): evidence for dispute /
-- support cases + regulatory "we can reconstruct who did what"
-- without retaining raw ops actions forever. Spec §11 does NOT name
-- audit_log in its retention table — the 90-day cadence follows the
-- existing webhook_log precedent rather than a spec rule.

CREATE TABLE IF NOT EXISTS audit_log (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Nullable: system-automation writes (e.g., pg_cron-scheduled flag
  -- rollouts) carry NULL actor. Admin-initiated writes carry the
  -- authenticated auth.users.id.
  actor_id       UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  -- Email snapshot at write time. Survives auth.users deletion.
  actor_email    TEXT,
  -- Dotted action name. Examples:
  --   users.status.updated       users.reset_quota
  --   users.force_reauth         flagged_outputs.resolved
  --   prompt_versions.rollout    feature_flags.updated
  action         TEXT NOT NULL CHECK (length(action) <= 128),
  target_table   TEXT NOT NULL CHECK (length(target_table) <= 128),
  target_id      TEXT NOT NULL CHECK (length(target_id) <= 256),
  before_json    JSONB,
  after_json     JSONB,
  -- request_id pulled from the ops-admin Edge Function's requestIdFrom().
  -- Nullable so non-HTTP-initiated writes (cron jobs) can still log.
  request_id     UUID,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Recent-first browse (ops SPA Audit Log page primary sort).
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at
  ON audit_log(created_at DESC);

-- "What did this admin do?" — per-actor audit trail.
CREATE INDEX IF NOT EXISTS idx_audit_log_actor
  ON audit_log(actor_id, created_at DESC)
  WHERE actor_id IS NOT NULL;

-- "What happened to this row?" — per-target audit trail.
CREATE INDEX IF NOT EXISTS idx_audit_log_target
  ON audit_log(target_table, target_id, created_at DESC);

-- Action-class filter ("all prompt rollouts", "all bans").
CREATE INDEX IF NOT EXISTS idx_audit_log_action
  ON audit_log(action, created_at DESC);

ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;

-- Admin read-only access.
CREATE POLICY audit_log_admin_select ON audit_log
  FOR SELECT TO authenticated
  USING (public.is_admin());

-- Intentionally NO INSERT / UPDATE / DELETE policies. Append-only from
-- service-role only. Authenticated admins can only SELECT. If we ever
-- need a "clear my audit mistake" path, it should go through a
-- SECURITY DEFINER RPC that writes a compensating entry (never
-- deletes), so the audit trail itself remains tamper-evident.

COMMENT ON TABLE  audit_log               IS 'Immutable record of admin mutations. Append-only — no UPDATE/DELETE policy for authenticated. 90-day retention via pg_cron (matches webhook_log precedent, not spec §11).';
COMMENT ON COLUMN audit_log.actor_id      IS 'auth.users.id of the admin. NULL for system-automation writes (pg_cron rollouts, etc.).';
COMMENT ON COLUMN audit_log.actor_email   IS 'Snapshot of actor email at write time. Survives auth.users deletion.';
COMMENT ON COLUMN audit_log.action        IS 'Dotted name: <subject>.<verb>. E.g., users.reset_quota, flagged_outputs.resolved.';
COMMENT ON COLUMN audit_log.target_table  IS 'Table whose row was modified. Informational; not a FK since the target may be application-level (e.g., a synthetic "voice_session_refresh_trigger").';
COMMENT ON COLUMN audit_log.target_id     IS 'Row PK serialized as TEXT (UUIDs, canonical_user_keys, feature_flag keys, prompt_version ids all fit).';
COMMENT ON COLUMN audit_log.before_json   IS 'Target row pre-mutation. NULL for pure-inserts (no before-state).';
COMMENT ON COLUMN audit_log.after_json    IS 'Target row post-mutation. NULL for pure-deletes.';
COMMENT ON COLUMN audit_log.request_id   IS 'Edge Function request id for cross-referencing with Supabase logs / Sentry. NULL for non-HTTP writes.';
