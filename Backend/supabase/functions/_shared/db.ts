// Supabase client factories.
//
// In production handlers we ONLY use the service-role client. It bypasses
// RLS and does its own `WHERE canonical_user_key = $jwt_key` filtering
// against JWT claims we verified ourselves. RLS is defense-in-depth for
// direct PostgREST clients (iOS may later read usage_counters directly
// with its session JWT — the RLS policies are what protect that path).
//
// The user-scoped client factory is exported for the RLS isolation test
// only. Never call it from a handler.

import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL');
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

if (!SUPABASE_URL) throw new Error('SUPABASE_URL missing from environment');
if (!SUPABASE_SERVICE_ROLE_KEY) throw new Error('SUPABASE_SERVICE_ROLE_KEY missing from environment');

/**
 * Build a service-role Supabase client. Bypasses RLS. Intended exclusively
 * for Edge Function handler code paths that handle auth themselves.
 */
export function createServiceClient(): SupabaseClient {
  return createClient(SUPABASE_URL!, SUPABASE_SERVICE_ROLE_KEY!, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { 'x-stir-client': 'service-role' } },
  });
}

/**
 * Build a user-scoped Supabase client carrying a session JWT.
 * Tests-only: exercises RLS exactly as iOS would via PostgREST.
 */
export function createUserClient(jwt: string): SupabaseClient {
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  if (!anonKey) throw new Error('SUPABASE_ANON_KEY missing from environment');
  return createClient(SUPABASE_URL!, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      headers: {
        Authorization: `Bearer ${jwt}`,
        'x-stir-client': 'user-scoped-test-only',
      },
    },
  });
}
