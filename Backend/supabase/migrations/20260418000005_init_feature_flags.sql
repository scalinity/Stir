-- Stir operational schema — feature_flags
-- Server-side flags only. Client flags live in PostHog per spec §13 split.
--
-- payload_json wraps the flag's value in {"value": X} so we can extend
-- per-flag metadata later without migrating the value shape.
-- Wire shape (from /v1/config/bootstrap): { key, value, is_enabled, rollout_pct }.
-- Per-key Zod schemas live in functions/_shared/flags.ts (flag_registry).
--
-- Kill-switch semantics: flag is active iff `is_enabled && value === true`.
-- Config flag semantics: return `flag.is_enabled ? flag.value : <default>`.
--
-- rollout_pct is stored but not enforced in step 1 — rollout gating lands
-- when the first feature-flag-gated AI prompt rolls out in step 3+.

CREATE TABLE IF NOT EXISTS feature_flags (
  key           TEXT PRIMARY KEY,
  description   TEXT NOT NULL,
  payload_json  JSONB NOT NULL,        -- always {"value": <scalar|object>}
  is_enabled    BOOLEAN NOT NULL DEFAULT TRUE,
  rollout_pct   INTEGER NOT NULL DEFAULT 100 CHECK (rollout_pct BETWEEN 0 AND 100),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  feature_flags              IS 'Server-side flags. Client flags are PostHog-side (spec §13).';
COMMENT ON COLUMN feature_flags.payload_json IS 'Always shape {"value": X}; X is scalar or object depending on key.';
COMMENT ON COLUMN feature_flags.is_enabled   IS 'Master switch. FALSE means consumers must use the key''s default value.';
COMMENT ON COLUMN feature_flags.rollout_pct  IS 'Reserved for gradual rollout in step 3+; not enforced in step 1.';
