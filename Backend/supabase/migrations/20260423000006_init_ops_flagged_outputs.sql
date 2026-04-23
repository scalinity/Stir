-- Stir operational schema — ops_flagged_outputs
-- Step 8: flagged AI output review queue. Populated by:
--   - iOS users via POST /v1/ops/flag-output  → flagged_by='user'
--   - Admin console via ops-admin router      → flagged_by='admin'
--   - Auto-detection (future, e.g., hard-rule validator failures) → flagged_by='system'
--
-- Resolution actions (ADR 0023 §D3):
--   - `dismissed`                passive review — "we looked, no change needed"
--   - `withdrawn`                active removal — the ai_response_cache row
--                                 for (canonical_user_key, request_id) is DELETED
--                                 so a retry won't re-serve the bad output.
--                                 The Edge Function handling resolve executes
--                                 the cache delete.
--   - `canned_fallback_pinned`   replacement — canned_fallback_json replaces
--                                 the cached response; future (canonical_user_key,
--                                 request_id) lookups return the safe body.
--
-- Privacy: canonical_user_key_hash is a SHA-256 truncated to 16 chars (the
-- same pattern ai_observability.ts uses for PostHog distinct_id). Raw
-- canonical keys never land here — support workflows that need to reach
-- the actual user start from the request_id + ai_request_log.
--
-- Raw input/output are captured at flag time from ai_request_log /
-- ai_response_cache. Retention: no auto-trim in step 8. A flagged output
-- is evidence; we keep it until an admin resolves. Resolved rows stay
-- forever for audit. Daniel may add retention later.
--
-- RLS: SELECT/UPDATE via is_admin(). INSERT never via authenticated — both
-- user-flag path (ops-flag-output) and admin-flag path (ops-admin) use the
-- service-role client. This keeps iOS out of the ops table.

CREATE TYPE ops_flag_source AS ENUM ('user', 'admin', 'system');

CREATE TYPE ops_flag_resolution_action AS ENUM (
  'dismissed',
  'withdrawn',
  'canned_fallback_pinned'
);

CREATE TABLE IF NOT EXISTS ops_flagged_outputs (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_user_key_hash  TEXT NOT NULL,
  feature_key              TEXT NOT NULL,
  request_id               UUID NOT NULL,
  flagged_by               ops_flag_source NOT NULL,
  flag_reason              TEXT NOT NULL CHECK (length(flag_reason) <= 2000),
  context_snapshot_json    JSONB,
  raw_input_json           JSONB,
  raw_output_json          JSONB,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at              TIMESTAMPTZ,
  resolved_by              UUID REFERENCES auth.users(id) ON DELETE SET NULL,
  resolution_action        ops_flag_resolution_action,
  resolution_notes         TEXT,
  canned_fallback_json     JSONB,

  -- Resolution bookkeeping invariants.
  CONSTRAINT ops_flagged_outputs_resolution_consistency CHECK (
    (resolved_at IS NULL
      AND resolved_by IS NULL
      AND resolution_action IS NULL
      AND canned_fallback_json IS NULL)
    OR
    (resolved_at IS NOT NULL
      AND resolution_action IS NOT NULL
      -- resolved_by MAY be null if the admin auth row was later removed
      -- (ON DELETE SET NULL on the FK).
      -- canned_fallback_json required iff action='canned_fallback_pinned'.
      AND (
        (resolution_action = 'canned_fallback_pinned' AND canned_fallback_json IS NOT NULL)
        OR
        (resolution_action <> 'canned_fallback_pinned' AND canned_fallback_json IS NULL)
      ))
  )
);

-- Primary review-queue lookup: "show me open flags, newest first".
CREATE INDEX IF NOT EXISTS idx_ops_flagged_outputs_open
  ON ops_flagged_outputs(created_at DESC)
  WHERE resolved_at IS NULL;

-- Per-feature filter on the admin console "show all cook_turn flags".
CREATE INDEX IF NOT EXISTS idx_ops_flagged_outputs_feature
  ON ops_flagged_outputs(feature_key, created_at DESC);

-- Lookup by request_id: used when ops-flag-output checks "has this
-- request already been flagged by the same user?" (dedup at insert time).
CREATE INDEX IF NOT EXISTS idx_ops_flagged_outputs_request
  ON ops_flagged_outputs(request_id);

-- Per-resolver audit ("what did this admin handle?").
CREATE INDEX IF NOT EXISTS idx_ops_flagged_outputs_resolver
  ON ops_flagged_outputs(resolved_by, resolved_at DESC)
  WHERE resolved_by IS NOT NULL;

ALTER TABLE ops_flagged_outputs ENABLE ROW LEVEL SECURITY;

CREATE POLICY ops_flagged_outputs_admin_select ON ops_flagged_outputs
  FOR SELECT TO authenticated
  USING (public.is_admin());

CREATE POLICY ops_flagged_outputs_admin_update ON ops_flagged_outputs
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- No INSERT / DELETE policies for authenticated. Service role bypasses
-- RLS and handles both.

COMMENT ON TABLE  ops_flagged_outputs                       IS 'AI output review queue. See ADR 0023 §D3 for the three-action resolution enum.';
COMMENT ON COLUMN ops_flagged_outputs.canonical_user_key_hash IS 'SHA-256(canonical_user_key), 16-char truncation. Matches ai_observability.ts PostHog distinct_id pattern. Raw keys never stored here.';
COMMENT ON COLUMN ops_flagged_outputs.feature_key           IS 'dinner_solve | substitution | cook_turn | recipe_import | pantry_parse | grocery_generate | cook_mode_realtime. TEXT (not ENUM) to match ai_request_log.';
COMMENT ON COLUMN ops_flagged_outputs.request_id            IS 'Original AI call id from ai_request_log. Joins flagged output → raw request/response for context.';
COMMENT ON COLUMN ops_flagged_outputs.flagged_by            IS 'user | admin | system';
COMMENT ON COLUMN ops_flagged_outputs.flag_reason           IS 'User- or admin-entered reason text. Max 2000 chars.';
COMMENT ON COLUMN ops_flagged_outputs.context_snapshot_json IS 'Feature-specific context at flag time (e.g., recipe_plan_id, step_index, current_step_number).';
COMMENT ON COLUMN ops_flagged_outputs.raw_input_json        IS 'Captured from ai_request_log.request_payload (or equivalent) at flag time.';
COMMENT ON COLUMN ops_flagged_outputs.raw_output_json       IS 'Captured from ai_response_cache.response_body at flag time.';
COMMENT ON COLUMN ops_flagged_outputs.resolution_action     IS 'dismissed (no change) | withdrawn (cache deleted) | canned_fallback_pinned (cache replaced with canned_fallback_json).';
COMMENT ON COLUMN ops_flagged_outputs.canned_fallback_json  IS 'Only populated when resolution_action=canned_fallback_pinned. The safe replacement body to serve on retry.';
