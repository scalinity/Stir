-- Stir seed — prompt_versions placeholders
-- Seven feature_keys mirroring CLAUDE.md §"AI pipeline map". Each gets a
-- placeholder row at version = '0.0.0' with an empty template_blob. The
-- rows are is_default = TRUE so /v1/config/bootstrap returns the full list
-- on day one, but is_enabled = FALSE so nothing is served from them.
--
-- Later steps INSERT real prompt bodies at version = '1.0.0' and flip
-- is_default. The 0.0.0 rows stay as historical baselines.
--
-- Idempotent re-run via ON CONFLICT DO NOTHING on (feature_key, version).

INSERT INTO prompt_versions (feature_key, version, provider_model, template_blob, schema_hash, is_default, is_enabled, rollout_pct) VALUES
  ('pantry_parse',       '0.0.0', 'gemini-3-flash',                  '', '', TRUE, FALSE, 0),
  ('dinner_solve',       '0.0.0', 'gemini-3-flash',                  '', '', TRUE, FALSE, 0),
  ('cook_turn',          '0.0.0', 'gemini-3-flash',                  '', '', TRUE, FALSE, 0),
  ('cook_mode_realtime', '0.0.0', 'gemini-3.1-flash-live-preview',   '', '', TRUE, FALSE, 0),
  ('substitution',       '0.0.0', 'gemini-3-flash',                  '', '', TRUE, FALSE, 0),
  ('recipe_import',      '0.0.0', 'gemini-3.1-flash-lite',           '', '', TRUE, FALSE, 0),
  ('grocery_generate',   '0.0.0', 'gemini-3.1-flash-lite',           '', '', TRUE, FALSE, 0)
ON CONFLICT (feature_key, version) DO NOTHING;
