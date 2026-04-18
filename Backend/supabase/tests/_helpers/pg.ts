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
