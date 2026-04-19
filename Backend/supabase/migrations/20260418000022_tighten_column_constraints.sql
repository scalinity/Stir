-- Stir operational schema — tighten column types + length bounds.
--
-- Three independent defense-in-depth tightenings bundled into one migration
-- since they touch adjacent concerns and each is a small atomic change:
--
--   1. canonical_user_key length CHECK — prevents a misbehaving client or a
--      future code-path bug from storing a runaway-long key. Max derivation:
--      `ck:` (3 chars) + 256-char cloudkit_user_record_name ceiling = 259;
--      round to 300 for safety margin. The Zod regex already enforces 33-
--      char CK names, so real rows are 36 chars — 300 is only a DB-level
--      sanity check.
--
--   2. device_installations.installation_id + app_users.current_install_id
--      TEXT → UUID. iOS always sends UUID-shaped values (Zod-validated),
--      and every existing row in prod was inserted via that path, so the
--      ALTER ... USING cast is safe. Benefits: implicit format validation
--      at the DB layer, 8-byte-per-row saving, uuid_ops index class.
--
--   3. entitlement_snapshots.raw_webhook_payload size CHECK — step 5's
--      RevenueCat webhook will stuff full event bodies here. Cap at 64 KiB
--      to prevent a malformed/malicious payload from bloating the row.
--      64 KiB is ~20x the typical RevenueCat event size.
--
-- All three ALTERs are safe to run against existing data. Each ADD CONSTRAINT
-- validates the full table at apply time; at current row counts (low-
-- thousands at most) this is instant.

-- ---------------------------------------------------------------------------
-- 1. canonical_user_key length CHECK
-- ---------------------------------------------------------------------------
-- Apply to every table that stores the key. Length floor = 4 for the
-- minimum viable key ("ck:_" or "install:" + 4 chars).

ALTER TABLE app_users
  ADD CONSTRAINT app_users_canonical_user_key_len_chk
  CHECK (length(canonical_user_key) BETWEEN 4 AND 300);

ALTER TABLE device_installations
  ADD CONSTRAINT device_installations_canonical_user_key_len_chk
  CHECK (length(canonical_user_key) BETWEEN 4 AND 300);

ALTER TABLE entitlement_snapshots
  ADD CONSTRAINT entitlement_snapshots_canonical_user_key_len_chk
  CHECK (length(canonical_user_key) BETWEEN 4 AND 300);

ALTER TABLE usage_counters
  ADD CONSTRAINT usage_counters_canonical_user_key_len_chk
  CHECK (length(canonical_user_key) BETWEEN 4 AND 300);

ALTER TABLE ai_request_log
  ADD CONSTRAINT ai_request_log_canonical_user_key_len_chk
  CHECK (length(canonical_user_key) BETWEEN 4 AND 300);

-- ---------------------------------------------------------------------------
-- 2. installation_id TEXT → UUID
-- ---------------------------------------------------------------------------
-- device_installations.installation_id is the PK — ALTER rebuilds the
-- underlying index. At current scale (hundreds of rows) this is
-- sub-millisecond. The USING cast fails loudly if any existing value is
-- non-UUID; Zod validation on `/v1/session/bootstrap` means this won't
-- happen in practice.

ALTER TABLE device_installations
  ALTER COLUMN installation_id TYPE UUID USING installation_id::UUID;

ALTER TABLE app_users
  ALTER COLUMN current_install_id TYPE UUID USING current_install_id::UUID;

-- ---------------------------------------------------------------------------
-- 3. entitlement_snapshots.raw_webhook_payload size ceiling
-- ---------------------------------------------------------------------------
-- pg_column_size() returns the TOAST-compressed size in bytes, which is
-- what matters for row storage cost. 64 KiB ceiling is far above any
-- plausible RevenueCat event size and well below the BYTEA/JSONB 1 GB
-- maximum, so normal webhook payloads pass trivially.

ALTER TABLE entitlement_snapshots
  ADD CONSTRAINT entitlement_snapshots_raw_webhook_payload_size_chk
  CHECK (raw_webhook_payload IS NULL OR pg_column_size(raw_webhook_payload) < 65536);

-- ---------------------------------------------------------------------------
-- Comments refresh
-- ---------------------------------------------------------------------------

COMMENT ON COLUMN device_installations.installation_id IS
  'UUID generated once per install, persisted in iOS keychain. UUID type since migration 22.';
COMMENT ON COLUMN app_users.current_install_id IS
  'Most recently seen installation_id. May lag if user switched devices. UUID type since migration 22.';
COMMENT ON COLUMN entitlement_snapshots.raw_webhook_payload IS
  'Last RevenueCat webhook body. NULL in step 1. Size-capped at 64 KiB via CHECK (migration 22).';
