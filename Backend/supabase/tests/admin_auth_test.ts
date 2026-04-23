// Step 8 — _shared/admin_auth.ts verification.
//
// End-to-end sanity: import the helper directly (no Edge Function layer)
// and exercise every reason branch.

// Must run before any import that reads STIR_JWT_SECRET at module load.
import './_helpers/env.ts';
import { assertEquals, assertRejects } from '@std/assert';
import * as jose from 'jose';
import {
  AdminAuthError,
  verifyAdminAuth,
  adminAuthErrorHttp,
} from '../functions/_shared/admin_auth.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';
import { seedAdmin, seedAuthOnlyUser, mintAdminAuthJWT } from './_helpers/admin_factory.ts';
import { quickBootstrap } from './_helpers/factory.ts';

await clearRateLimitBuckets();

const JWT_SECRET = Deno.env.get('STIR_JWT_SECRET')!;
const SECRET = new TextEncoder().encode(JWT_SECRET);

function reqWith(headers: Record<string, string> = {}): Request {
  return new Request('http://localhost/v1/ops/admin', {
    method: 'POST',
    headers,
    body: '{}',
  });
}

Deno.test('admin_auth: missing Authorization → reason=missing', async () => {
  const svc = serviceClient();
  await assertRejects(
    () => verifyAdminAuth(reqWith(), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'missing');
    assertEquals(adminAuthErrorHttp(err).status, 401);
  });
});

Deno.test('admin_auth: non-Bearer Authorization → reason=malformed', async () => {
  const svc = serviceClient();
  await assertRejects(
    () => verifyAdminAuth(reqWith({ authorization: 'Basic abc' }), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'malformed');
  });
});

Deno.test('admin_auth: non-JWT token → reason=malformed', async () => {
  const svc = serviceClient();
  await assertRejects(
    () => verifyAdminAuth(reqWith({ authorization: 'Bearer not.a.jwt' }), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'malformed');
  });
});

Deno.test('admin_auth: expired JWT → reason=expired', async () => {
  const svc = serviceClient();
  const admin = await seedAdmin();
  const expiredJwt = await new jose.SignJWT({
    sub: admin.authUserId,
    role: 'authenticated',
    aal: 'aal1',
    session_id: crypto.randomUUID(),
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('http://127.0.0.1:54321/auth/v1')
    .setAudience('authenticated')
    .setSubject(admin.authUserId)
    .setIssuedAt(Math.floor(Date.now() / 1000) - 3600)
    .setExpirationTime(Math.floor(Date.now() / 1000) - 60)
    .sign(SECRET);

  await assertRejects(
    () => verifyAdminAuth(reqWith({ authorization: `Bearer ${expiredJwt}` }), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'expired');
  });
});

Deno.test('admin_auth: wrong audience → reason=wrong_audience', async () => {
  const svc = serviceClient();
  const admin = await seedAdmin();
  const wrongAudJwt = await new jose.SignJWT({
    sub: admin.authUserId,
    role: 'authenticated',
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('http://127.0.0.1:54321/auth/v1')
    .setAudience('anon')
    .setSubject(admin.authUserId)
    .setIssuedAt(Math.floor(Date.now() / 1000))
    .setExpirationTime(Math.floor(Date.now() / 1000) + 3600)
    .sign(SECRET);

  await assertRejects(
    () => verifyAdminAuth(reqWith({ authorization: `Bearer ${wrongAudJwt}` }), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'wrong_audience');
  });
});

Deno.test('admin_auth: iOS session JWT (iss=stir-backend) → reason=wrong_issuer', async () => {
  const svc = serviceClient();
  const session = await quickBootstrap();
  await assertRejects(
    () => verifyAdminAuth(reqWith({ authorization: `Bearer ${session.session_jwt}` }), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'wrong_issuer');
  });
});

Deno.test('admin_auth: JWT with unknown iss → reason=wrong_issuer', async () => {
  const svc = serviceClient();
  const admin = await seedAdmin();
  const otherIssJwt = await new jose.SignJWT({
    sub: admin.authUserId,
    role: 'authenticated',
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer('https://evil.example.com/auth/v1/oops')
    .setAudience('authenticated')
    .setSubject(admin.authUserId)
    .setIssuedAt(Math.floor(Date.now() / 1000))
    .setExpirationTime(Math.floor(Date.now() / 1000) + 3600)
    .sign(SECRET);

  await assertRejects(
    () => verifyAdminAuth(reqWith({ authorization: `Bearer ${otherIssJwt}` }), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'wrong_issuer');
  });
});

Deno.test('admin_auth: non-admin auth user → reason=not_admin', async () => {
  const svc = serviceClient();
  const user = await seedAuthOnlyUser();
  await assertRejects(
    () => verifyAdminAuth(reqWith({ authorization: `Bearer ${user.jwt}` }), svc),
    AdminAuthError,
  ).then((err: AdminAuthError) => {
    assertEquals(err.reason, 'not_admin');
    assertEquals(adminAuthErrorHttp(err).status, 403);
  });
});

Deno.test('admin_auth: valid admin JWT returns identity', async () => {
  const svc = serviceClient();
  const admin = await seedAdmin();

  const identity = await verifyAdminAuth(
    reqWith({ authorization: `Bearer ${admin.jwt}` }),
    svc,
  );
  assertEquals(identity.authUserId, admin.authUserId);
  assertEquals(identity.email, admin.email);
});

Deno.test('admin_auth: minted helper produces tokens this verifier accepts', async () => {
  const svc = serviceClient();
  const admin = await seedAdmin();
  const fresh = await mintAdminAuthJWT({
    userId: admin.authUserId,
    email: admin.email,
    ttlSeconds: 120,
  });

  const identity = await verifyAdminAuth(
    reqWith({ authorization: `Bearer ${fresh}` }),
    svc,
  );
  assertEquals(identity.authUserId, admin.authUserId);
});
