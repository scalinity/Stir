-- Stir operational schema — webhook_log.status: TEXT → ENUM migration.
--
-- Review surfaced that `webhook_log.status` was TEXT while other status
-- columns in the schema (`app_users.status`, `entitlement_snapshots.billing_state`)
-- are native Postgres ENUMs per CLAUDE.md's "What NOT to reopen" rule on
-- ENUM columns. TEXT admits invalid values silently and breaks the
-- `idx_webhook_log_status_nonaccepted` partial-index filter semantics if
-- a bug writes an unrecognized string.
--
-- Migration plan:
--   1. Create webhook_log_status ENUM with the nine documented values
--      (including 'ignored' added in the step-5 review for events where
--      the handler explicitly skips).
--   2. Drop the partial index (depends on the column type).
--   3. ALTER COLUMN status TYPE webhook_log_status USING status::webhook_log_status.
--   4. Recreate the partial index on the new column type.
--
-- Existing rows: all values already written are valid members of the new
-- ENUM (the handler code only ever emitted these strings).

CREATE TYPE webhook_log_status AS ENUM (
  'accepted',
  'duplicate',
  'signature_invalid',
  'validation_failed',
  'unknown_event',
  'ignored',
  'alias_processed',
  'transfer_processed',
  'error'
);

-- Drop the partial index that references the old TEXT column.
DROP INDEX IF EXISTS idx_webhook_log_status_nonaccepted;

-- Coerce the column. USING ... ::webhook_log_status casts each existing
-- string via the ENUM's implicit conversion; any row with a value not in
-- the ENUM raises here, which is the intended safety net.
ALTER TABLE webhook_log
  ALTER COLUMN status TYPE webhook_log_status
  USING status::webhook_log_status;

-- Recreate the partial index against the ENUM column.
CREATE INDEX IF NOT EXISTS idx_webhook_log_status_nonaccepted
  ON webhook_log(status, processed_at DESC)
  WHERE status != 'accepted';

COMMENT ON TYPE webhook_log_status IS
  'RC webhook audit-log outcome. accepted=mutated state; duplicate=idempotent replay; signature_invalid=401 (not logged in practice); validation_failed=malformed body; unknown_event=RC type we do not handle; ignored=RC type we explicitly skip (e.g. NON_RENEWING_PURCHASE, unknown product); alias_processed/transfer_processed=identity merges; error=unexpected server failure.';
