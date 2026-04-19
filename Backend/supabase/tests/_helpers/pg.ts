// Supabase clients for tests.
//
// Thin wrappers over the production factories in functions/_shared/db.ts so
// tests exercise the exact client shape production handlers use (including
// the `x-stir-client` header that surfaces in Supabase log dashboards).
// Previously this file maintained parallel factories; the duplication
// invited drift (e.g. one added the `x-stir-client` tag, the other didn't).
//
// serviceClient: bypasses RLS — used ONLY to seed rows in tests that assert
// RLS behavior. Never mirror this pattern in production handler code.
//
// userClient: authenticated-role PostgREST client, passes the session JWT
// as Bearer. This is the client shape iOS would use to read usage_counters
// directly. RLS isolation tests run everything through this path.

// Side-effect import: overrides shell env with local .env values.
import './env.ts';

import type { SupabaseClient } from '@supabase/supabase-js';
import {
  createServiceClient,
  createUserClient,
} from '../../functions/_shared/db.ts';

export function serviceClient(): SupabaseClient {
  return createServiceClient();
}

export function userClient(jwt: string): SupabaseClient {
  return createUserClient(jwt);
}

/**
 * Clear the shared rate_limit_buckets table. Tests run against a local
 * Supabase where Kong overwrites x-forwarded-for with the Docker gateway
 * IP — every test bucket lands in the same row and trips the new
 * ip:bootstrap_hourly / ip:pantry_parse_daily / ip:dinner_solve_daily
 * policies within a single test-run window. Calling this at the top of
 * each test file (once) keeps tests independent without weakening the
 * production rate-limit defense.
 */
export async function clearRateLimitBuckets(): Promise<void> {
  const client = serviceClient();
  // Delete-by-condition rather than TRUNCATE so we don't need the
  // postgres role. Any row matches scope_key IS NOT NULL.
  const { error } = await client
    .from('rate_limit_buckets')
    .delete()
    .not('scope_key', 'is', null);
  if (error) throw error;
}
