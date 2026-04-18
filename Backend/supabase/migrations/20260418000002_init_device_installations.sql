-- Stir operational schema — device_installations
-- One row per iOS install. `installation_id` is a keychain-backed UUID
-- the iOS client sends on every `/v1/session/bootstrap` call.
--
-- A single canonical_user_key may own many installation rows (multi-device
-- CloudKit users). An install row's canonical_user_key is rewritten during
-- alias-forward (install → ck) so the install_id identity survives.

CREATE TABLE IF NOT EXISTS device_installations (
  installation_id        TEXT PRIMARY KEY,
  canonical_user_key     TEXT NOT NULL REFERENCES app_users(canonical_user_key) ON DELETE CASCADE,
  build                  TEXT NOT NULL,
  os_version             TEXT NOT NULL,
  push_token             TEXT,
  notifications_enabled  BOOLEAN NOT NULL DEFAULT FALSE,
  last_seen_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_device_installations_user
  ON device_installations(canonical_user_key);

COMMENT ON TABLE  device_installations                       IS 'Install tracking; push_token populated by step 8 push-register handler.';
COMMENT ON COLUMN device_installations.installation_id       IS 'UUID generated once per install, persisted in iOS keychain.';
COMMENT ON COLUMN device_installations.push_token            IS 'APNs device token. NULL until user grants notification permission.';
COMMENT ON COLUMN device_installations.notifications_enabled IS 'Whether user has opted into push. Defaults FALSE — iOS prompts then flips.';
