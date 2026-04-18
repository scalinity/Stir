-- Stir operational schema — usage_counters
-- Monthly metered quota counters, one row per (user, period, feature).
--
-- cap_count is SNAPSHOTTED at row creation from the active tier.
-- Mid-month tier upgrade does NOT mutate current-period rows; new rows at
-- the next period_start carry the upgraded cap. Non-metered entitlements
-- (voice access, favorites, widgets) flip immediately via entitlement_snapshots.
--
-- period_start is anchored to the user's app_users.created_at day-of-month
-- (not calendar month) — matches Apple subscription renewal pattern and
-- avoids mid-month cliffs for new signups.
--
-- Atomic quota check pattern (in handler):
--   UPDATE usage_counters
--      SET used_count = used_count + 1, updated_at = now()
--    WHERE canonical_user_key = $1 AND period_start = $2 AND feature_key = $3
--      AND used_count < cap_count
--   RETURNING used_count, cap_count;
-- Empty result = quota exhausted.
--
-- See CLAUDE.md "usage_counters feature keys and period semantics" section.

CREATE TYPE usage_feature_key AS ENUM (
  'dinner_solve',
  'voice_cook_session',
  'recipe_import'
);

CREATE TABLE IF NOT EXISTS usage_counters (
  canonical_user_key  TEXT NOT NULL REFERENCES app_users(canonical_user_key) ON DELETE CASCADE,
  period_start        DATE NOT NULL,
  feature_key         usage_feature_key NOT NULL,
  used_count          INTEGER NOT NULL DEFAULT 0,
  cap_count           INTEGER NOT NULL,
  tier_at_snapshot    user_tier NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (canonical_user_key, period_start, feature_key)
);

-- Used by admin dashboards aggregating by month.
CREATE INDEX IF NOT EXISTS idx_usage_counters_period
  ON usage_counters(period_start, canonical_user_key);

COMMENT ON TABLE  usage_counters                    IS 'Monthly metered quotas. Atomic UPDATE-WHERE-used<cap pattern in handlers.';
COMMENT ON COLUMN usage_counters.period_start       IS 'UTC date; user-anchored (account-creation day of month).';
COMMENT ON COLUMN usage_counters.feature_key        IS 'dinner_solve | voice_cook_session | recipe_import. Standing caps (pantry) not modeled here.';
COMMENT ON COLUMN usage_counters.cap_count          IS 'Snapshotted from tier at row creation; immutable for the period.';
COMMENT ON COLUMN usage_counters.tier_at_snapshot   IS 'Audit: which tier produced this row''s cap_count.';
