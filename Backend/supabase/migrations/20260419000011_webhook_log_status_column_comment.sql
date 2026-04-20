-- Sync the webhook_log.status column COMMENT with the ENUM.
--
-- Migration 2 set the initial column comment against the TEXT column, listing
-- 8 values. Migration 6 later flipped the column type to `webhook_log_status`
-- ENUM and added 'ignored' (as well as 'duplicate', which was implicit in the
-- status sentinel but not in the original comment). The TYPE now carries the
-- canonical enumeration (see migration 6's COMMENT ON TYPE), but
-- `\d+ webhook_log` shows column and type comments separately — the stale
-- column comment was misleading readers of the schema.
--
-- No data change; comment-only migration.

COMMENT ON COLUMN webhook_log.status IS
  'Outcome of the webhook delivery. Canonical value set lives on the webhook_log_status ENUM type — see its COMMENT.';
