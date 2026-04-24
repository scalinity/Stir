-- Step-8 review C8 + C9 + W13 — performance index additions.
--
-- C8: app_users(last_seen_at DESC) WHERE status='active' — hot path for both
--     stir_ops_list_users default sort AND stir_ops_reactivation_enqueue
--     BETWEEN predicate. Pre-fix both seq-scan app_users at beta+1 scale.
--
-- C9: ai_request_log session_id UUID column + index — replaces
--     `request_id LIKE 'voice:%:%'` + `split_part(request_id, ':', 2)` in
--     stir_ops_list_voice_sessions and stir_ops_cost_anomaly_scan (voice
--     branch). Neither the LIKE nor the split_part are sargable; the
--     15-min cost-anomaly cron was on track to seq-scan the 24h window
--     (~400K rows at beta+1 scale). Session_id is backfilled from the
--     existing request_id format; voice-turn-usage (writing new rows)
--     populates it alongside request_id.
--
-- W13: supporting indexes for stir_ops_user_detail + reactivation DISTINCT
--      ON patterns that currently force in-memory sorts at scale:
--      - webhook_log(canonical_user_key, processed_at DESC) — user-detail
--        recent-webhooks subquery
--      - ops_flagged_outputs(canonical_user_key_hash, created_at DESC) WHERE
--        resolved_at IS NULL — user-detail flagged_open subquery
--      - device_installations(canonical_user_key, last_seen_at DESC) —
--        reactivation_enqueue DISTINCT ON sort

BEGIN;

-- 1. app_users(last_seen_at DESC) partial on active.
CREATE INDEX IF NOT EXISTS idx_app_users_last_seen_at
  ON app_users(last_seen_at DESC)
  WHERE status = 'active';

-- 2. ai_request_log.session_id — add column, backfill voice rows, index.
ALTER TABLE ai_request_log
  ADD COLUMN IF NOT EXISTS session_id UUID;

-- Backfill voice rows — parse the second ':' segment as UUID. Non-voice
-- rows retain session_id = NULL (partial index skips them). Guard with
-- regex check so malformed IDs don't raise.
UPDATE ai_request_log
   SET session_id = (split_part(request_id, ':', 2))::UUID
 WHERE session_id IS NULL
   AND feature_key = 'cook_mode_realtime'
   AND request_id ~ '^voice:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9]+$';

-- Partial composite — only voice rows populate session_id.
CREATE INDEX IF NOT EXISTS idx_ai_request_log_voice_session
  ON ai_request_log(feature_key, session_id, created_at DESC)
  WHERE feature_key = 'cook_mode_realtime' AND session_id IS NOT NULL;

COMMENT ON COLUMN ai_request_log.session_id IS 'Voice session id (UUID). Populated by voice-turn-usage alongside request_id=''voice:<session_id>:<turn_index>''. NULL for non-voice rows. Indexed via idx_ai_request_log_voice_session for ops aggregations.';

-- 3. webhook_log(canonical_user_key, processed_at DESC) — already partial
--    on canonical_user_key IS NOT NULL per migration 20260419000002. Extend
--    to include processed_at for the user-detail recent-webhooks sort.
DROP INDEX IF EXISTS idx_webhook_log_user;
CREATE INDEX IF NOT EXISTS idx_webhook_log_user
  ON webhook_log(canonical_user_key, processed_at DESC)
  WHERE canonical_user_key IS NOT NULL;

-- 4. ops_flagged_outputs open + user filter.
CREATE INDEX IF NOT EXISTS idx_ops_flagged_outputs_user_open
  ON ops_flagged_outputs(canonical_user_key_hash, created_at DESC)
  WHERE resolved_at IS NULL;

-- 5. device_installations composite for DISTINCT ON sort.
DROP INDEX IF EXISTS idx_device_installations_user;
CREATE INDEX IF NOT EXISTS idx_device_installations_user
  ON device_installations(canonical_user_key, last_seen_at DESC);

COMMIT;
