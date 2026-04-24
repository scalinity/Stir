// Supabase client for the ops console.
//
// Uses the ANON key (public) + magic-link auth. ADR 0023: the admin JWT
// this flow mints is separate from iOS session JWTs; backend
// _shared/admin_auth.ts triple-gates the distinction on every call.

import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string;
const SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY as string;

if (!SUPABASE_URL) throw new Error('VITE_SUPABASE_URL missing — set in .env.local');
if (!SUPABASE_ANON_KEY) throw new Error('VITE_SUPABASE_ANON_KEY missing — set in .env.local');

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});

export const OPS_ADMIN_URL = `${SUPABASE_URL}/functions/v1/ops-admin`;
