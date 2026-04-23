-- 20260422000008 — ai_request_log.prompt_cached_tokens
--
-- Observability column for Gemini Live implicit context caching. The Live
-- API's usageMetadata frame carries `cachedContentTokenCount` when
-- server-side caching fires on a turn. iOS accumulates it in
-- TurnUsageAccumulator.sumCachedContentTokens and forwards it on the
-- voice-turn-usage POST; this column captures it for dashboard math.
--
-- Why it matters: the step-6 cost model assumes caching is NOT firing on
-- Live (all prompt tokens priced at full rate). If it IS firing, real
-- costs are ~25% of the $0.75/M text rate on the cached portion, and our
-- $2.93/mo Premium projection is an overstatement. The cap-reversal
-- trigger in spec §9 ("raise caps when cachedContentTokenCount ≥ 50% of
-- promptTokenCount across 100-session sample") needs this column to be
-- measurable, not aspirational.
--
-- Nullable because non-voice features (dinner_solve, pantry_parse, etc.)
-- don't set it. Backward-compatible — existing writers that don't set
-- the column continue to write NULL. PostHog $ai_cache_read_input_tokens
-- (standard property) gets populated from this column via ai_observability.ts.

ALTER TABLE ai_request_log
  ADD COLUMN IF NOT EXISTS prompt_cached_tokens INTEGER;

COMMENT ON COLUMN ai_request_log.prompt_cached_tokens IS
  'Gemini Live cachedContentTokenCount (implicit caching). NULL when not applicable (non-voice feature) or caching not firing. PostHog $ai_cache_read_input_tokens sources from this column. Cap-reversal trigger in spec §9 measures cachedContentTokenCount / promptTokenCount ratio across rolling 100-session sample.';
