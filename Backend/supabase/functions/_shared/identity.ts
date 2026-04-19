// Canonical identity resolution + alias-forward transaction.
//
// See plan file §"Alias-forward (identity.ts) — one transaction" for the
// full per-table merge spec. Everything here runs inside a single Postgres
// transaction; failure retries once, then surfaces as VAL-01.

import type { SupabaseClient } from '@supabase/supabase-js';
import type { SessionBootstrapRequest } from './validation.ts';

export type UserSource = 'install' | 'cloudkit';

export interface CanonicalKeyResolution {
  canonical_user_key: string;
  source_type: UserSource;
  /** Install key used for this request (always present). */
  install_canonical_key: string;
  /** CK key when user has CloudKit; undefined for install-only. */
  ck_canonical_key?: string;
}

/** Decide the canonical_user_key we should resolve against `app_users`. */
export function resolveCanonicalKey(body: SessionBootstrapRequest): CanonicalKeyResolution {
  const install_canonical_key = `install:${body.installation_id}`;
  if (body.cloudkit_user_record_name) {
    const ck_canonical_key = `ck:${body.cloudkit_user_record_name}`;
    return {
      canonical_user_key: ck_canonical_key,
      source_type: 'cloudkit',
      install_canonical_key,
      ck_canonical_key,
    };
  }
  return {
    canonical_user_key: install_canonical_key,
    source_type: 'install',
    install_canonical_key,
  };
}

// ---------------------------------------------------------------------------
// app_users row shape (as fetched from the DB)
// ---------------------------------------------------------------------------

export interface AppUserRow {
  canonical_user_key: string;
  current_install_id: string | null;
  revenuecat_app_user_id: string | null;
  source_type: UserSource;
  status: 'active' | 'merged' | 'banned';
  merged_into: string | null;
  created_at: string;
  last_seen_at: string;
}

/** Fetch a single app_users row or null if missing. */
export async function readAppUser(
  client: SupabaseClient,
  canonicalKey: string,
): Promise<AppUserRow | null> {
  const { data, error } = await client
    .from('app_users')
    .select('*')
    .eq('canonical_user_key', canonicalKey)
    .maybeSingle<AppUserRow>();
  if (error) throw error;
  return data;
}

// ---------------------------------------------------------------------------
// followMergedInto — chase merge chain to the terminal winning row
// ---------------------------------------------------------------------------

/**
 * Resolve to the terminal (non-merged) row. Allows exactly ONE hop —
 * a longer chain is a bug (merge targets should themselves be active).
 * Throws if a second hop is needed; caller logs to Sentry.
 */
export async function followMergedInto(
  client: SupabaseClient,
  start: AppUserRow,
): Promise<AppUserRow> {
  if (start.merged_into == null) return start;
  const next = await readAppUser(client, start.merged_into);
  if (next == null) {
    throw new Error(`followMergedInto: target ${start.merged_into} missing`);
  }
  if (next.merged_into != null) {
    throw new Error(
      `followMergedInto: nested merge (chain ${start.canonical_user_key} → ${next.canonical_user_key} → ${next.merged_into})`,
    );
  }
  return next;
}

// ---------------------------------------------------------------------------
// aliasForward — install → ck merge. See plan for per-table rules.
// ---------------------------------------------------------------------------

export interface AliasForwardResult {
  alias_performed: boolean;
  usage_rows_merged: number;
  /** ck already had an entitlement row; install's was discarded. */
  entitlement_row_discarded: boolean;
  /**
   * ck had no entitlement row; install's row was renamed to ck. Added in
   * migration 20260419000004 to preserve entitlements purchased under an
   * install-scoped identity when the user later gains iCloud.
   */
  entitlement_row_promoted?: boolean;
  ai_log_rows_rewritten: number;
  device_rows_rewritten: number;
}

/**
 * Alias-forward merge executed during /v1/session/bootstrap when a new `ck:`
 * row is about to win over an existing `install:` row owned by the same
 * installation. Runs inside the caller's transaction.
 *
 * Per-table rules (plan §"Alias-forward"):
 *  - usage_counters: sum used_count per (period_start, feature_key) onto ck.
 *    No cap clamping — summed counts exceeding cap still lock the user out.
 *  - entitlement_snapshots: keep ck row; delete install row.
 *  - ai_request_log: UPDATE canonical_user_key install→ck.
 *  - device_installations: UPDATE canonical_user_key install→ck.
 *  - app_users (install): SET merged_into = ck, status = 'merged'.
 *  - app_users (ck): update last_seen_at.
 *
 * This implementation uses a Postgres function created below via raw SQL
 * (invoked through rpc) to get atomicity. Running individual supabase-js
 * calls in sequence does NOT give us a transaction.
 */
export async function aliasForward(
  client: SupabaseClient,
  installKey: string,
  ckKey: string,
): Promise<AliasForwardResult> {
  const { data, error } = await client.rpc('stir_alias_forward', {
    p_install_key: installKey,
    p_ck_key: ckKey,
  });
  if (error) throw error;
  return data as AliasForwardResult;
}
