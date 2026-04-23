-- 20260422000009 — partial index on ai_request_log.prompt_cached_tokens
--
-- Supports the spec §9 cap-reversal trigger query:
--   SELECT AVG(prompt_cached_tokens::numeric / input_tokens)
--   FROM ai_request_log
--   WHERE feature_key = 'cook_mode_realtime'
--     AND prompt_cached_tokens IS NOT NULL
--     AND created_at > NOW() - INTERVAL '30 days'
--   ORDER BY created_at DESC LIMIT 100;
--
-- Partial (WHERE prompt_cached_tokens IS NOT NULL) to stay tiny — the
-- vast majority of ai_request_log rows are non-voice features that won't
-- have this column populated. Index only needs to cover the voice
-- subset where caching data matters.
--
-- created_at DESC matches the "rolling recent window" access pattern;
-- no need to include the column in the index tuple since the trigger
-- query filters by the IS NOT NULL predicate which the WHERE clause
-- already pre-filters.

CREATE INDEX IF NOT EXISTS ai_request_log_cached_tokens_idx
  ON ai_request_log (created_at DESC)
  WHERE feature_key = 'cook_mode_realtime' AND prompt_cached_tokens IS NOT NULL;

COMMENT ON INDEX ai_request_log_cached_tokens_idx IS
  'Partial index supporting the spec §9 cap-reversal trigger query (100-session rolling median of cachedContentTokenCount / promptTokenCount). Covers only cook_mode_realtime rows with non-NULL prompt_cached_tokens to stay tiny.';
