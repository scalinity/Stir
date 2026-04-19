-- Stir operational schema — scope ai_response_cache per-user (SA2-01)
--
-- Before this migration, ai_response_cache used request_id alone as the
-- primary key. Idempotency keys are client-generated UUIDs, so under
-- normal use collision is astronomically unlikely — but if a request_id
-- ever leaks (Sentry breadcrumb, observability dashboard, misbehaving
-- SDK log), a different user could submit any body with that ID and
-- receive the original user's cached response verbatim. The response
-- body echoes recipe context + model reasoning, so this is a
-- cross-user content-leak vector.
--
-- Fix: scope the cache PK to (canonical_user_key, request_id). The
-- same request_id can now exist for multiple users (no collision risk)
-- and a cache hit requires both the JWT-authenticated user AND the
-- request_id to match. An attacker who only knows the victim's
-- request_id still sees a cache miss under their own JWT.
--
-- Migration strategy: existing rows are sub-TTL (10 min) and the cache
-- is operational, not user-facing. Safe to drop all rows during the
-- PK rebuild — worst case is an Edge Function re-hitting Gemini for
-- an in-flight idempotent retry, which still converges on the same
-- wire response.

BEGIN;

-- Drop all rows first; rebuilding the PK with existing rows would
-- require back-filling canonical_user_key from ai_request_log, and
-- that's more fragile than simply clearing the 10-minute cache.
DELETE FROM ai_response_cache;

ALTER TABLE ai_response_cache
  ADD COLUMN canonical_user_key TEXT NOT NULL;

ALTER TABLE ai_response_cache
  DROP CONSTRAINT ai_response_cache_pkey;

ALTER TABLE ai_response_cache
  ADD CONSTRAINT ai_response_cache_pkey
    PRIMARY KEY (canonical_user_key, request_id);

COMMENT ON COLUMN ai_response_cache.canonical_user_key IS
  'Owner of the cached response. Scopes idempotency per-user so a leaked request_id cannot be replayed by a different user.';

COMMIT;
