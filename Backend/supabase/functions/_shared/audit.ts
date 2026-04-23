// Audit-log write helper for /v1/ops/admin/* Edge Functions.
//
// Single call site for all admin mutations. Step 8 ADR 0023 mandates that
// every admin route write an audit row on success — no silent actions.
//
// Posture:
//   - Non-fatal on insert failure. If audit_log is unavailable we do NOT
//     unwind the user-facing mutation. Reason: a user's quota reset that
//     didn't log an audit row is a worse situation if we retry than if we
//     proceed. The logger captures the failure at warn level; a nightly
//     recon job would catch systemic write failures.
//   - Service-role only. The caller supplies a service client. audit_log
//     RLS has no INSERT policy for authenticated.
//   - Actor snapshot: caller passes actor_id + actor_email. We don't
//     re-lookup ops_admins here — admin_auth.verifyAdminAuth already
//     produced that identity at request entry.
//
// Typical flow inside an admin handler:
//
//   const admin = await verifyAdminAuth(req, client);
//   // ... mutate something ...
//   await writeAudit(client, log, {
//     actor_id: admin.authUserId,
//     actor_email: admin.email,
//     action: 'users.reset_quota',
//     target_table: 'usage_counters',
//     target_id: canonicalUserKey,
//     before: { used_count: 5, cap_count: 6 },
//     after:  { used_count: 0, cap_count: 6 },
//     request_id: requestId,
//   });

import type { SupabaseClient } from '@supabase/supabase-js';
import type { Logger } from './logger.ts';

export interface AuditEntry {
  actor_id: string | null;
  actor_email: string | null;
  action: string;
  target_table: string;
  target_id: string;
  before?: unknown;
  after?: unknown;
  request_id?: string;
}

/**
 * Insert a row into audit_log. Failures are logged at warn level and
 * swallowed. Returns the inserted row id on success, or null on failure.
 *
 * Never throws — audit failures must not break the caller's happy path.
 */
export async function writeAudit(
  client: SupabaseClient,
  log: Logger,
  entry: AuditEntry,
): Promise<string | null> {
  try {
    const row = {
      actor_id: entry.actor_id,
      actor_email: entry.actor_email,
      action: entry.action,
      target_table: entry.target_table,
      target_id: entry.target_id,
      before_json: entry.before ?? null,
      after_json: entry.after ?? null,
      request_id: entry.request_id ?? null,
    };

    const { data, error } = await client
      .from('audit_log')
      .insert(row)
      .select('id')
      .single<{ id: string }>();

    if (error) {
      log.warn('audit_log_insert_failed', {
        action: entry.action,
        target_table: entry.target_table,
        target_id: entry.target_id,
        err: error.message,
      });
      return null;
    }
    return data?.id ?? null;
  } catch (err) {
    // Defensive: network blip, typed client wrapper throws, etc.
    log.warn('audit_log_insert_threw', {
      action: entry.action,
      err: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

/**
 * Write audit + surface the inserted id on caller's result object.
 * Convenience wrapper when the caller wants the row id in their response
 * body (e.g., to return an "undo" token — though v1 doesn't implement
 * undo). Never throws; returns null on failure.
 */
export async function writeAuditAndReturnId(
  client: SupabaseClient,
  log: Logger,
  entry: AuditEntry,
): Promise<string | null> {
  return writeAudit(client, log, entry);
}
