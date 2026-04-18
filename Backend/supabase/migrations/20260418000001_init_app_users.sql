-- Stir operational schema — app_users
-- Canonical identity table. Primary key is `canonical_user_key` which is the
-- Stir-wide identity string: `ck:<CloudKit userRecordName>` when CloudKit is
-- available, else `install:<keychain installation UUID>`.
--
-- Aliasing semantics (enforced by handler, not DB):
--   install row → gains merged_into = ck:<record>, status = 'merged'
--   data moves to the ck row in one transaction at bootstrap time
--   merged rows are retained for audit and NEVER hard-deleted
--
-- See plan §"Alias-forward" and CLAUDE.md Identity section.

CREATE TYPE app_user_status AS ENUM ('active', 'merged', 'banned');
CREATE TYPE user_tier       AS ENUM ('free', 'premium', 'pro');
CREATE TYPE user_source     AS ENUM ('install', 'cloudkit');

CREATE TABLE IF NOT EXISTS app_users (
  canonical_user_key      TEXT PRIMARY KEY,
  current_install_id      TEXT,
  revenuecat_app_user_id  TEXT,
  source_type             user_source NOT NULL,
  status                  app_user_status NOT NULL DEFAULT 'active',
  merged_into             TEXT REFERENCES app_users(canonical_user_key) ON DELETE RESTRICT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Partial index: 99%+ of rows sit at 'active'. Only index the hot path
-- for admin queries ("show banned/merged users").
CREATE INDEX IF NOT EXISTS idx_app_users_status_nonactive
  ON app_users(status) WHERE status != 'active';

-- Partial index for chasing merge chains. One-hop only is enforced by
-- application code; this index supports the fast-path lookup.
CREATE INDEX IF NOT EXISTS idx_app_users_merged_into
  ON app_users(merged_into) WHERE merged_into IS NOT NULL;

COMMENT ON TABLE  app_users                         IS 'Stir canonical identity; one row per canonical_user_key. See CLAUDE.md Identity section.';
COMMENT ON COLUMN app_users.canonical_user_key      IS 'PK. Shape: `ck:<record>` or `install:<uuid>`. Opaque to DB.';
COMMENT ON COLUMN app_users.current_install_id      IS 'Most recently seen installation_id. May lag if user switched devices.';
COMMENT ON COLUMN app_users.revenuecat_app_user_id  IS 'RevenueCat appUserID; equals canonical_user_key after alias forward in step 5.';
COMMENT ON COLUMN app_users.source_type             IS 'Origin at row creation: install (keychain ID first) or cloudkit (CK user first).';
COMMENT ON COLUMN app_users.status                  IS 'Lifecycle: active | merged (terminal) | banned.';
COMMENT ON COLUMN app_users.merged_into             IS 'Alias forward target. NULL for winning rows. One hop max.';
