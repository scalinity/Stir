-- Stir operational schema — prompt_versions
-- One row per (feature_key, version). Exactly one row per feature_key
-- should carry is_default = TRUE; that's the row /v1/config/bootstrap returns.
--
-- template_blob holds the prompt text for steps 3+. In step 1 the seed
-- migration inserts empty placeholder rows (version = '0.0.0'); the slot
-- exists so iOS clients see the full prompt_key list on day one.
--
-- prompt_version_override feature flag can route a specific feature_key
-- to a non-default version for canary/rollback work (step 3+).
--
-- Idempotent re-run: the companion seed migration uses ON CONFLICT DO NOTHING.

CREATE TABLE IF NOT EXISTS prompt_versions (
  feature_key     TEXT NOT NULL,
  version         TEXT NOT NULL,                    -- semver string, not a numeric version
  provider_model  TEXT NOT NULL,
  template_blob   TEXT NOT NULL DEFAULT '',
  schema_hash     TEXT NOT NULL DEFAULT '',
  rollout_pct     INTEGER NOT NULL DEFAULT 100 CHECK (rollout_pct BETWEEN 0 AND 100),
  is_default      BOOLEAN NOT NULL DEFAULT FALSE,
  is_enabled      BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (feature_key, version)
);

-- Fast path for config-bootstrap: "give me the default prompt per feature_key".
CREATE INDEX IF NOT EXISTS idx_prompt_versions_feature_default
  ON prompt_versions(feature_key) WHERE is_default = TRUE;

-- Optional uniqueness guard: at most one default per feature_key.
-- Enforced via partial unique index rather than CHECK so new prompts can
-- be staged at is_default=FALSE before the flip.
CREATE UNIQUE INDEX IF NOT EXISTS uq_prompt_versions_one_default_per_feature
  ON prompt_versions(feature_key) WHERE is_default = TRUE;

COMMENT ON TABLE  prompt_versions                IS 'Prompt registry. Default row per feature_key served via /v1/config/bootstrap.';
COMMENT ON COLUMN prompt_versions.version        IS 'Semver string, e.g. "0.0.0" (placeholder) or "1.0.0" (first real prompt).';
COMMENT ON COLUMN prompt_versions.template_blob  IS 'Prompt text. Empty in step 1 seed; populated via migrations in steps 3+.';
COMMENT ON COLUMN prompt_versions.schema_hash    IS 'Hash of expected response JSON schema; used to detect mismatched client/server shapes.';
