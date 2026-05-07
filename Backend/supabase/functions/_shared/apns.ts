// APNs (Apple Push Notification service) sender.
//
// Signs a bearer token with ES256 over the APNs_AUTH_KEY_P8 (base64-encoded
// PKCS#8 ECDSA P-256 private key) and POSTs to api.push.apple.com (prod) or
// api.sandbox.push.apple.com (sandbox). HTTP/2 required — Supabase Edge
// Functions' Deno fetch supports it natively.
//
// Caller supplies:
//   - token          hex device token from UNUserNotificationCenter
//   - environment    'production' | 'sandbox' (matches device_installations
//                    CHECK constraint; iOS DEBUG builds send 'sandbox', Release
//                    sends 'production')
//   - category       'reactivation' | 'import_completion' | 'cook_reminder'
//   - alert          { title, body }
//   - data?          custom key/value for deep-link routing in iOS
//
// Return: { apnsId } on success, or { error: { reason, status } } on APNs
// rejection. Caller decides retry vs mark-token-dead.
//
// Retry-classification:
//   - 400 BadDeviceToken / 410 Unregistered → token dead; caller nulls out
//     device_installations.push_token
//   - 429 TooManyRequests / 5xx             → retry via notification_jobs
//                                              backoff
//   - 403 MissingProviderToken / signing    → config bug; log + alert

import * as jose from 'jose';

// Env vars read inside each call (not at module load) so tests can inject
// fake credentials after import. Real runtime reads are cheap (~µs).
function readApnsEnv(): {
  keyId: string | undefined;
  keyP8: string | undefined;
  teamId: string | undefined;
  bundleId: string | undefined;
} {
  return {
    keyId:    Deno.env.get('APNS_AUTH_KEY_ID'),
    keyP8:    Deno.env.get('APNS_AUTH_KEY_P8'),
    teamId:   Deno.env.get('APNS_TEAM_ID'),
    bundleId: Deno.env.get('APNS_BUNDLE_ID'),
  };
}

// Cached JWT + expiry. APNs requires a new token every 20–60 minutes;
// minting on every call is cheap but wasteful. Cache at module scope —
// Edge Function worker lifetime is ~30 min on average so this amortizes
// across many sends per worker. `mintingPromise` coalesces concurrent
// cold-worker mint attempts so we sign ES256 once, not N times per
// contended cold-start window.
let cachedProviderJwt: string | null = null;
let cachedProviderJwtExpiresAt = 0; // seconds since epoch
let mintingPromise: Promise<string> | null = null;
const PROVIDER_JWT_TTL_SECONDS = 30 * 60; // APNs accepts up to 60 min; we use 30.
const APNS_FETCH_TIMEOUT_MS = 10_000; // Stall guard — APNs HTTP/2 normally < 500 ms.

export type APNsEnvironment = 'production' | 'sandbox';
export type APNsCategory = 'reactivation' | 'import_completion' | 'cook_reminder';

export interface APNsPushInput {
  token: string;
  environment: APNsEnvironment;
  category: APNsCategory;
  alert: { title: string; body: string };
  /** Custom key/value pairs merged into the APS payload root for iOS deep-linking. */
  data?: Record<string, unknown>;
  /** APNs thread-id — groups notifications in Notification Center. */
  threadId?: string;
}

export type APNsPushResult =
  | { ok: true; apnsId: string }
  | { ok: false; reason: APNsFailureReason; status: number; apnsReason?: string };

export type APNsFailureReason =
  | 'bad_device_token'      // 400/410 — token dead, null it out
  | 'config_invalid'         // 403 / signing failure
  | 'rate_limited'           // 429
  | 'server_error'           // 5xx — retry via backoff
  | 'network'                // fetch threw
  | 'missing_secret';        // env var missing at call time

async function getProviderJwt(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedProviderJwt && now < cachedProviderJwtExpiresAt - 60) {
    return cachedProviderJwt;
  }

  // Coalesce concurrent mint attempts on a cold worker — the first call
  // in creates the promise; later arrivers await the same work.
  if (mintingPromise) return mintingPromise;

  mintingPromise = (async () => {
    const { keyId, keyP8, teamId } = readApnsEnv();
    if (!keyP8 || !keyId || !teamId) {
      throw new Error('APNs config missing: need APNS_AUTH_KEY_P8 + APNS_AUTH_KEY_ID + APNS_TEAM_ID');
    }

    // Decode base64 → PEM-wrap for jose.importPKCS8. importPKCS8 throws on
    // malformed DER/ASN.1; we let that propagate so operators see the real
    // parse error rather than an opaque "config_invalid".
    const rawPem = new TextDecoder().decode(base64Decode(keyP8));
    const pem = rawPem.includes('BEGIN PRIVATE KEY')
      ? rawPem
      : `-----BEGIN PRIVATE KEY-----\n${rawPem.match(/.{1,64}/g)?.join('\n') ?? rawPem}\n-----END PRIVATE KEY-----`;

    let privateKey;
    try {
      privateKey = await jose.importPKCS8(pem, 'ES256');
    } catch (err) {
      // Wrap with a clearer message; readers of logs should know this is
      // a deploy-time misconfig, not a wire/APNs problem.
      throw new Error(
        `APNS_AUTH_KEY_P8 did not parse as ES256 PKCS#8: ${err instanceof Error ? err.message : String(err)}`,
      );
    }

    const minted = await new jose.SignJWT({})
      .setProtectedHeader({ alg: 'ES256', kid: keyId })
      .setIssuer(teamId)
      .setIssuedAt(now)
      .sign(privateKey);

    cachedProviderJwt = minted;
    cachedProviderJwtExpiresAt = now + PROVIDER_JWT_TTL_SECONDS;
    return minted;
  })();

  try {
    return await mintingPromise;
  } finally {
    mintingPromise = null;
  }
}

function base64Decode(b64: string): Uint8Array {
  const bin = atob(b64.replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Send a single APNs push. Never throws — all failures surface as structured results. */
export async function sendAPNsPush(input: APNsPushInput): Promise<APNsPushResult> {
  const { bundleId } = readApnsEnv();
  if (!bundleId) {
    return { ok: false, reason: 'missing_secret', status: 0, apnsReason: 'APNS_BUNDLE_ID not set' };
  }

  let providerJwt: string;
  try {
    providerJwt = await getProviderJwt();
  } catch (err) {
    return {
      ok: false,
      reason: err instanceof Error && err.message.includes('missing')
        ? 'missing_secret'
        : 'config_invalid',
      status: 0,
      apnsReason: err instanceof Error ? err.message : String(err),
    };
  }

  const host = input.environment === 'production'
    ? 'api.push.apple.com'
    : 'api.sandbox.push.apple.com';
  const url = `https://${host}/3/device/${encodeURIComponent(input.token)}`;

  const apsPayload: Record<string, unknown> = {
    aps: {
      alert: { title: input.alert.title, body: input.alert.body },
      sound: 'default',
      'thread-id': input.threadId ?? input.category,
      'content-available': 1,
    },
    ...(input.data ?? {}),
  };

  const headers: Record<string, string> = {
    'authorization': `bearer ${providerJwt}`,
    'apns-topic': bundleId,
    'apns-push-type': 'alert',
    'apns-priority': '5',
    'apns-collapse-id': input.category,
    'content-type': 'application/json',
  };

  let res: Response;
  try {
    res = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(apsPayload),
      signal: AbortSignal.timeout(APNS_FETCH_TIMEOUT_MS),
    });
  } catch (err) {
    return {
      ok: false,
      reason: 'network',
      status: 0,
      apnsReason: err instanceof Error ? err.message : String(err),
    };
  }

  if (res.ok) {
    return { ok: true, apnsId: res.headers.get('apns-id') ?? '' };
  }

  // APNs returns JSON {reason:"BadDeviceToken"|"Unregistered"|...} on error.
  let apnsReason: string | undefined;
  try {
    const errBody = await res.json();
    apnsReason = typeof errBody?.reason === 'string' ? errBody.reason : undefined;
  } catch { /* ignore */ }

  // Classify by BOTH status and apnsReason. Apple documents 400 as covering
  // BadDeviceToken *and* a family of payload/config bugs (BadExpirationDate,
  // BadMessageId, BadPath, BadTopic, PayloadEmpty, PayloadTooLarge). Mapping
  // all 400s to bad_device_token would cause the caller (pgmq-dispatch) to
  // null out healthy push tokens on payload regressions. 410 is always
  // Unregistered (dead token). Everything else routes by status.
  const failReason = ((): APNsFailureReason => {
    if (res.status === 410) return 'bad_device_token';
    if (res.status === 400) {
      // 400 + explicit BadDeviceToken/BadExpirationDate mapping per Apple:
      // BadDeviceToken is the only 400 that means "token is dead and future
      // sends to this token will keep failing." Everything else is a
      // config/payload bug — retryable only after ops intervention.
      if (apnsReason === 'BadDeviceToken') return 'bad_device_token';
      return 'config_invalid';
    }
    if (res.status === 403) return 'config_invalid'; // MissingProviderToken
    if (res.status === 429) return 'rate_limited';
    if (res.status >= 500) return 'server_error';
    return 'config_invalid';
  })();

  return {
    ok: false,
    reason: failReason,
    status: res.status,
    ...(apnsReason !== undefined ? { apnsReason } : {}),
  };
}
