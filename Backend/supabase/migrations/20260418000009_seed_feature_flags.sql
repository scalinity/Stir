-- Stir seed — server-side feature flags
-- Client-facing flags (paywall_variant, voice_turn_detection_mode, etc.)
-- live in PostHog per spec §13 and are NOT seeded here.
--
-- Values match CLAUDE.md §"Feature flags" for server-side + kill switches.
-- Idempotent re-run via ON CONFLICT DO NOTHING.

INSERT INTO feature_flags (key, description, payload_json, is_enabled, rollout_pct) VALUES
  (
    'disable_cook_realtime',
    'Kill switch. When value=true, /v1/ai/realtime-session returns error and iOS voice falls back to text path with AI-VOICE-01 banner.',
    '{"value": false}',
    TRUE, 100
  ),
  (
    'disable_scan_parse',
    'Kill switch. When value=true, /v1/ai/pantry-parse returns error; iOS pantry scan degrades to manual entry.',
    '{"value": false}',
    TRUE, 100
  ),
  (
    'disable_imports',
    'Kill switch. When value=true, /v1/ai/recipe-import returns error; share extension shows IMPORT-01 until flag flips.',
    '{"value": false}',
    TRUE, 100
  ),
  (
    'force_saved_meals_only',
    'Kill switch. When value=true, all AI generation is blocked and the app operates on saved meals + manual paths only.',
    '{"value": false}',
    TRUE, 100
  ),
  (
    'priority_queue_pro_enabled',
    'Gate for Pro-tier priority inference queue. Value=true activates queue-skip behavior in step 3+.',
    '{"value": false}',
    TRUE, 100
  ),
  (
    'cook_voice_thinking_level',
    'Gemini Live thinkingLevel override. Values: "minimal" (default) or "low" (escalation path if reasoning proves insufficient).',
    '{"value": "minimal"}',
    TRUE, 100
  ),
  (
    'prompt_version_override',
    'Optional override mapping feature_key -> version string, used for canary/rollback in steps 3+. NULL = use is_default row.',
    '{"value": null}',
    TRUE, 100
  ),
  (
    'recipe_import_async_threshold',
    'Byte threshold for recipe_import raw text; above this we push to pgmq for async processing (step 7). Default 8 KiB.',
    '{"value": 8192}',
    TRUE, 100
  )
ON CONFLICT (key) DO NOTHING;
