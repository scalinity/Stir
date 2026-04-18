-- Stir operational schema — entitlement_snapshots
-- Current plan state per canonical_user_key. One row per user.
-- Source of truth: RevenueCat webhook (step 5). In step 1 we only seed
-- new Free-tier rows at bootstrap time.
--
-- `tier` = entitled-to (what unlocks); `billing_state` = why they're
-- entitled and what the app should show. Orthogonal columns.
-- See CLAUDE.md "entitlement_snapshots.billing_state enum" section.

CREATE TYPE billing_state AS ENUM (
  'none',              -- Free tier, never purchased
  'active',            -- Paid Premium/Pro, current
  'trial',             -- Intro offer in progress (Premium annual only)
  'grace',             -- Apple billing retry; user retains paid access
  'cancelled_active',  -- User cancelled; access continues until period end
  'expired'            -- Paid access ended; eligible for win-back
);

CREATE TABLE IF NOT EXISTS entitlement_snapshots (
  canonical_user_key   TEXT PRIMARY KEY REFERENCES app_users(canonical_user_key) ON DELETE CASCADE,
  tier                 user_tier NOT NULL DEFAULT 'free',
  is_trial             BOOLEAN   NOT NULL DEFAULT FALSE,
  expires_at           TIMESTAMPTZ,
  billing_state        billing_state NOT NULL DEFAULT 'none',
  raw_webhook_payload  JSONB,           -- populated by step 5 webhook handler; NULL in step 1
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Partial indexes: hot path is Free users (tier='free', billing_state='none').
-- Only index deviations from the hot path for admin dashboards.
CREATE INDEX IF NOT EXISTS idx_entitlement_billing_state_nonnone
  ON entitlement_snapshots(billing_state) WHERE billing_state != 'none';

CREATE INDEX IF NOT EXISTS idx_entitlement_tier_paid
  ON entitlement_snapshots(tier) WHERE tier != 'free';

-- Index by expires_at for step 5's trial-reminder notification dispatcher.
CREATE INDEX IF NOT EXISTS idx_entitlement_expires_at
  ON entitlement_snapshots(expires_at) WHERE expires_at IS NOT NULL;

COMMENT ON TABLE  entitlement_snapshots                     IS 'Plan state per user. RevenueCat is source of truth; webhook populates in step 5.';
COMMENT ON COLUMN entitlement_snapshots.tier                IS 'free | premium | pro — what features unlock.';
COMMENT ON COLUMN entitlement_snapshots.billing_state       IS 'none | active | trial | grace | cancelled_active | expired — why they have what they have.';
COMMENT ON COLUMN entitlement_snapshots.raw_webhook_payload IS 'Last RevenueCat webhook body. NULL in step 1.';
