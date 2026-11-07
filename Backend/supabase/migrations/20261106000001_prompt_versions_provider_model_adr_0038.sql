-- 20261106000001 — prompt_versions.provider_model for the ADR 0038 providers
--
-- Text features run on Claude (AI_TEXT_PROVIDER=anthropic, the default) and
-- voice runs on OpenAI Realtime. provider_model is metadata: no handler
-- reads it to choose a model (each endpoint resolves its model through
-- `_shared/ai_text.ts` / `_shared/realtime_mint.ts`), and config-bootstrap
-- reports the live selection on the wire. This keeps the column — read by
-- the ops console — naming the models the default configuration serves.
--
-- Only enabled rows change: disabled historical versions keep the model
-- that actually served them. Templates are unchanged, so no version bump
-- and no rollout_pct change.

UPDATE prompt_versions
   SET provider_model = 'claude-haiku-5-5'
 WHERE is_enabled
   AND feature_key IN (
     'pantry_parse',
     'dinner_solve',
     'substitution',
     'recipe_step_rewrite',
     'cook_turn',
     'recipe_import',
     'grocery_generate'
   );

UPDATE prompt_versions
   SET provider_model = 'gpt-realtime-2.1-mini'
 WHERE is_enabled
   AND feature_key = 'cook_mode_realtime';
