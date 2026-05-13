// Step 9 — _shared/rate_limiter.ts `ipBucket()` — salted (HMAC-SHA256) path + fallback path.
//
// The function is a privacy-grade bucket identifier for source IPs.
// Threat model + rotation runbook: docs/runbooks/ip-salt-rotation.md.

// Must run before any import that reads env at module load.
import './_helpers/env.ts';
import { assertEquals, assertNotEquals, assertMatch } from '@std/assert';
import { ipBucket } from '../functions/_shared/rate_limiter.ts';

Deno.test('ipBucket: empty + unknown produce "unknown"', async () => {
  assertEquals(await ipBucket(''), 'unknown');
  assertEquals(await ipBucket('unknown'), 'unknown');
});

Deno.test('ipBucket: with LOG_IP_SALT set, produces "ip_" prefix with 16 hex chars (HMAC-SHA256 truncated to 64 bits)', async () => {
  const prior = Deno.env.get('LOG_IP_SALT');
  try {
    // Use a deterministic test salt so the bucket value is pinned.
    Deno.env.set('LOG_IP_SALT', 'a'.repeat(64));
    const out = await ipBucket('203.0.113.42');
    assertMatch(out, /^ip_[0-9a-f]{16}$/, `expected ip_<16hex>, got: ${out}`);

    // Same IP + same salt → same bucket (deterministic).
    const again = await ipBucket('203.0.113.42');
    assertEquals(out, again, 'same IP + salt must yield same bucket');

    // Different IP + same salt → different bucket (collision-resistant at 64 bits).
    const other = await ipBucket('198.51.100.17');
    assertNotEquals(out, other, 'different IPs must yield different buckets');
  } finally {
    if (prior === undefined) Deno.env.delete('LOG_IP_SALT');
    else Deno.env.set('LOG_IP_SALT', prior);
  }
});

Deno.test('ipBucket: different salts yield different buckets for the same IP (salt rotation invalidates prior buckets)', async () => {
  const prior = Deno.env.get('LOG_IP_SALT');
  try {
    Deno.env.set('LOG_IP_SALT', 'a'.repeat(64));
    const withSaltA = await ipBucket('203.0.113.42');

    Deno.env.set('LOG_IP_SALT', 'b'.repeat(64));
    const withSaltB = await ipBucket('203.0.113.42');

    assertNotEquals(withSaltA, withSaltB, 'different salts must yield different buckets (rotation invalidates prior)');
  } finally {
    if (prior === undefined) Deno.env.delete('LOG_IP_SALT');
    else Deno.env.set('LOG_IP_SALT', prior);
  }
});

Deno.test('ipBucket: without LOG_IP_SALT, falls back to "unsalted:" prefix (observable misconfig signal)', async () => {
  const prior = Deno.env.get('LOG_IP_SALT');
  try {
    Deno.env.delete('LOG_IP_SALT');
    const out = await ipBucket('203.0.113.42');
    assertMatch(out, /^unsalted:[0-9a-f]{8}$/, `expected unsalted:<8hex> FNV fallback, got: ${out}`);
  } finally {
    if (prior !== undefined) Deno.env.set('LOG_IP_SALT', prior);
  }
});

Deno.test('ipBucket: fallback path is deterministic (same IP → same FNV hex) within a salt-missing window', async () => {
  const prior = Deno.env.get('LOG_IP_SALT');
  try {
    Deno.env.delete('LOG_IP_SALT');
    const a = await ipBucket('203.0.113.42');
    const b = await ipBucket('203.0.113.42');
    assertEquals(a, b);
  } finally {
    if (prior !== undefined) Deno.env.set('LOG_IP_SALT', prior);
  }
});

// ---------------------------------------------------------------------------
// SCA-275 (S9 from /review-5): checkAndIncrement throw-propagation contract
// ---------------------------------------------------------------------------
//
// ops-admin/index.ts and most authenticated /v1/* callers wrap
// `checkAndIncrement` in a try/catch and fall OPEN on any thrown error
// (`log.warn('rate_limiter_failed', ...)` + continue). For those
// post-JWT endpoints fail-open is the right choice — a
// `rate_limit_buckets` glitch must not lock the console or block paid
// users mid-cook — but it depends on `checkAndIncrement` actually
// throwing on RPC failures. If a future refactor swallowed the RPC
// error and returned a "fake allowed" result, fail-open semantics would
// silently flip to fail-closed-on-bug + every-request-allowed, and
// ops dashboards would never see the rate-limiter glitch.
//
// SCA-373 EXCEPTION: session-bootstrap is the only PRE-auth endpoint
// — the IP rate limit is the *only* defense against the synthetic-
// install JWT-farming DoS that SCA-247 added the limiter to stop. So
// session-bootstrap fails CLOSED (503 NET-01 + Retry-After) on a
// thrown checkAndIncrement, breaking the fail-open default. The
// throw-propagation contract this test pins is what makes BOTH
// postures work — bootstrap reads the throw and returns 503; other
// callers read the throw and continue. Future refactors must keep
// the throw.
//
// Pin the contract: when the underlying Supabase RPC errors,
// `checkAndIncrement` propagates rather than silently allowing.

import { checkAndIncrement } from '../functions/_shared/rate_limiter.ts';

Deno.test('checkAndIncrement: RPC error propagates (callers can fail-open)', async () => {
  // Stub a Supabase client whose `.rpc(...)` returns a structured error.
  // The real implementation would return PostgrestError shape; the test
  // harness only needs to drive the same return-shape contract.
  const stubClient = {
    rpc: () =>
      Promise.resolve({
        data: null,
        error: { message: 'simulated rate_limit_buckets infra failure' },
      }),
    // deno-lint-ignore no-explicit-any
  } as any;

  let threw = false;
  try {
    await checkAndIncrement(stubClient, 'ip:ops_admin_hourly', '203.0.113.42');
  } catch (err) {
    threw = true;
    // The caught value is the structured error, not a wrapped Error
    // instance — `if (error) throw error` re-throws verbatim.
    if (typeof err !== 'object' || err === null) {
      throw new Error(`expected structured error object, got: ${String(err)}`);
    }
  }
  if (!threw) {
    throw new Error('checkAndIncrement must throw on RPC error so callers can fail-open');
  }
});

Deno.test('checkAndIncrement: empty result row throws (no SETOF row → no allowed shape)', async () => {
  const stubClient = {
    rpc: () => Promise.resolve({ data: [], error: null }),
    // deno-lint-ignore no-explicit-any
  } as any;

  let threw = false;
  try {
    await checkAndIncrement(stubClient, 'ip:ops_admin_hourly', '203.0.113.42');
  } catch {
    threw = true;
  }
  if (!threw) {
    throw new Error(
      'checkAndIncrement must throw on empty SETOF — caller must NOT receive an undefined RateLimitResult',
    );
  }
});
