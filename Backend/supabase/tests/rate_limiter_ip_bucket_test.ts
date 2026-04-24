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
