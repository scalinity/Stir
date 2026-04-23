// Step 8 — ops_admins table + is_admin() function.
//
// Verifies:
//   - is_admin() returns true for a JWT whose sub matches an ops_admins row
//   - is_admin() returns false for an authenticated-but-not-admin JWT
//   - is_admin() returns false for an iOS session JWT (auth.uid() is null
//     because canonical_user_key doesn't resolve to an auth.users row)
//   - RLS: admin can SELECT own ops_admins row
//   - RLS: authenticated-not-admin sees empty result set (no 403, per
//     CLAUDE.md §Integration test DB strategy)
//
// Local-only. Requires `supabase start` + functions-serve + GEMINI-free
// (this suite never hits Gemini).

import { assertEquals } from '@std/assert';
import { quickBootstrap } from './_helpers/factory.ts';
import { seedAdmin, seedAuthOnlyUser } from './_helpers/admin_factory.ts';
import { clearRateLimitBuckets, serviceClient, userClient } from './_helpers/pg.ts';

await clearRateLimitBuckets();

Deno.test('is_admin(): true for seeded admin JWT', async () => {
  const admin = await seedAdmin();
  const client = userClient(admin.jwt);

  const { data, error } = await client.rpc('is_admin');
  assertEquals(error, null);
  assertEquals(data, true);
});

Deno.test('is_admin(): false for authenticated-but-not-admin JWT', async () => {
  const user = await seedAuthOnlyUser();
  const client = userClient(user.jwt);

  const { data, error } = await client.rpc('is_admin');
  assertEquals(error, null);
  assertEquals(data, false);
});

Deno.test('is_admin(): false for iOS session JWT (canonical_user_key-scoped, no auth.users sub)', async () => {
  const session = await quickBootstrap();
  const client = userClient(session.session_jwt);

  const { data, error } = await client.rpc('is_admin');
  assertEquals(error, null);
  // iOS JWT sub is a canonical_user_key string, not a UUID → auth.uid()
  // returns null or fails to resolve, so is_admin() returns false.
  assertEquals(data, false);
});

Deno.test('RLS: admin can SELECT own ops_admins row', async () => {
  const admin = await seedAdmin();
  const client = userClient(admin.jwt);

  const { data, error } = await client
    .from('ops_admins')
    .select('auth_user_id, email')
    .eq('auth_user_id', admin.authUserId)
    .single();

  assertEquals(error, null);
  assertEquals(data?.auth_user_id, admin.authUserId);
  assertEquals(data?.email, admin.email);
});

Deno.test('RLS: admin cannot SELECT another admin row', async () => {
  const [adminA, adminB] = await Promise.all([seedAdmin(), seedAdmin()]);
  const clientA = userClient(adminA.jwt);

  // Filter for B's row via A's JWT → empty result (not 403).
  const { data, error } = await clientA
    .from('ops_admins')
    .select('*')
    .eq('auth_user_id', adminB.authUserId);

  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('RLS: authenticated-not-admin sees empty ops_admins', async () => {
  const user = await seedAuthOnlyUser();
  const client = userClient(user.jwt);

  const { data, error } = await client.from('ops_admins').select('*');
  assertEquals(error, null);
  assertEquals((data ?? []).length, 0);
});

Deno.test('RLS: service role sees all ops_admins rows', async () => {
  const [a, b] = await Promise.all([seedAdmin(), seedAdmin()]);
  const client = serviceClient();

  const { data, error } = await client
    .from('ops_admins')
    .select('auth_user_id')
    .in('auth_user_id', [a.authUserId, b.authUserId]);

  assertEquals(error, null);
  assertEquals((data ?? []).length, 2);
});
