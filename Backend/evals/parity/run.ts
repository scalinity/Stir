// Text-provider parity check — runner (ADR 0038).
//
// Sends the same request bodies (fixtures.ts) through the real local edge
// functions and records, per request: HTTP status, latency, parsed response
// (dinner-solve: the SSE frames) and the `ai_request_log` row (model, tokens,
// cost). Going through the endpoints means the real prompts, Zod parsing,
// retries and hard-rule validators all run. `compare.ts` diffs two run files.
//
// Operator steps (each run spends real provider credits):
//
//   1. Start the local stack:
//        cd Backend/supabase && supabase start
//      Provider keys (ANTHROPIC_API_KEY, GEMINI_API_KEY) must be in
//      Backend/supabase/functions/.env (`cp .env functions/.env` copies them).
//
//   2. Run once with the default provider (anthropic):
//        STIR_RUN_AI_EVALS=1 deno run --config Backend/supabase/functions/deno.json \
//          --allow-env --allow-net --allow-read --allow-write \
//          Backend/evals/parity/run.ts --label claude --out /tmp/parity-claude.json
//
//   3. Switch to Gemini: add the line  AI_TEXT_PROVIDER=gemini  to
//      Backend/supabase/functions/.env, then restart the stack:
//        cd Backend/supabase && supabase stop && supabase start
//      Run again:
//        STIR_RUN_AI_EVALS=1 deno run ... Backend/evals/parity/run.ts \
//          --label gemini --out /tmp/parity-gemini.json
//
//   4. Remove the AI_TEXT_PROVIDER line from functions/.env, restart the stack
//      again (stop + start) so the default provider is back, then compare:
//        deno run --config Backend/supabase/functions/deno.json \
//          --allow-read --allow-write Backend/evals/parity/compare.ts \
//          /tmp/parity-claude.json /tmp/parity-gemini.json --md /tmp/parity-report.md
//
// Options: --only dinner_solve,substitution,...   run a subset of features
//          --images-dir <dir>                     enable pantry_parse: one request per
//                                                 .jpg/.jpeg in <dir> (skipped otherwise)
//
// compare.ts prints the model each run actually used (from ai_request_log);
// if both runs show the same model the provider switch did not take effect.

import '../../supabase/tests/_helpers/env.ts';
import { gateOrSkip } from '../_shared/harness.ts';
import {
  promoteToPremium,
  quickBootstrap,
  testIPHeaders,
} from '../../supabase/tests/_helpers/factory.ts';
import { clearRateLimitBuckets, serviceClient } from '../../supabase/tests/_helpers/pg.ts';
import {
  type FeatureKey,
  FEATURES,
  type FeatureSpec,
  type Fixture,
  FIXTURES,
  pantryImageFixtures,
  validateFixtures,
} from './fixtures.ts';
import type { AiLogRow, DinnerSolveResponse, RequestRecord, RunFile } from './types.ts';

const FUNCTIONS_URL = Deno.env.get('SUPABASE_URL')
  ? `${Deno.env.get('SUPABASE_URL')}/functions/v1`
  : 'http://127.0.0.1:54321/functions/v1';

const REQUEST_TIMEOUT_MS = 180_000;
const LOG_POLL_TIMEOUT_MS = 5_000;
const LOG_POLL_INTERVAL_MS = 100;
// Error codes whose handlers still write an ai_request_log row (is_error=true).
const ERROR_CODES_WITH_LOG = new Set(['AI-01', 'AI-02', 'IMPORT-01']);

interface Args {
  label: string;
  out: string;
  only: FeatureKey[] | null;
  imagesDir: string | null;
}

function parseArgs(argv: string[]): Args {
  const values = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    if (!flag?.startsWith('--')) throw new Error(`unexpected argument '${flag}'`);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`${flag} needs a value`);
    values.set(flag, value);
    i++;
  }
  for (const key of values.keys()) {
    if (!['--label', '--out', '--only', '--images-dir'].includes(key)) {
      throw new Error(`unknown option ${key}`);
    }
  }
  const label = values.get('--label');
  const out = values.get('--out');
  if (!label || !out) throw new Error('--label <name> and --out <file.json> are required');

  let only: FeatureKey[] | null = null;
  const onlyRaw = values.get('--only');
  if (onlyRaw) {
    only = onlyRaw.split(',').map((s) => {
      const key = s.trim().replaceAll('-', '_');
      const spec = FEATURES.find((f) => f.key === key);
      if (!spec) {
        throw new Error(
          `--only: unknown feature '${s}' (${FEATURES.map((f) => f.key).join(', ')})`,
        );
      }
      return spec.key;
    });
  }
  return { label, out, only, imagesDir: values.get('--images-dir') ?? null };
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

interface RawResponse {
  status: number | null;
  contentType: string;
  cacheHit: boolean;
  text: string;
  headersMs: number;
  totalMs: number;
  networkError: string | null;
}

async function post(endpoint: string, body: unknown, jwt: string): Promise<RawResponse> {
  const started = performance.now();
  try {
    const res = await fetch(`${FUNCTIONS_URL}/${endpoint}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${jwt}`,
        ...testIPHeaders(),
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
    const headersMs = Math.round(performance.now() - started);
    const text = await res.text();
    return {
      status: res.status,
      contentType: res.headers.get('content-type') ?? '',
      cacheHit: res.headers.get('x-cache') === 'hit',
      text,
      headersMs,
      totalMs: Math.round(performance.now() - started),
      networkError: null,
    };
  } catch (err) {
    const elapsed = Math.round(performance.now() - started);
    return {
      status: null,
      contentType: '',
      cacheHit: false,
      text: '',
      headersMs: elapsed,
      totalMs: elapsed,
      networkError: err instanceof Error ? err.message : String(err),
    };
  }
}

/** Splits an SSE body into dish / error / done frames (dinner-solve). */
function parseSse(text: string): DinnerSolveResponse {
  const result: DinnerSolveResponse = { dishes: [], errors: [], done: null };
  for (const frame of text.split(/\r?\n\r?\n/)) {
    let event = '';
    const data: string[] = [];
    for (const line of frame.split(/\r?\n/)) {
      if (line.startsWith('event:')) event = line.slice(6).trim();
      else if (line.startsWith('data:')) data.push(line.slice(5).trim());
    }
    if (!event || data.length === 0) continue;
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(data.join('\n')) as Record<string, unknown>;
    } catch {
      continue;
    }
    if (event === 'dish') result.dishes.push(parsed);
    else if (event === 'error') result.errors.push(parsed);
    else if (event === 'done') result.done = parsed;
  }
  return result;
}

// ---------------------------------------------------------------------------
// ai_request_log
// ---------------------------------------------------------------------------

type ServiceClient = ReturnType<typeof serviceClient>;

// recordAIRequest is fire-and-forget (EdgeRuntime.waitUntil), so the row can
// land just after the response. Poll briefly, same idea as
// awaitAIRequestLogRow in tests/voice_turn_usage_test.ts.
async function fetchLogRow(client: ServiceClient, requestId: string): Promise<AiLogRow | null> {
  const deadline = Date.now() + LOG_POLL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const { data } = await client
      .from('ai_request_log')
      .select(
        'model, input_tokens, output_tokens, cost_usd, latency_ms, retry_count, prompt_version',
      )
      .eq('request_id', requestId)
      .maybeSingle();
    if (data) {
      const row = data as Record<string, unknown>;
      return {
        model: String(row.model),
        input_tokens: Number(row.input_tokens),
        output_tokens: Number(row.output_tokens),
        cost_usd: Number(row.cost_usd),
        latency_ms: Number(row.latency_ms),
        retry_count: row.retry_count === null ? null : Number(row.retry_count),
        prompt_version: row.prompt_version === null ? null : String(row.prompt_version),
      };
    }
    await new Promise((r) => setTimeout(r, LOG_POLL_INTERVAL_MS));
  }
  return null;
}

// ---------------------------------------------------------------------------
// One request
// ---------------------------------------------------------------------------

function redactImages(body: Record<string, unknown>): Record<string, unknown> {
  const image = body.image_base64;
  if (typeof image !== 'string') return body;
  return { ...body, image_base64: `<${image.length} base64 chars>` };
}

async function runOne(
  spec: FeatureSpec,
  fixture: Fixture,
  jwt: string,
  client: ServiceClient,
): Promise<RequestRecord> {
  const body = fixture.build();
  const requestId = String(body[spec.idField]);
  const raw = await post(spec.endpoint, body, jwt);

  let response: unknown = null;
  let errorCode: string | null = null;
  let errorMessage: string | null = null;
  if (raw.networkError) {
    errorCode = 'NETWORK';
    errorMessage = raw.networkError;
  } else if (raw.contentType.includes('text/event-stream')) {
    response = parseSse(raw.text);
  } else {
    try {
      response = JSON.parse(raw.text);
    } catch {
      response = { raw: raw.text.slice(0, 2000) };
    }
    if (raw.status !== 200) {
      const envelope = response as { error?: unknown; message?: unknown };
      errorCode = typeof envelope.error === 'string' ? envelope.error : `HTTP-${raw.status}`;
      errorMessage = typeof envelope.message === 'string' ? envelope.message : null;
    }
  }

  const expectLog = raw.status === 200 ||
    (errorCode !== null && ERROR_CODES_WITH_LOG.has(errorCode));
  return {
    feature: fixture.feature,
    fixture: fixture.name,
    note: fixture.note,
    request_id: requestId,
    request: redactImages(body),
    http_status: raw.status,
    latency_ms: raw.headersMs,
    total_ms: raw.totalMs,
    error_code: errorCode,
    error_message: errorMessage,
    cache_hit: raw.cacheHit,
    response,
    log: expectLog ? await fetchLogRow(client, requestId) : null,
  };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  const skipped = gateOrSkip('stir_text_provider_parity');
  if (skipped) {
    console.error(skipped.skip_reason);
    console.error(
      'To run: STIR_RUN_AI_EVALS=1 deno run --config Backend/supabase/functions/deno.json ' +
        '--allow-env --allow-net --allow-read --allow-write Backend/evals/parity/run.ts ' +
        '--label <name> --out <file.json>',
    );
    Deno.exit(2);
  }

  const args = parseArgs(Deno.args);
  const notes: string[] = [];

  const fixtures: Fixture[] = [...FIXTURES];
  if (args.imagesDir) {
    fixtures.push(...await pantryImageFixtures(args.imagesDir));
  } else if (args.only === null || args.only.includes('pantry_parse')) {
    const note = 'pantry_parse skipped: no --images-dir given.';
    if (args.only !== null && args.only.length === 1) throw new Error(note);
    notes.push(note);
    console.log(note);
  }

  const selected = fixtures.filter((f) => args.only === null || args.only.includes(f.feature));
  if (selected.length === 0) throw new Error('no fixtures selected');

  // Fail before any credits are spent if a body would not pass its schema.
  const failures = validateFixtures(selected).filter((c) => c.errors.length > 0);
  if (failures.length > 0) {
    for (const f of failures) {
      console.error(`invalid fixture ${f.feature}/${f.name}: ${f.errors.join('; ')}`);
    }
    throw new Error(`${failures.length} fixture(s) fail their request schema; nothing was sent`);
  }

  const session = await quickBootstrap();
  await promoteToPremium(session.canonical_user_key);
  const client = serviceClient();
  // usage_counters.cap_count is snapshotted at bootstrap (Free: 6 dinner solves,
  // 2 imports) and promoteToPremium does not refresh it; lift the caps so the
  // sequence is not cut off by RATE-01.
  for (const featureKey of ['dinner_solve', 'recipe_import']) {
    const { error } = await client
      .from('usage_counters')
      .update({ cap_count: 1000 })
      .eq('canonical_user_key', session.canonical_user_key)
      .eq('feature_key', featureKey);
    if (error) throw error;
  }
  console.log(`label=${args.label}  endpoint=${FUNCTIONS_URL}  fixtures=${selected.length}`);

  const startedAt = new Date().toISOString();
  const records: RequestRecord[] = [];
  let index = 0;
  for (const spec of FEATURES) {
    const group = selected.filter((f) => f.feature === spec.key);
    if (group.length === 0) continue;
    // Kong rewrites x-real-ip, so the x-forwarded-for headers do not separate
    // per-IP buckets locally; clearing them per feature keeps the 10/hour user
    // dinner-solve limit and the daily IP limits from tripping mid-run.
    await clearRateLimitBuckets();
    for (const fixture of group) {
      index++;
      const record = await runOne(spec, fixture, session.session_jwt, client);
      records.push(record);
      const cost = record.log ? `$${record.log.cost_usd.toFixed(6)}` : 'no-log';
      console.log(
        `[${index}/${selected.length}] ${spec.key}/${fixture.name}  ` +
          `${record.http_status ?? 'ERR'}${record.error_code ? ` ${record.error_code}` : ''}  ` +
          `${record.latency_ms}ms  ${cost}  ${record.log?.model ?? '-'}`,
      );
    }
  }

  const run: RunFile = {
    label: args.label,
    started_at: startedAt,
    finished_at: new Date().toISOString(),
    functions_url: FUNCTIONS_URL,
    notes,
    records,
  };
  await Deno.writeTextFile(args.out, JSON.stringify(run, null, 2));

  const ok = records.filter((r) => r.http_status === 200).length;
  const models = [...new Set(records.map((r) => r.log?.model).filter((m) => m !== undefined))];
  const total = records.reduce((sum, r) => sum + (r.log?.cost_usd ?? 0), 0);
  console.log(
    `\n${ok}/${records.length} ok  models=${models.join(', ') || '-'}  cost=$${total.toFixed(6)}`,
  );
  console.log(`wrote ${args.out}`);
}

try {
  await main();
} catch (err) {
  console.error(err instanceof Error ? err.message : String(err));
  Deno.exit(1);
}
