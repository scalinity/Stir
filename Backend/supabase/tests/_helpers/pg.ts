// Supabase clients for tests.
//
// serviceClient: bypasses RLS — used ONLY to seed rows in tests that assert
// RLS behavior. Never mirror this pattern in production handler code.
//
// userClient: authenticated-role PostgREST client, passes the session JWT
// as Bearer. This is the client shape iOS would use to read usage_counters
// directly. RLS isolation tests run everything through this path.

// Side-effect import: overrides shell env with local .env values.
import './env.ts';

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? 'http://127.0.0.1:54321';

export function serviceClient(): SupabaseClient {
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!serviceKey) {
    throw new Error('SUPABASE_SERVICE_ROLE_KEY missing from test environment.');
  }
  return createClient(SUPABASE_URL, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function userClient(jwt: string): SupabaseClient {
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  if (!anonKey) {
    throw new Error('SUPABASE_ANON_KEY missing from test environment.');
  }
  return createClient(SUPABASE_URL, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
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
