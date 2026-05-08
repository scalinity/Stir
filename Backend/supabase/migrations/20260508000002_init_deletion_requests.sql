-- Stir operational schema — deletion_requests
-- SCA-61: in-app CCPA deletion flow.
--
-- Rationale: Privacy Policy §7.7 (2026-04-24) directed users to email-
-- only at privacy@getstir.app because no in-app surface existed. CCPA
-- compliance + SOC2 audit + state AG inquiries all flag email-only as
-- a friction-shaped barrier to the §7.2 right-to-delete. This migration
-- adds the durable queue that backs the in-app submission flow.
--
-- Table shape:
--   * Status ENUM: pending → approved → processing → (completed | failed)
--   * canonical_user_key_hash (irreversible) — admins resolve by hash
--   * external_refs_json — structured record of subsystem cleanup state
--     (PostHog identify-merge, Sentry user-erase, RC alias-cleanup,
--     CloudKit zone-delete trigger). Caller pgmq-dispatch fulfillment
--     job populates per-step status; partial failures preserve completed
--     subsystems so a retry continues from the failure point.
--   * Idempotent on (canonical_user_key) when state ∈ {pending, approved,
--     processing} — a duplicate submit returns the existing row id.
--
-- Compliance: 30-day fulfillment SLA per Privacy Policy §7.2. The fulfillment
-- job is scheduled with priority; manual ops triage fires when status =
-- 'failed'.

CREATE TYPE deletion_request_state AS ENUM (
  'pending',
  'approved',
  'processing',
  'completed',
  'failed'
);

CREATE TABLE IF NOT EXISTS deletion_requests (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  canonical_user_key       TEXT NOT NULL REFERENCES app_users(canonical_user_key) ON DELETE CASCADE,
  canonical_user_key_hash  TEXT NOT NULL,
  state                    deletion_request_state NOT NULL DEFAULT 'pending',
  requested_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  approved_at              TIMESTAMPTZ,
  approved_by_admin_id     UUID,  -- references ops_admins, soft (admin row may be banned later)
  started_at               TIMESTAMPTZ,
  completed_at             TIMESTAMPTZ,
  failure_reason           TEXT,
  external_refs_json       JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Idempotency: at most one in-flight (non-terminal) deletion request per user.
-- A second POST /v1/users/delete-request returns the existing row.
CREATE UNIQUE INDEX IF NOT EXISTS uq_deletion_requests_in_flight
  ON deletion_requests(canonical_user_key)
  WHERE state IN ('pending', 'approved', 'processing');

-- Hot path for ops admin "list pending requests" page.
CREATE INDEX IF NOT EXISTS idx_deletion_requests_state_requested
  ON deletion_requests(state, requested_at DESC)
  WHERE state IN ('pending', 'approved', 'processing');

-- Hash lookup for cross-system reconciliation queries.
CREATE INDEX IF NOT EXISTS idx_deletion_requests_hash
  ON deletion_requests(canonical_user_key_hash);

ALTER TABLE deletion_requests ENABLE ROW LEVEL SECURITY;
-- Service-role only. iOS reads its own pending state through the
-- /v1/users/delete-request POST (the endpoint returns the existing row
-- on a duplicate submit, satisfying "do I have a pending request?"
-- without a separate GET). Admin reads via /v1/ops/admin RPC.

COMMENT ON TABLE  deletion_requests                    IS 'CCPA / privacy-rights deletion queue. SCA-61. iOS submits via POST /v1/users/delete-request; ops admin approves; pgmq-dispatch fulfills.';
COMMENT ON COLUMN deletion_requests.state              IS 'pending → approved → processing → (completed | failed). Terminal states retain rows for audit.';
COMMENT ON COLUMN deletion_requests.canonical_user_key_hash IS 'SHA-256 of canonical_user_key (per ADR 0027). Survives the FK cascade so completed deletions still have an audit anchor.';
COMMENT ON COLUMN deletion_requests.external_refs_json IS 'Per-subsystem fulfillment status. Shape: {posthog: {merged_at, distinct_id_hash}, sentry: {erased_at, user_id_hash}, revenuecat: {cleared_at, app_user_id_hash}, cloudkit: {triggered_at}}. Partial state preserved across retries.';
COMMENT ON COLUMN deletion_requests.failure_reason     IS 'Set when state=failed; truncated to 1024 chars in fulfillment worker.';
