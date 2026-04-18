-- Stir operational schema — ai_request_log
-- Cost + reliability log. Row written at the end of every AI request in
-- steps 3+. Step 1 creates the schema only — no rows are written yet.
--
-- feature_key is intentionally TEXT (not an ENUM) because new AI features
-- may appear between migrations; we don't want prompt migrations blocked
-- on enum ALTER for a log column.
--
-- cost_usd is NUMERIC(10,6) — handles up to $9,999.999999 per row, enough
-- for any plausible single-request cost. The six decimal places cover
-- sub-cent Flash-Lite requests.
--
-- Partitioning is deliberately NOT applied in step 1. It becomes worth the
-- operational complexity somewhere north of ~1M rows/day. Revisit in step 8
-- (ops dashboards) or step 9 (beta scale).

CREATE TABLE IF NOT EXISTS ai_request_log (
  request_id          TEXT PRIMARY KEY,
  canonical_user_key  TEXT NOT NULL REFERENCES app_users(canonical_user_key) ON DELETE CASCADE,
  feature_key         TEXT NOT NULL,
  model               TEXT NOT NULL,
  input_tokens        INTEGER NOT NULL,
  output_tokens       INTEGER NOT NULL,
  cost_usd            NUMERIC(10, 6) NOT NULL,
  latency_ms          INTEGER NOT NULL,
  thinking_level      TEXT,
  prompt_version      TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Per-user timeline queries for support + abuse investigation.
CREATE INDEX IF NOT EXISTS idx_ai_request_log_user_created
  ON ai_request_log(canonical_user_key, created_at DESC);

-- Per-feature cost dashboards (step 8).
CREATE INDEX IF NOT EXISTS idx_ai_request_log_feature_created
  ON ai_request_log(feature_key, created_at DESC);

COMMENT ON TABLE  ai_request_log               IS 'Cost + reliability log. Row per AI call. Written by handlers in steps 3+.';
COMMENT ON COLUMN ai_request_log.request_id    IS 'Client-supplied x-request-id when present, else server-generated UUID.';
COMMENT ON COLUMN ai_request_log.feature_key   IS 'TEXT not ENUM — new AI features appear between migrations.';
COMMENT ON COLUMN ai_request_log.cost_usd      IS 'Per-request USD cost in NUMERIC(10,6). Aggregated nightly for dashboards.';
COMMENT ON COLUMN ai_request_log.thinking_level IS 'Gemini thinking level (minimal|low|medium|high); NULL for non-thinking models.';
