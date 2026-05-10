// Test environment loader.
//
// Explicitly loads Backend/supabase/.env and OVERRIDES any existing env
// vars. Needed because Deno's --env-file doesn't override shell-exported
// vars (and Daniel's shell exports cloud-Supabase values, breaking tests
// that target the local stack).
//
// Every test helper imports this at module load:
//   import './env.ts';
// so the side-effect import runs before any SUPABASE_URL / jwt reads.

const ENV_PATH = new URL('../../.env', import.meta.url);

try {
  const text = Deno.readTextFileSync(ENV_PATH);
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq < 0) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    // Strip surrounding double or single quotes.
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    Deno.env.set(key, value);
  }
} catch (err) {
  throw new Error(
    `tests/_helpers/env.ts: failed to read Backend/supabase/.env — run \`supabase start\` then re-run the env generator. (${
      err instanceof Error ? err.message : String(err)
    })`,
  );
}

// Prod-safety guard: tests call clearRateLimitBuckets() and other
// DELETE operations that would wipe shared state. Even with the
// .env file override above, a misconfigured .env could point at
// cloud. Assert that SUPABASE_URL resolves to localhost at module
// load so any test run against prod fails loudly before any side
// effect lands (Suggestion #13).
const loadedSupabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
if (
  !loadedSupabaseUrl.includes('127.0.0.1') &&
  !loadedSupabaseUrl.includes('localhost')
) {
  throw new Error(
    `tests/_helpers/env.ts: refusing to run tests against non-local SUPABASE_URL=${loadedSupabaseUrl}. ` +
      'Tests issue DELETE statements (rate-limit buckets, test rows) and MUST target the local stack. ' +
      "Run 'supabase start' + re-generate the .env before re-running tests.",
  );
}

// SCA-305 — unlock the env-gated `_setApnsFetchOverrideForTests` DI seam.
// The seam itself stays in production code (it's the cheapest mock surface
// for ES256+APNs), but a synchronous throw fires on any call where this
// env var isn't '1'. Every test that imports a test-helper picks up this
// side-effect import first, so the gate is satisfied by the time any
// `_setApnsFetchOverrideForTests(mock.fetch)` call lands.
Deno.env.set('STIR_TEST_MODE', '1');
