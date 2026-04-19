-- Correct phantom provider_model strings seeded in migrations 10, 16, 23.
--
-- Investigation 2026-04-19 during the step-6 Gemini Live spike: model names
-- `gemini-3-flash` and `gemini-3.1-flash-lite` DO NOT EXIST on Google's
-- Generative Language API. `models.list` returns 52 models; the real names
-- are `gemini-3-flash-preview` and `gemini-3.1-flash-lite-preview`. Every
-- prompt row that encodes a non-preview name would 404 when called.
--
-- Root cause: CLAUDE.md pre-dated the actual Gemini 3 release and recorded
-- the pre-release/aspirational model names. Prompt-versions seeds (and the
-- gemini.ts enum) followed CLAUDE.md verbatim.
--
-- Scope: updates existing prompt_versions rows only. Does not change schema.
-- Migrations 10, 16, 23 stay as the historical record of what was seeded;
-- this migration records the correction.
--
-- Idempotent: updates are no-ops on rows where provider_model already has
-- the correct suffix.

UPDATE prompt_versions
   SET provider_model = 'gemini-3-flash-preview'
 WHERE provider_model = 'gemini-3-flash';

UPDATE prompt_versions
   SET provider_model = 'gemini-3.1-flash-lite-preview'
 WHERE provider_model = 'gemini-3.1-flash-lite';

-- Leave gemini-3.1-flash-live-preview rows untouched — that name IS correct.
