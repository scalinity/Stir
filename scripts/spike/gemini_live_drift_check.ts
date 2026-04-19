// Cheap-half Gemini Live drift check.
//
// Run: deno run --allow-net --allow-env --allow-read scripts/spike/gemini_live_drift_check.ts
//
// Validates CLAUDE.md §"Gemini Live — the sharp-edges section" points
// 13-16 before step 6 writes production code. Reports the exact shape
// of any drift so the decision on fallback design (OAuth service-account
// vs backend-proxied WebSocket) can be made immediately.
//
// Budget: ~$0.005 worst-case (one minted token + one trivial turn).

import { load as loadEnv } from 'https://deno.land/std@0.224.0/dotenv/mod.ts';

const MINT_URL   = 'https://generativelanguage.googleapis.com/v1alpha/authTokens';
const WS_URL     = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
const MODEL      = 'models/gemini-3.1-flash-live-preview';

interface DriftReport {
  test: string;
  status: 'pass' | 'fail' | 'warn';
  detail: string;
  raw?: unknown;
}

const report: DriftReport[] = [];
function push(r: DriftReport) {
  const prefix = r.status === 'pass' ? 'PASS' : r.status === 'warn' ? 'WARN' : 'FAIL';
  console.log(`[${prefix}] ${r.test}: ${r.detail}`);
  report.push(r);
}

// ---------------------------------------------------------------------------
// 0. Load API key
// ---------------------------------------------------------------------------

let apiKey = Deno.env.get('GEMINI_API_KEY') ?? '';
if (!apiKey) {
  try {
    const env = await loadEnv({ envPath: 'Backend/supabase/.env', export: false });
    apiKey = env.GEMINI_API_KEY ?? '';
  } catch (_) { /* .env absent — handled below */ }
}
if (!apiKey) {
  console.error('GEMINI_API_KEY is not set. Export it or populate Backend/supabase/.env');
  Deno.exit(1);
}
console.log(`GEMINI_API_KEY loaded (len=${apiKey.length}).`);

// ---------------------------------------------------------------------------
// 1. Mint endpoint — two config variants
// ---------------------------------------------------------------------------
//
// Variant A: new-default turn_coverage = TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO
// Variant B (fallback): old turn_coverage = TURN_INCLUDES_ALL_INPUT
//
// We stop at the first success so we don't burn two mints if A works.

async function mintToken(turnCoverage: string): Promise<{ token: string; raw: unknown } | { error: unknown; status: number }>
{
  const now = new Date();
  const body = {
    authToken: {
      expire_time: new Date(now.getTime() + 35 * 60_000).toISOString(),
      new_session_expire_time: new Date(now.getTime() + 60_000).toISOString(),
      uses: 1,
      bidi_generate_content_setup: {
        model: MODEL,
        generation_config: {
          response_modalities: ['AUDIO'],
          speech_config: { voice_config: { prebuilt_voice_config: { voice_name: 'Aoede' } } },
          max_output_tokens: 150,
          thinking_config: { thinking_level: 'minimal' },
        },
        system_instruction: {
          parts: [{ text: 'You are a terse test assistant. Reply with one short sentence.' }],
        },
        tools: [],
        realtime_input_config: {
          automatic_activity_detection: { disabled: false },
          turn_coverage: turnCoverage,
        },
      },
    },
  };
  const res = await fetch(MINT_URL, {
    method: 'POST',
    headers: {
      'x-goog-api-key': apiKey,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  let parsed: unknown = text;
  try { parsed = JSON.parse(text); } catch { /* keep raw */ }
  if (!res.ok) return { error: parsed, status: res.status };
  const token = (parsed as { token?: string })?.token;
  if (!token) return { error: { note: 'response missing token field', body: parsed }, status: res.status };
  return { token, raw: parsed };
}

let activeToken: string | null = null;
let activeTurnCoverage: string | null = null;

for (const tc of ['TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO', 'TURN_INCLUDES_ALL_INPUT']) {
  const result = await mintToken(tc);
  if ('token' in result) {
    push({ test: `mint with turn_coverage=${tc}`, status: 'pass', detail: `minted, token len=${result.token.length}`, raw: result.raw });
    activeToken = result.token;
    activeTurnCoverage = tc;
    break;
  }
  push({
    test: `mint with turn_coverage=${tc}`,
    status: 'fail',
    detail: `status=${result.status}`,
    raw: result.error,
  });
}

if (!activeToken) {
  push({ test: 'mint endpoint auth', status: 'fail', detail: 'no turn_coverage variant accepted; API-key auth likely rejected' });
  // Capture the state of the report so step-6 backend code can commit to the
  // fallback design (OAuth service-account vs backend-proxied WebSocket).
  console.log('\nDRIFT CHECK SUMMARY:');
  console.log(JSON.stringify(report, null, 2));
  console.log('\nFallback paths (choose one before building /v1/ai/realtime-session):');
  console.log('  A) OAuth service-account credential server-side (still keeps key off client)');
  console.log('  B) Backend-proxied WebSocket (Edge Function holds Gemini connection; +100-300ms TTFA)');
  Deno.exit(1);
}

// ---------------------------------------------------------------------------
// 2. WebSocket connect + trivial turn
// ---------------------------------------------------------------------------

interface ProbeResult {
  setupComplete: boolean;
  receivedServerMessage: boolean;
  sampleFrames: unknown[];
  usageMetadata: unknown[];
  error?: string;
}

async function probeWebSocket(token: string): Promise<ProbeResult> {
  return new Promise<ProbeResult>((resolve) => {
    const result: ProbeResult = { setupComplete: false, receivedServerMessage: false, sampleFrames: [], usageMetadata: [] };
    // Deno's WebSocket doesn't accept custom headers. Gemini Live accepts the
    // token either as `Authorization: Token <value>` (documented) or as an
    // `access_token` query param. Fall back to the query-param form from
    // Deno; in production, iOS uses URLSessionWebSocketTask which DOES
    // support setting the Authorization header.
    const url = `${WS_URL}?access_token=${encodeURIComponent(token)}`;
    const ws = new WebSocket(url);

    // Hard cap: 15s for the full round-trip.
    const timeout = setTimeout(() => {
      result.error = 'timeout waiting for setup-complete + response';
      try { ws.close(); } catch { /* noop */ }
      resolve(result);
    }, 15_000);

    ws.onopen = () => {
      // The session config was baked into the ephemeral token's
      // bidi_generate_content_setup, so iOS does NOT need to send a
      // SETUP frame. Send a realtimeInput.text to elicit a response.
      // (clientContent is history-only on 3.1 Flash Live per CLAUDE.md #11.)
      const turn = {
        realtimeInput: {
          text: 'Say hello in five words.',
        },
      };
      ws.send(JSON.stringify(turn));
    };

    ws.onmessage = async (evt: MessageEvent) => {
      result.receivedServerMessage = true;
      let text: string;
      if (typeof evt.data === 'string') {
        text = evt.data;
      } else if (evt.data instanceof Blob) {
        text = await evt.data.text();
      } else if (evt.data instanceof ArrayBuffer) {
        text = new TextDecoder().decode(evt.data);
      } else {
        text = String(evt.data);
      }
      let parsed: unknown = text;
      try { parsed = JSON.parse(text); } catch { /* keep raw */ }
      if (result.sampleFrames.length < 5) result.sampleFrames.push(parsed);
      const obj = parsed as { setupComplete?: unknown; usageMetadata?: unknown; serverContent?: { turnComplete?: boolean } };
      if (obj.setupComplete !== undefined) result.setupComplete = true;
      if (obj.usageMetadata) result.usageMetadata.push(obj.usageMetadata);
      if (obj.serverContent?.turnComplete) {
        clearTimeout(timeout);
        try { ws.close(); } catch { /* noop */ }
        resolve(result);
      }
    };

    ws.onerror = (e: Event) => {
      result.error = `ws error: ${(e as ErrorEvent)?.message ?? 'unknown'}`;
    };

    ws.onclose = (e: CloseEvent) => {
      clearTimeout(timeout);
      if (!result.setupComplete && !result.error) {
        result.error = `ws closed without setup-complete (code=${e.code}, reason=${e.reason})`;
      }
      resolve(result);
    };
  });
}

const probe = await probeWebSocket(activeToken);
if (probe.setupComplete) {
  push({ test: 'WebSocket setupComplete frame', status: 'pass', detail: `turn_coverage=${activeTurnCoverage}` });
} else {
  push({ test: 'WebSocket setupComplete frame', status: 'fail', detail: probe.error ?? 'no setup-complete received', raw: probe.sampleFrames });
}
if (probe.receivedServerMessage) {
  push({ test: 'WebSocket any message received', status: 'pass', detail: `sampled ${probe.sampleFrames.length} frames` });
} else {
  push({ test: 'WebSocket any message received', status: 'fail', detail: probe.error ?? 'silent' });
}
if (probe.usageMetadata.length > 0) {
  push({ test: 'usageMetadata emission', status: 'pass', detail: `${probe.usageMetadata.length} usage frames`, raw: probe.usageMetadata });
} else {
  push({ test: 'usageMetadata emission', status: 'warn', detail: 'no usageMetadata before turn complete — likely text-only turn was too small' });
}

// ---------------------------------------------------------------------------
// 3. Summary
// ---------------------------------------------------------------------------

const fails = report.filter((r) => r.status === 'fail');
console.log('\nDRIFT CHECK SUMMARY:');
console.log(JSON.stringify({ active_turn_coverage: activeTurnCoverage, report }, null, 2));
if (fails.length === 0) {
  console.log('\nAll checks passed. Safe to proceed with step-6 production code.');
  Deno.exit(0);
} else {
  console.log(`\n${fails.length} drift finding(s). Update CLAUDE.md + Cook Mode Architecture doc before production code.`);
  Deno.exit(1);
}
