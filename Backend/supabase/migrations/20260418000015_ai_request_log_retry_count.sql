-- Stir operational schema — ai_request_log.retry_count
--
-- Beta telemetry: track how many Gemini retries it took to produce a valid
-- response that passed hard-rule validation and JSON schema.
--
--   0 = first attempt succeeded
--   1 = one retry (rare; normal for dinner_solve when a single slot fails)
--   2 = two retries across slots, e.g. rank 1 and rank 2 each failed once
--   N = aggregate across all slot-level retries within one handler call
--
-- Used in step-3 beta to watch for elevated retry rates, which are the
-- earliest signal that a prompt needs a revision or a model drifted.
-- Nullable for historical rows; new inserts set it explicitly.

ALTER TABLE ai_request_log
  ADD COLUMN IF NOT EXISTS retry_count INTEGER NOT NULL DEFAULT 0;

COMMENT ON COLUMN ai_request_log.retry_count IS
  'Total Gemini retries for this handler invocation. 0 = first-try success. Watched in beta as prompt-quality signal.';
