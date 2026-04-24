// Step 8 Phase 2 — verifySessionJWT reauth_required enforcement.
//
// Contract (P1.1b COMMENT + ADR 0023):
//   - reauth_required_at NULL (default) → no check runs
//   - reauth_required_at > JWT.iat      → throw AuthError('reauth_required')
//   - reauth_required_at <= JWT.iat     → pass normally
//   - client omitted from verifySessionJWT → check skipped entirely
//
// Force-reauth is self-expiring: bumping reauth_required_at invalidates
// every JWT issued BEFORE the bump; fresh JWTs minted AFTER the bump pass
// naturally because their iat is greater.

import './_helpers/env.ts';
import { assertEquals, assertRejects } from '@std/assert';
import {
  AuthError,
  issueSessionJWT,
  verifySessionJWT,
} from '../functions/_shared/auth.ts';
import { clearRateLimitBuckets, serviceClient } from './_helpers/pg.ts';
import { quickBootstrap } from './_helpers/factory.ts';

await clearRateLimitBuckets();

function reqWithJWT(jwt: string): Request {
  return new Request('http://localhost/v1/test', {
    headers: { Authorization: `Bearer ${jwt}` },
  });
}

Deno.test('verifySessionJWT: reauth_required_at NULL → no check, JWT passes', async () => {
  const session = await quickBootstrap();
  const client = serviceClient();

  // Bootstrap creates user with reauth_required_at = NULL by default.
  const claims = await verifySessionJWT(reqWithJWT(session.session_jwt), client);
  assertEquals(claims.canonical_user_key, session.canonical_user_key);
});

Deno.test('verifySessionJWT: client omitted → check STILL runs (review C1 fix — internal client)', async () => {
  // Pre-fix contract was "check skipped when client omitted". Force-reauth
  // was dead code because no production caller passed the client. Post-fix
  // (review C1): verifySessionJWT creates a module-scope service client
  // internally so the gate runs universally. Sleep 1.1s so iat < reauthAt.
  const session = await quickBootstrap();
  const svc = serviceClient();
  await new Promise((r) => setTimeout(r, 1100));

  await svc
    .from('app_users')
    .update({ reauth_required_at: new Date().toISOString() })
    .eq('canonical_user_key', session.canonical_user_key);

  await assertRejects(
    () => verifySessionJWT(reqWithJWT(session.session_jwt)),
    AuthError,
  ).then((err: AuthError) => {
    assertEquals(err.reason, 'reauth_required');
  });
});

Deno.test('verifySessionJWT: iat == reauth_required_at (same-second collision) → rejects (review W5 iat<= fix)', async () => {
  // Pre-fix: iat < reauthAtSec (strict less-than) passed same-second
  // collisions. Real timing: JWT iat is Math.floor(Date.now()/1000) and
  // Postgres now() truncates to seconds — same-second writes produce
  // identical integers. Post-fix: iat <= reauthAtSec rejects conservatively.
  const session = await quickBootstrap();
  const svc = serviceClient();
  const iatSec = Math.floor(Date.now() / 1000);

  const jwt = await issueSessionJWT({
    canonical_user_key: session.canonical_user_key,
    installation_id: crypto.randomUUID(),
    tier: 'free',
  });

  // Write reauth_required_at at exactly the same second as the JWT iat.
  await svc
    .from('app_users')
    .update({ reauth_required_at: new Date(iatSec * 1000).toISOString() })
    .eq('canonical_user_key', session.canonical_user_key);

  await assertRejects(
    () => verifySessionJWT(reqWithJWT(jwt), serviceClient()),
    AuthError,
  ).then((err: AuthError) => {
    assertEquals(err.reason, 'reauth_required');
  });
});

Deno.test('verifySessionJWT: JWT.iat < reauth_required_at → AuthError reauth_required', async () => {
  const session = await quickBootstrap();
  const svc = serviceClient();

  // JWT issued at time T. Bump reauth_required_at to T+10s — forces the
  // comparison to reject. We use a manually-minted JWT so iat is deterministic.
  const iat = Math.floor(Date.now() / 1000);
  const stale = await issueSessionJWT(
    {
      canonical_user_key: session.canonical_user_key,
      installation_id: crypto.randomUUID(),
      tier: 'free',
    },
    { ttlSeconds: 3600 },
  );

  // Set reauth_required_at 10 seconds in the future relative to JWT iat.
  // Since issueSessionJWT uses `now()`, we just bump to 10s from now.
  await svc
    .from('app_users')
    .update({ reauth_required_at: new Date((iat + 10) * 1000).toISOString() })
    .eq('canonical_user_key', session.canonical_user_key);

  const client = serviceClient();
  await assertRejects(
    () => verifySessionJWT(reqWithJWT(stale), client),
    AuthError,
  ).then((err: AuthError) => {
    assertEquals(err.reason, 'reauth_required');
  });
});

Deno.test('verifySessionJWT: JWT.iat > reauth_required_at → passes (fresh JWT after bump)', async () => {
  const session = await quickBootstrap();
  const svc = serviceClient();

  // Simulate: admin bumped reauth_required_at 60s AGO. Then user re-bootstrapped,
  // getting a fresh JWT with iat=now. Fresh JWT must pass.
  const pastStamp = new Date(Date.now() - 60_000).toISOString();
  await svc
    .from('app_users')
    .update({ reauth_required_at: pastStamp })
    .eq('canonical_user_key', session.canonical_user_key);

  const freshJwt = await issueSessionJWT({
    canonical_user_key: session.canonical_user_key,
    installation_id: crypto.randomUUID(),
    tier: 'free',
  });

  const client = serviceClient();
  const claims = await verifySessionJWT(reqWithJWT(freshJwt), client);
  assertEquals(claims.canonical_user_key, session.canonical_user_key);
});

Deno.test('verifySessionJWT: unknown canonical_user_key → no error, check is row-missing-safe', async () => {
  // If app_users row doesn't exist (edge case — shouldn't happen post-bootstrap,
  // but defensively: don't fail closed on a DB-row miss at this layer).
  const ghostJwt = await issueSessionJWT({
    canonical_user_key: 'install:ghost-' + crypto.randomUUID(),
    installation_id: crypto.randomUUID(),
    tier: 'free',
  });
  const client = serviceClient();
  const claims = await verifySessionJWT(reqWithJWT(ghostJwt), client);
  // Passes through verifySessionJWT; identity-resolution at the handler layer
  // will produce user_stale or re-create the row as appropriate.
  assertEquals(claims.canonical_user_key.startsWith('install:ghost-'), true);
});

Deno.test('admin force_reauth → subsequent verifySessionJWT rejects → fresh bootstrap passes', async () => {
  const svc = serviceClient();

  // 1. User bootstraps → JWT1 with iat=T0.
  const session1 = await quickBootstrap();

  // Sleep 1.1s so reauth_required_at=now() lands in a CLOCK SECOND strictly
  // AFTER the JWT.iat. JWT iat is `Math.floor(Date.now()/1000)` (one-second
  // resolution) so same-second writes compare equal and the `<` gate
  // doesn't fire. Real force_reauth flow has admin latency baked in; this
  // sleep simulates that.
  await new Promise((r) => setTimeout(r, 1100));

  // 2. Admin calls force_reauth → app_users.reauth_required_at = T1 > T0.
  const { error: reauthErr } = await svc.rpc('stir_ops_force_reauth', {
    p_canonical_user_key: session1.canonical_user_key,
  });
  assertEquals(reauthErr, null);

  // 3. JWT1 now fails verifySessionJWT.
  const client = serviceClient();
  await assertRejects(
    () => verifySessionJWT(reqWithJWT(session1.session_jwt), client),
    AuthError,
  ).then((err: AuthError) => {
    assertEquals(err.reason, 'reauth_required');
  });

  // 4. User re-bootstraps — fresh install_id simulating iOS SIWA re-flow.
  //    (In real flow, iOS rotates Keychain install_id; here we just bootstrap
  //    again with a new install_id for the same canonical user path. Since
  //    this test seeds an install-keyed user, the new bootstrap creates a
  //    fresh canonical_user_key unless we preserve CK; for simplicity we
  //    test the invariant that the FRESH JWT passes its own verification.)
  //    Sleep 1s so the fresh JWT's iat clocks forward past the bump time.
  await new Promise((r) => setTimeout(r, 1100));
  const freshJwt = await issueSessionJWT({
    canonical_user_key: session1.canonical_user_key,
    installation_id: crypto.randomUUID(),
    tier: 'free',
  });

  const claims = await verifySessionJWT(reqWithJWT(freshJwt), client);
  assertEquals(claims.canonical_user_key, session1.canonical_user_key);
});
