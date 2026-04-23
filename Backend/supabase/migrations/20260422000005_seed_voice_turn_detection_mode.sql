-- C.5 — voice_turn_detection_mode feature flag
--
-- VAD profile switch baked into the Gemini Live mint body by
-- `_shared/live_mint.ts`. `semantic_vad` is the tuned-for-kitchen
-- profile (silenceDurationMs=800 + LOW sensitivity, validated
-- 2026-04-20..22). `server_vad` is the escape hatch that passes only
-- `{ disabled: false }` and lets Gemini use its defaults — enables a
-- same-day ops flip without an iOS release if the tuned profile
-- regresses for a user segment.
--
-- Categorized as Supabase-backed despite CLAUDE.md's "Client (PostHog)"
-- aspirational classification: the flag is consumed at mint time
-- server-side (where the VAD block is composed), so Supabase is the
-- correct source of truth. Same pattern as cook_voice_thinking_level.
--
-- Idempotent via ON CONFLICT DO NOTHING so re-runs are safe.

INSERT INTO feature_flags (key, description, payload_json, is_enabled, rollout_pct) VALUES
  (
    'voice_turn_detection_mode',
    'Gemini Live VAD profile. Values: "semantic_vad" (default; tuned silence/sensitivity for kitchen noise) or "server_vad" (escape hatch; Gemini defaults only).',
    '{"value": "semantic_vad"}',
    TRUE, 100
  )
ON CONFLICT (key) DO NOTHING;
