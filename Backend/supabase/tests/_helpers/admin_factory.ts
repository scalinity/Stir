// Admin-auth test factories. Step 8.
//
// Seeds an auth.users row + ops_admins link + mints a Supabase-Auth-shaped
// JWT signed with the same HS256 `STIR_JWT_SECRET` used for iOS session
// JWTs. PostgREST accepts it natively (the project's jwt_secret matches),
// auth.uid() resolves to the auth.users row, is_admin() returns true.
//
// Two JWT shapes coexist in this codebase:
//   iOS session JWT  — iss='stir-backend', sub=canonical_user_key (string),
//                      minted by _shared/auth.ts::issueSessionJWT.
//   Admin auth JWT   — iss='<local Auth issuer>', sub=auth.users.id (UUID),
//                      minted by this helper (matches Supabase Auth shape).
// ADR 0020 covers the separation guarantees.

import './env.ts';
import * as jose from 'jose';
import { serviceClient } from './pg.ts';

const JWT_SECRET = Deno.env.get('STIR_JWT_SECRET') ?? Deno.env.get('SUPABASE_JWT_SECRET');
if (!JWT_SECRET) {
  throw new Error(
    'admin_factory: STIR_JWT_SECRET (or SUPABASE_JWT_SECRET fallback) missing from env. ' +
      'Run supabase start and ensure Backend/supabase/.env carries the local jwt_secret.',
  );
}
const SECRET_BYTES = new TextEncoder().encode(JWT_SECRET);

// Local Supabase Auth issuer. Matches the `iss` claim Supabase's own gotrue
// stamps into tokens when you sign in via magic link against the local
// stack. Production issuer is https://<project>.supabase.co/auth/v1.
const LOCAL_AUTH_ISSUER = 'http://127.0.0.1:54321/auth/v1';

export interface SeededAdmin {
  authUserId: string;
  email: string;
  jwt: string;
}

/**
 * Mint a JWT with Supabase-Auth-shaped claims. Not a real Supabase Auth
 * session (no corresponding refresh token), just enough to exercise
 * PostgREST + is_admin() + admin-only RPC paths in tests.
 */
export async function mintAdminAuthJWT(opts: {
  userId: string;
  email: string;
  ttlSeconds?: number;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const ttl = opts.ttlSeconds ?? 3600;
  return await new jose.SignJWT({
    sub: opts.userId,
    email: opts.email,
    role: 'authenticated',
    aal: 'aal1',
    session_id: crypto.randomUUID(),
    user_metadata: { ops_admin_v1: true },
    app_metadata: { provider: 'email', providers: ['email'] },
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer(LOCAL_AUTH_ISSUER)
    .setAudience('authenticated')
    .setSubject(opts.userId)
    .setIssuedAt(now)
    .setExpirationTime(now + ttl)
    .sign(SECRET_BYTES);
}

/**
 * Create an auth user + ops_admins row + mint a matching JWT.
 *
 * Every call produces a fresh email + UUID so tests never collide.
 * `supabase db reset` between CI runs handles aggregate cleanup.
 */
export async function seedAdmin(opts: { email?: string; notes?: string } = {}): Promise<SeededAdmin> {
  const client = serviceClient();
  const email = opts.email ?? `admin-${crypto.randomUUID().slice(0, 8)}@test.stir.app`;

  // Create the auth user via the Supabase admin API. The service-role client
  // is authenticated as admin, so this works in local dev and mirrors the
  // real magic-link flow's row-creation path.
  // deno-lint-ignore no-explicit-any
  const admin = (client.auth as any).admin;
  const createRes = await admin.createUser({
    email,
    email_confirm: true,
    user_metadata: { ops_admin_v1: true },
  });
  if (createRes.error || !createRes.data?.user) {
    throw new Error(
      `seedAdmin: auth.admin.createUser failed: ${createRes.error?.message ?? 'no user returned'}`,
    );
  }
  const authUserId: string = createRes.data.user.id;

  const { error: adminErr } = await client.from('ops_admins').insert({
    auth_user_id: authUserId,
    email,
    notes: opts.notes ?? 'test seed',
  });
  if (adminErr) {
    throw new Error(`seedAdmin: ops_admins insert failed: ${adminErr.message}`);
  }

  const jwt = await mintAdminAuthJWT({ userId: authUserId, email });
  return { authUserId, email, jwt };
}

/**
 * Create an auth user WITHOUT ops_admins row. Mint JWT. Useful for negative
 * tests: "authenticated but not admin → is_admin() === false".
 */
export async function seedAuthOnlyUser(
  opts: { email?: string } = {},
): Promise<SeededAdmin> {
  const client = serviceClient();
  const email = opts.email ?? `notadmin-${crypto.randomUUID().slice(0, 8)}@test.stir.app`;
  // deno-lint-ignore no-explicit-any
  const admin = (client.auth as any).admin;
  const createRes = await admin.createUser({
    email,
    email_confirm: true,
  });
  if (createRes.error || !createRes.data?.user) {
    throw new Error(
      `seedAuthOnlyUser: auth.admin.createUser failed: ${createRes.error?.message ?? 'no user returned'}`,
    );
  }
  const authUserId: string = createRes.data.user.id;
  const jwt = await mintAdminAuthJWT({ userId: authUserId, email });
  return { authUserId, email, jwt };
}
