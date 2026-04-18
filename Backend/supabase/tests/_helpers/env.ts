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
