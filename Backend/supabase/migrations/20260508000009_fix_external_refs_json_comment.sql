-- SCA-233 — fix stale external_refs_json COMMENT on deletion_requests.
--
-- The init migration (20260508000002) declared this comment using
-- field names that don't match what the worker emits:
--
--   declared: {posthog: {merged_at, distinct_id_hash},
--              sentry: {erased_at, user_id_hash},
--              revenuecat: {cleared_at, app_user_id_hash},
--              cloudkit: {triggered_at}}
--
--   actual:   {posthog:    {completed_at, distinct_id_hash},
--              sentry:     {completed_at, user_id_hash} OR
--                          {requires_manual_action, error, triggered_at},
--              revenuecat: {completed_at, app_user_id_hash} OR
--                          {requires_manual_action, error, triggered_at},
--              cloudkit:   {requires_client_action, triggered_at},
--              alerts:     {approved_stale|failed_stale: {dispatched_at, sentry_request_id}}
--                          (added by 20260508000006's stale-row alerter),
--              postgres:   {completed_at, canonical_user_key_hash}
--                          (set on the success path before the cascade
--                           wipes deletion_requests; visible in the
--                           audit_log after_json snapshot)}
--
-- Anyone reading the schema would build broken JSON-path queries
-- using the stale field names. Forward migration per the immutable-
-- migration policy — never edit the original.

COMMENT ON COLUMN deletion_requests.external_refs_json IS
  'Per-subsystem fulfillment status. Shape (SCA-88 + SCA-227 + SCA-222 + SCA-225 follow-ups; superseded the original 20260508000002 COMMENT): {posthog: {completed_at, distinct_id_hash}, sentry: {completed_at, user_id_hash} | {requires_manual_action, error, triggered_at}, revenuecat: {completed_at, app_user_id_hash} | {requires_manual_action, error, triggered_at}, cloudkit: {requires_client_action, triggered_at}, alerts: {approved_stale|failed_stale: {dispatched_at, sentry_request_id}}, postgres: {completed_at, canonical_user_key_hash}}. Partial state preserved across retries; resume short-circuits on completed_at, requires_manual_action (sentry/RC), and requires_client_action (cloudkit).';
