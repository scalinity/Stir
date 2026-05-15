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
//                    | 'billing_grace'
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

import * as jose from "jose";

// Env vars read inside each call (not at module load) so tests can inject
// fake credentials after import. Real runtime reads are cheap (~µs).
function readApnsEnv(): {
  keyId: string | undefined;
  keyP8: string | undefined;
  teamId: string | undefined;
  bundleId: string | undefined;
} {
  return {
    keyId: Deno.env.get("APNS_AUTH_KEY_ID"),
    keyP8: Deno.env.get("APNS_AUTH_KEY_P8"),
    teamId: Deno.env.get("APNS_TEAM_ID"),
    bundleId: Deno.env.get("APNS_BUNDLE_ID"),
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

// Test-only fetch DI seam (SCA-115). Production code path uses
// `globalThis.fetch` directly; integration tests substitute a mock that
// records calls, scripts response codes, and asserts header shape without
// hitting Apple. Keep the override module-scoped so a misuse in prod
// would surface as a test-only export being called — there is no
// public production path that sets this. Underscore-prefixed by
// convention (matches `_resetApnsCacheForTests`).
type ApnsFetch = (input: string, init: RequestInit) => Promise<Response>;
let apnsFetchOverride: ApnsFetch | null = null;

/**
 * Test-only: install a fetch override the next `sendAPNsPush` call will
 * use instead of `globalThis.fetch`.
 *
 * **DO NOT call from production code** — this is the dependency-injection
 * seam called out in SCA-115. The production path resolves to
 * `globalThis.fetch` on every call (no cache, no module-scoped state) so
 * the override never persists past a test that explicitly clears it.
 *
 * SCA-305: env-gated. The seam is preserved (deliberate DI surface,
 * cheaper than a full mock-able transport interface) but any caller
 * outside test mode throws synchronously. `STIR_TEST_MODE=1` is set by
 * `tests/_helpers/env.ts` before any test imports this module; the
 * deployed `supabase functions deploy` environment never sets it.
 * The check is a fail-fast tripwire — there is no public production
 * path that calls this, so the throw doubles as a regression guard if
 * one is ever added by accident.
 */
export function _setApnsFetchOverrideForTests(fn: ApnsFetch | null): void {
  if (Deno.env.get("STIR_TEST_MODE") !== "1") {
    throw new Error(
      "_setApnsFetchOverrideForTests called outside test mode — this is a " +
        "test-only DI seam (SCA-115); production code must use globalThis.fetch. " +
        "Set STIR_TEST_MODE=1 in the test harness.",
    );
  }
  apnsFetchOverride = fn;
}

export type APNsEnvironment = "production" | "sandbox";
export type APNsCategory =
  | "reactivation"
  | "import_completion"
  | "cook_reminder"
  | "billing_grace";

// SCA-296 C1 / SCA-327: narrow a nullable apns_environment (the schema
// lets device_installations.apns_environment be NULL — the CHECK only
// constrains non-null values) to the two values downstream
// PushSendPayloadSchema.environment accepts. Returns null if the raw
// value isn't a valid APNs environment so callers can skip enqueue +
// log a typed warning instead of poisoning notification_jobs with a
// row that burns MAX_ATTEMPTS retries before dead-lettering.
//
// Originally lived in pgmq-dispatch/push_send.ts (SCA-296 C1). Hoisted
// to _shared/apns.ts (SCA-327) so the second enqueue site —
// revenuecat-webhook/index.ts BILLING_ISSUE — picks up the same guard
// without a circular import on the push_send module (which carries
// PushSendPayloadSchema + processPushSend, neither of which the webhook
// needs). push_send.ts re-exports this so existing imports keep
// working.
export function validatePushEnvironment(
  raw: string | null | undefined,
): APNsEnvironment | null {
  return raw === "production" || raw === "sandbox" ? raw : null;
}

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
  | {
    ok: false;
    reason: APNsFailureReason;
    status: number;
    apnsReason?: string;
  };

export type APNsFailureReason =
  | "bad_device_token" // 400/410 — token dead, null it out
  | "config_invalid" // 403 / signing failure
  | "rate_limited" // 429
  | "server_error" // 5xx — retry via backoff
  | "network" // fetch threw
  | "missing_secret"; // env var missing at call time

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
      throw new Error(
        "APNs config missing: need APNS_AUTH_KEY_P8 + APNS_AUTH_KEY_ID + APNS_TEAM_ID",
      );
    }

    // Decode base64 → PEM-wrap for jose.importPKCS8. importPKCS8 throws on
    // malformed DER/ASN.1; we let that propagate so operators see the real
    // parse error rather than an opaque "config_invalid".
    const rawPem = new TextDecoder().decode(base64Decode(keyP8));
    const pem = rawPem.includes("BEGIN PRIVATE KEY")
      ? rawPem
      : `-----BEGIN PRIVATE KEY-----\n${
        rawPem.match(/.{1,64}/g)?.join("\n") ?? rawPem
      }\n-----END PRIVATE KEY-----`;

    let privateKey;
    try {
      privateKey = await jose.importPKCS8(pem, "ES256");
    } catch (err) {
      // Wrap with a clearer message; readers of logs should know this is
      // a deploy-time misconfig, not a wire/APNs problem.
      throw new Error(
        `APNS_AUTH_KEY_P8 did not parse as ES256 PKCS#8: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }

    const minted = await new jose.SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: keyId })
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

/**
 * Test-only: clear the cached provider JWT and any in-flight mintingPromise.
 *
 * Used by `apns_hardening_test.ts` to exercise the cold-start mint-
 * coalescing path (W11) without leaking state from previous tests in the
 * same `deno test` process. **DO NOT call from production code** — the
 * cached JWT is intentionally module-level so it amortizes across an
 * Edge Function worker's lifetime.
 *
 * Underscore-prefixed by convention to mark "internal / test-facing."
 */
export function _resetApnsCacheForTests(): void {
  cachedProviderJwt = null;
  cachedProviderJwtExpiresAt = 0;
  mintingPromise = null;
}

/**
 * SCA-403 — read-only test seam exposing the cached provider JWT.
 * Lets tests assert SCA-352 cache-invalidation by checking the cache
 * directly (`cachedProviderJwt === null`) instead of inferring it from
 * different-bytes-after-different-iat side effects (which required a
 * 1.1s setTimeout per assertion). Tighter contract pin + shaves ~1s
 * off the suite per assertion.
 *
 * Same `STIR_TEST_MODE=1` tripwire as `_setApnsFetchOverrideForTests`
 * so a future production caller throws synchronously instead of
 * silently exposing the cache. Underscore-prefixed by convention.
 */
export function _cachedJwtForTests(): string | null {
  if (Deno.env.get("STIR_TEST_MODE") !== "1") {
    throw new Error(
      "_cachedJwtForTests called outside test mode (STIR_TEST_MODE != '1')",
    );
  }
  return cachedProviderJwt;
}

/**
 * SCA-412 — test seam: roll the cache's "minted at" time backwards by
 * `secondsAgo` so the SCA-412 just-minted guard treats it as aged.
 * Used by SCA-352 cache-invalidation tests that need to exercise the
 * "expired JWT got 401 → invalidate" path; pre-SCA-412 they could
 * just trigger 401 immediately, but the just-minted guard now skips
 * invalidation on fresh mints (correct behavior; protects against
 * mint thrash on key/config bugs).
 *
 * STIR_TEST_MODE=1 tripwire identical to other seams.
 */
export function _ageProviderJwtCacheForTests(secondsAgo: number): void {
  if (Deno.env.get("STIR_TEST_MODE") !== "1") {
    throw new Error(
      "_ageProviderJwtCacheForTests called outside test mode (STIR_TEST_MODE != '1')",
    );
  }
  // Decrement expiresAt so `cacheAge = now - (expiresAt - TTL)` > secondsAgo.
  cachedProviderJwtExpiresAt -= secondsAgo;
}

function base64Decode(b64: string): Uint8Array {
  const bin = atob(b64.replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** Send a single APNs push. Never throws — all failures surface as structured results. */
export async function sendAPNsPush(
  input: APNsPushInput,
): Promise<APNsPushResult> {
  const { bundleId } = readApnsEnv();
  if (!bundleId) {
    return {
      ok: false,
      reason: "missing_secret",
      status: 0,
      apnsReason: "APNS_BUNDLE_ID not set",
    };
  }

  let providerJwt: string;
  try {
    providerJwt = await getProviderJwt();
  } catch (err) {
    return {
      ok: false,
      reason: err instanceof Error && err.message.includes("missing")
        ? "missing_secret"
        : "config_invalid",
      status: 0,
      apnsReason: err instanceof Error ? err.message : String(err),
    };
  }

  const host = input.environment === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  const url = `https://${host}/3/device/${encodeURIComponent(input.token)}`;

  const apsPayload: Record<string, unknown> = {
    aps: {
      alert: { title: input.alert.title, body: input.alert.body },
      sound: "default",
      "thread-id": input.threadId ?? input.category,
      "content-available": 1,
    },
    ...(input.data ?? {}),
  };

  const headers: Record<string, string> = {
    "authorization": `bearer ${providerJwt}`,
    "apns-topic": bundleId,
    "apns-push-type": "alert",
    "apns-priority": "5",
    "apns-collapse-id": input.category,
    "content-type": "application/json",
  };

  let res: Response;
  try {
    const fetchImpl: ApnsFetch = apnsFetchOverride ??
      ((input, init) => fetch(input, init));
    res = await fetchImpl(url, {
      method: "POST",
      headers,
      body: JSON.stringify(apsPayload),
      signal: AbortSignal.timeout(APNS_FETCH_TIMEOUT_MS),
    });
  } catch (err) {
    return {
      ok: false,
      reason: "network",
      status: 0,
      apnsReason: err instanceof Error ? err.message : String(err),
    };
  }

  if (res.ok) {
    return { ok: true, apnsId: res.headers.get("apns-id") ?? "" };
  }

  // APNs returns JSON {reason:"BadDeviceToken"|"Unregistered"|...} on error.
  let apnsReason: string | undefined;
  try {
    const errBody = await res.json();
    apnsReason = typeof errBody?.reason === "string"
      ? errBody.reason
      : undefined;
  } catch { /* ignore */ }

  // SCA-352: 401 = ExpiredProviderToken / InvalidProviderToken. The cached
  // provider JWT we just signed is wrong — invalidate it so the NEXT call
  // (whether retry or fresh) mints fresh. Pre-fix: the cache stayed valid
  // and attempts 2 + 3 burned against the same bad JWT, dead-lettering a
  // legitimate push every NTP-skew or key-rotation race window.
  // SCA-412: bound the invalidation with a "just-minted" guard. Under
  // sustained 401 (wrong APNS_AUTH_KEY_P8 post-deploy, or APNs key
  // rotated and prod env wasn't updated), every pgmq-dispatch worker
  // would otherwise re-mint ES256 → 401 → invalidate → re-mint forever,
  // burning CPU + APNs request budget. If the cache is fresher than 5s,
  // the JWT we just minted got rejected — that's a key/config bug, not
  // a stale-cache bug. Don't thrash; let the existing dead-letter +
  // pgmq-dispatch backoff control the retry rate. Recovery on key
  // rotation: after 5s the cache effectively unblocks itself for a
  // fresh mint attempt. Mint coalescing (mintingPromise) is preserved.
  if (res.status === 401) {
    const cacheAgeSeconds = (Date.now() / 1000) -
      (cachedProviderJwtExpiresAt - PROVIDER_JWT_TTL_SECONDS);
    const justMinted = cacheAgeSeconds < 5;
    if (!justMinted) {
      cachedProviderJwt = null;
      cachedProviderJwtExpiresAt = 0;
      mintingPromise = null;
    }
  }

  // Classify by BOTH status and apnsReason. Apple documents 400 as covering
  // BadDeviceToken *and* a family of payload/config bugs (BadExpirationDate,
  // BadMessageId, BadPath, BadTopic, PayloadEmpty, PayloadTooLarge). Mapping
  // all 400s to bad_device_token would cause the caller (pgmq-dispatch) to
  // null out healthy push tokens on payload regressions. 410 is always
  // Unregistered (dead token). Everything else routes by status.
  const failReason = ((): APNsFailureReason => {
    if (res.status === 410) return "bad_device_token";
    if (res.status === 400) {
      // 400 + explicit BadDeviceToken/BadExpirationDate mapping per Apple:
      // BadDeviceToken is the only 400 that means "token is dead and future
      // sends to this token will keep failing." Everything else is a
      // config/payload bug — retryable only after ops intervention.
      if (apnsReason === "BadDeviceToken") return "bad_device_token";
      return "config_invalid";
    }
    // SCA-352: 401 ExpiredProviderToken — terminal, retries against the
    // same expired JWT all fail (the cache invalidation above lets the
    // NEXT job mint fresh; this call is dead-lettered with an
    // operator-actionable error_message).
    if (res.status === 401) return "config_invalid";
    if (res.status === 403) return "config_invalid"; // MissingProviderToken
    // SCA-352: 404 (path bug) and 405 (Method Not Allowed) are documented
    // Apple permanent failures — treating them as transient under SCA-323
    // burns the retry budget against a known-bad request.
    if (res.status === 404 || res.status === 405) return "config_invalid";
    // SCA-352: 408 (request timeout) is genuinely transient; longer
    // backoff curve fits via rate_limited rather than the default
    // server_error.
    if (res.status === 408) return "rate_limited";
    if (res.status === 429) return "rate_limited";
    if (res.status >= 500) return "server_error";
    // SCA-323: Apple documents only {400, 401, 403, 410, 429} as 4xx APNs
    // responses (https://developer.apple.com/documentation/usernotifications
    // /sending_notification_requests_to_apns#Responses). Anything outside
    // that set (rare 451/503 from gateway maintenance, etc.) pre-fix
    // mapped to `config_invalid`, which `processPushSend` re-throws and
    // pgmq-dispatch retries through MAX_ATTEMPTS, then dead-letters as a
    // permanent config bug. Net: a transient 60s gateway blip burned the
    // retry budget and silently dropped a real push. Treat unknowns as
    // transient server errors so the retry loop has a chance to recover.
    return "server_error";
  })();

  return {
    ok: false,
    reason: failReason,
    status: res.status,
    ...(apnsReason !== undefined ? { apnsReason } : {}),
  };
}
