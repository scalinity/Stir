// Cheap-half Gemini Live drift check.
//
// Run: deno run --allow-net --allow-env --allow-read scripts/spike/gemini_live_drift_check.ts
//
// Validates CLAUDE.md Gemini Live sharp edges before step 6 work:
// - API-key auth mints an ephemeral token server-side.
// - The constrained v1alpha WebSocket accepts the returned access_token.
// - The client must send the backend-provided setup frame before turns.
// - PCM16 16 kHz audio frames are accepted without protocol error.
// - usageMetadata still emits token accounting for Live turns.

import { load as loadEnv } from 'https://deno.land/std@0.224.0/dotenv/mod.ts';

const MINT_URL = 'https://generativelanguage.googleapis.com/v1alpha/auth_tokens';
const WS_URL =
  'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained';
const MODEL = 'models/gemini-3.1-flash-live-preview';
const TURN_COVERAGE = 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO';

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

let apiKey = Deno.env.get('GEMINI_API_KEY') ?? '';
if (!apiKey) {
  try {
    const env = await loadEnv({ envPath: 'Backend/supabase/.env', export: false });
    apiKey = env.GEMINI_API_KEY ?? '';
  } catch (_) {
    // .env absent - handled below.
  }
}
if (!apiKey || apiKey.startsWith('placeholder')) {
  console.error('GEMINI_API_KEY is not set to a real key. Export it or populate Backend/supabase/.env.');
  Deno.exit(1);
}
console.log(`GEMINI_API_KEY loaded (len=${apiKey.length}, prefix=${apiKey.slice(0, 4)}...).`);

function buildSetup() {
  return {
    model: MODEL,
    generationConfig: {
      responseModalities: ['AUDIO'],
      speechConfig: { voiceConfig: { prebuiltVoiceConfig: { voiceName: 'Aoede' } } },
      maxOutputTokens: 400,
      thinkingConfig: { thinkingLevel: 'minimal' },
    },
    systemInstruction: {
      parts: [{ text: 'You are a terse test assistant. Reply with one short sentence.' }],
    },
    tools: [],
    realtimeInputConfig: {
      automaticActivityDetection: {
        disabled: false,
        silenceDurationMs: 800,
        prefixPaddingMs: 300,
        startOfSpeechSensitivity: 'START_SENSITIVITY_LOW',
        endOfSpeechSensitivity: 'END_SENSITIVITY_LOW',
      },
      turnCoverage: TURN_COVERAGE,
    },
    inputAudioTranscription: {},
    outputAudioTranscription: {},
  };
}

async function mintToken(): Promise<
  | { tokenName: string; setupFrameJSON: string; raw: unknown }
  | { error: unknown; status: number }
> {
  const now = new Date();
  const setup = buildSetup();
  const body = {
    expireTime: new Date(now.getTime() + 35 * 60_000).toISOString(),
    newSessionExpireTime: new Date(now.getTime() + 60_000).toISOString(),
    uses: 1,
    bidiGenerateContentSetup: setup,
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
  try {
    parsed = JSON.parse(text);
  } catch {
    // keep raw text
  }
  if (!res.ok) return { error: parsed, status: res.status };
  const tokenName = (parsed as { name?: string })?.name;
  if (!tokenName?.startsWith('auth_tokens/')) {
    return { error: { note: 'response missing auth_tokens name field', body: parsed }, status: res.status };
  }
  return { tokenName, setupFrameJSON: JSON.stringify({ setup }), raw: parsed };
}

const minted = await mintToken();
if ('error' in minted) {
  push({ test: 'mint via API-key auth', status: 'fail', detail: `status=${minted.status}`, raw: minted.error });
  console.log('\nDRIFT CHECK SUMMARY:');
  console.log(JSON.stringify(report, null, 2));
  Deno.exit(1);
}

push({
  test: 'mint via API-key auth',
  status: 'pass',
  detail: `received ${minted.tokenName.slice(0, 'auth_tokens/'.length)}... name`,
});

interface ProbeResult {
  setupComplete: boolean;
  audioFrameSent: boolean;
  receivedServerMessage: boolean;
  receivedModelAudio: boolean;
  turnComplete: boolean;
  sampleFrameKeys: string[][];
  usageMetadata: unknown[];
  error?: string;
}

function silencePcm16FrameBase64(): string {
  // 20 ms, PCM16, 16 kHz, mono: 320 samples * 2 bytes.
  return btoa(String.fromCharCode(...new Uint8Array(640)));
}

async function probeWebSocket(tokenName: string, setupFrameJSON: string): Promise<ProbeResult> {
  return await new Promise<ProbeResult>((resolve) => {
    const result: ProbeResult = {
      setupComplete: false,
      audioFrameSent: false,
      receivedServerMessage: false,
      receivedModelAudio: false,
      turnComplete: false,
      sampleFrameKeys: [],
      usageMetadata: [],
    };
    const ws = new WebSocket(`${WS_URL}?access_token=${encodeURIComponent(tokenName)}`);
    const timeout = setTimeout(() => {
      result.error = 'timeout waiting for setupComplete + model audio';
      try {
        ws.close();
      } catch {
        // noop
      }
      resolve(result);
    }, 15_000);

    ws.onopen = () => {
      ws.send(setupFrameJSON);
      setTimeout(() => {
        try {
          ws.send(JSON.stringify({
            realtimeInput: {
              audio: { data: silencePcm16FrameBase64(), mimeType: 'audio/pcm;rate=16000' },
            },
          }));
          result.audioFrameSent = true;
        } catch (err) {
          result.error = err instanceof Error ? err.message : String(err);
        }
      }, 500);
      setTimeout(() => {
        try {
          ws.send(JSON.stringify({ realtimeInput: { text: 'Say ok in one short sentence.' } }));
        } catch (err) {
          result.error = err instanceof Error ? err.message : String(err);
        }
      }, 900);
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
      try {
        parsed = JSON.parse(text);
      } catch {
        // keep raw
      }
      if (typeof parsed === 'object' && parsed != null && result.sampleFrameKeys.length < 6) {
        result.sampleFrameKeys.push(Object.keys(parsed as Record<string, unknown>));
      }
      const obj = parsed as {
        setupComplete?: unknown;
        usageMetadata?: unknown;
        serverContent?: { turnComplete?: boolean; modelTurn?: { parts?: Array<{ inlineData?: { data?: string } }> } };
      };
      if (obj.setupComplete !== undefined) result.setupComplete = true;
      if (obj.usageMetadata) result.usageMetadata.push(obj.usageMetadata);
      const parts = obj.serverContent?.modelTurn?.parts ?? [];
      if (parts.some((part) => typeof part.inlineData?.data === 'string')) result.receivedModelAudio = true;
      if (obj.serverContent?.turnComplete) result.turnComplete = true;
      if (result.setupComplete && result.receivedModelAudio && result.turnComplete) {
        clearTimeout(timeout);
        try {
          ws.close();
        } catch {
          // noop
        }
        resolve(result);
      }
    };

    ws.onerror = (e: Event) => {
      result.error = `ws error: ${(e as ErrorEvent)?.message ?? 'unknown'}`;
    };

    ws.onclose = (e: CloseEvent) => {
      clearTimeout(timeout);
      if (!result.error && !result.setupComplete) {
        result.error = `ws closed before setupComplete (code=${e.code}, reason=${e.reason})`;
      }
      resolve(result);
    };
  });
}

const probe = await probeWebSocket(minted.tokenName, minted.setupFrameJSON);
push({
  test: 'WebSocket setupComplete frame',
  status: probe.setupComplete ? 'pass' : 'fail',
  detail: probe.setupComplete ? 'setupComplete received after explicit setup frame' : probe.error ?? 'missing setupComplete',
  ...(probe.setupComplete ? {} : { raw: probe.sampleFrameKeys }),
});
push({
  test: 'PCM16 audio frame protocol',
  status: probe.audioFrameSent && !probe.error ? 'pass' : 'fail',
  detail: probe.audioFrameSent && !probe.error ? 'audio/pcm;rate=16000 frame accepted without protocol close' : probe.error ?? 'send failed',
});
push({
  test: 'Live model audio response',
  status: probe.receivedModelAudio && probe.turnComplete ? 'pass' : 'fail',
  detail: probe.receivedModelAudio && probe.turnComplete ? 'model audio and turnComplete received' : probe.error ?? 'missing audio/turnComplete',
  ...(probe.receivedModelAudio && probe.turnComplete ? {} : { raw: probe.sampleFrameKeys }),
});
push({
  test: 'usageMetadata emission',
  status: probe.usageMetadata.length > 0 ? 'pass' : 'warn',
  detail: `${probe.usageMetadata.length} usage frames`,
  raw: probe.usageMetadata.map((item) => Object.keys(item as Record<string, unknown>)),
});

const fails = report.filter((r) => r.status === 'fail');
console.log('\nDRIFT CHECK SUMMARY:');
console.log(JSON.stringify({ turn_coverage: TURN_COVERAGE, report }, null, 2));
if (fails.length === 0) {
  console.log('\nAll checks passed. Safe to proceed with step-6 production code.');
  Deno.exit(0);
}
console.log(`\n${fails.length} drift finding(s). Update specs before production code.`);
Deno.exit(1);
