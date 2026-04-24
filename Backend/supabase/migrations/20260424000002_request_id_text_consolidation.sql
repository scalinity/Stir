-- Step-8 critical fix bundle (review C3 + C10 + W40):
--
--  1. ops_flagged_outputs.request_id     UUID → TEXT
--  2. audit_log.request_id               UUID → TEXT
--  3. UNIQUE(canonical_user_key_hash, request_id) on ops_flagged_outputs
--
-- Rationale
-- ─────────
-- ai_request_log.request_id is TEXT (migration 20260418000007); voice-turn
-- submissions write request_id in the format 'voice:<session_id>:<turn_index>'.
-- With ops_flagged_outputs.request_id declared UUID NOT NULL, every iOS
-- submission from voice Cook Mode hit SQLSTATE 22P02 and surfaced as an
-- opaque NET-01 500. The same mismatch exists on audit_log.request_id —
-- requestIdFrom() in _shared/logger.ts accepts /^[A-Za-z0-9_\-:.]{1,128}$/,
-- so any client-supplied non-UUID x-request-id silently dropped the audit
-- row via the non-fatal writeAudit catch.
--
-- The UNIQUE index replaces the handler's SELECT-then-INSERT dedup race —
-- concurrent double-taps now collapse to a single row via ON CONFLICT
-- DO NOTHING atomically. We deliberately move from "24h window" to "forever":
-- once a user has flagged a specific AI call, re-flagging it adds no new
-- information — the original flag was either resolved (cache removed or
-- replaced) or dismissed (admin reviewed, no change). A partial index on
-- WHERE created_at > now() - interval '24 hours' is NOT IMMUTABLE and would
-- be rejected by the planner.

BEGIN;

-- 1. ops_flagged_outputs.request_id — rebuild the indexed column.
DROP INDEX IF EXISTS idx_ops_flagged_outputs_request;

ALTER TABLE ops_flagged_outputs
  ALTER COLUMN request_id TYPE TEXT USING request_id::text;

CREATE INDEX idx_ops_flagged_outputs_request
  ON ops_flagged_outputs(request_id);

-- 2. UNIQUE (canonical_user_key_hash, request_id) — atomic dedup.
--    Handler uses INSERT ... ON CONFLICT DO NOTHING; existing row lookup
--    falls to the next SELECT. No race window.
CREATE UNIQUE INDEX idx_ops_flagged_outputs_dedup
  ON ops_flagged_outputs(canonical_user_key_hash, request_id);

-- 3. audit_log.request_id — match the client-accepted charset.
ALTER TABLE audit_log
  ALTER COLUMN request_id TYPE TEXT USING request_id::text;

-- 4. Update column comments to reflect new types.
COMMENT ON COLUMN ops_flagged_outputs.request_id IS 'Original AI call id from ai_request_log (TEXT — accepts UUID and ''voice:<session>:<turn>'' shapes). Joins flagged output → raw request/response for context.';
COMMENT ON COLUMN audit_log.request_id IS 'Edge Function request id for cross-referencing with Supabase logs / Sentry. TEXT (not UUID) to accept any x-request-id shape that requestIdFrom() passes.';

COMMIT;
