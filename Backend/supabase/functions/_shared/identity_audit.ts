// SCA-406 — typed wrappers around `writeAudit` for identity-related
// events. Pre-fix push-register/index.ts inlined two 8-line writeAudit
// blocks (`auth_user_stale`, `apns_environment_flipped`) with the same
// SCA-392 plumbing (actor_id: null, hashed key in after_json). Each
// wrapper centralizes that plumbing so the handler reads as a one-line
// call + the rationale lives next to the helper.
//
// Both functions inherit `writeAudit`'s non-fatal posture — they never
// throw, and silently log on insert failure.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from './logger.ts';
import type { VerifiedSessionClaims } from './auth.ts';
import { hashCanonicalKey } from './hashing.ts';
import { writeAudit } from './audit.ts';

/**
 * SCA-381 / SCA-392 — record an `auth_user_stale` audit row when JWT
 * verification passes but the claim's canonical_user_key no longer
 * resolves to an `app_users` row.
 *
 * Causes:
 *   (a) Row hard-deleted (shouldn't happen; status='banned' is the
 *       soft-delete path).
 *   (b) Identity-merge in flight where the alias-forward landed but
 *       the JWT was minted seconds before.
 *   (c) Test fixture cleanup raced with a real session.
 *
 * SREs grep `action='auth_user_stale'` to scope (a) vs (b)/(c) noise.
 *
 * SCA-392: `audit_log.actor_id` is `UUID REFERENCES auth.users(id)`;
 * canonical_user_key shapes (`ck:<recordName>` / `install:<uuid>`)
 * are not UUIDs. Pass `null` for actor_id; the hashed key lands in
 * `after_json.canonical_user_key_hash` (matches _shared/hashing.ts
 * log-invariant). Caller's endpoint name is captured for grep
 * scoping.
 */
export async function auditUserStale(
  client: SupabaseClient,
  log: Logger,
  claims: VerifiedSessionClaims,
  endpoint: string,
  requestId: string,
): Promise<void> {
  await writeAudit(client, log, {
    actor_id: null,
    actor_email: null,
    action: 'auth_user_stale',
    target_table: 'app_users',
    target_id: claims.canonical_user_key,
    after: {
      endpoint,
      reason: 'user_stale',
      canonical_user_key_hash: await hashCanonicalKey(claims.canonical_user_key),
    },
    request_id: requestId,
  });
}

/**
 * SCA-381 / SCA-392 — record an `apns_environment_flipped` audit row
 * when the same install registers under a different `apns_environment`.
 * Legitimate path: TestFlight → App Store graduation. A sustained
 * rate of unintended flips signals a misconfigured Debug→Release
 * build path on prod devices.
 *
 * Caller MUST gate on `priorEnvironment !== null && priorEnvironment
 * !== newEnvironment` (SCA-399 first-touch carve-out — see
 * push-register/index.ts).
 */
export async function auditApnsEnvironmentFlip(
  client: SupabaseClient,
  log: Logger,
  claims: VerifiedSessionClaims,
  installationId: string,
  priorEnvironment: string,
  newEnvironment: string,
  requestId: string,
): Promise<void> {
  await writeAudit(client, log, {
    actor_id: null,
    actor_email: null,
    action: 'apns_environment_flipped',
    target_table: 'device_installations',
    target_id: installationId,
    before: { apns_environment: priorEnvironment },
    after: {
      apns_environment: newEnvironment,
      canonical_user_key_hash: await hashCanonicalKey(claims.canonical_user_key),
    },
    request_id: requestId,
  });
}
