// Step 8 Phase 4 — _shared/apns.ts unit tests.
//
// We don't actually hit APNs. Instead we mock globalThis.fetch and assert:
//   - the provider JWT is signed with ES256 over APNS_AUTH_KEY_P8
//   - header shape is correct (authorization, apns-topic, apns-push-type,
//     apns-priority, apns-collapse-id)
//   - URL routes to prod vs sandbox based on environment
//   - error classification (bad_device_token / rate_limited / server_error
//     / config_invalid / network)

import "./_helpers/env.ts";
import { assertEquals, assertNotEquals } from "@std/assert";
import * as jose from "jose";
import { sendAPNsPush } from "../functions/_shared/apns.ts";

// Generate a throwaway ES256 key for the test run. apns.ts expects
// APNS_AUTH_KEY_P8 to be the base64-encoded .p8 file content (full PEM text,
// including BEGIN/END PRIVATE KEY lines).
const { privateKey } = await jose.generateKeyPair("ES256", {
  extractable: true,
});
const pkcs8Pem = await jose.exportPKCS8(privateKey);
Deno.env.set("APNS_AUTH_KEY_P8", btoa(pkcs8Pem));
Deno.env.set("APNS_AUTH_KEY_ID", "TEST1234KEY");
Deno.env.set("APNS_TEAM_ID", "TEAM0123ABC");
Deno.env.set("APNS_BUNDLE_ID", "com.company.stir.dev");

type FetchCall = { url: string; init: RequestInit };

function installMockFetch(
  respond: (call: FetchCall) => Response | Promise<Response>,
): { calls: FetchCall[]; restore: () => void } {
  const original = globalThis.fetch;
  const calls: FetchCall[] = [];
  globalThis.fetch = async (
    input: Request | URL | string,
    init?: RequestInit,
  ): Promise<Response> => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    const effectiveInit: RequestInit = init ?? (input instanceof Request
      ? {
        method: input.method,
        headers: input.headers,
        body: input.body,
      }
      : {});
    const call: FetchCall = { url, init: effectiveInit };
    calls.push(call);
    return await respond(call);
  };
  return {
    calls,
    restore: () => {
      globalThis.fetch = original;
    },
  };
}

Deno.test("sendAPNsPush: signs ES256 bearer token + sets correct headers", async () => {
  const { calls, restore } = installMockFetch(() =>
    new Response(null, {
      status: 200,
      headers: { "apns-id": "test-apns-id-123" },
    })
  );
  try {
    const result = await sendAPNsPush({
      token: "abc123def456",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "Test", body: "Body" },
      data: { deep_link: "stir://tonight" },
    });
    assertEquals(result.ok, true);
    if (result.ok) assertEquals(result.apnsId, "test-apns-id-123");

    assertEquals(calls.length, 1);
    assertEquals(
      calls[0]!.url,
      "https://api.sandbox.push.apple.com/3/device/abc123def456",
    );

    const headers = calls[0]!.init.headers as Record<string, string>;
    const auth: string = headers["authorization"] ?? headers["Authorization"] ??
      "";
    assertEquals(auth.startsWith("bearer "), true);
    assertEquals(headers["apns-topic"], "com.company.stir.dev");
    assertEquals(headers["apns-push-type"], "alert");
    assertEquals(headers["apns-priority"], "5");
    assertEquals(headers["apns-collapse-id"], "reactivation");

    // Verify JWT is ES256 and has kid + iss claims.
    const token = auth.slice("bearer ".length);
    const decoded = jose.decodeJwt(token);
    assertEquals(decoded.iss, "TEAM0123ABC");
    const header = jose.decodeProtectedHeader(token);
    assertEquals(header.alg, "ES256");
    assertEquals(header.kid, "TEST1234KEY");

    // Body includes alert + deep_link (merged into root per iOS deep-link convention).
    const body = JSON.parse(calls[0]!.init.body as string);
    assertEquals(body.aps.alert.title, "Test");
    assertEquals(body.aps.alert.body, "Body");
    assertEquals(body.deep_link, "stir://tonight");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: routes to prod host when environment=production", async () => {
  const { calls, restore } = installMockFetch(() =>
    new Response(null, { status: 200 })
  );
  try {
    await sendAPNsPush({
      token: "prodtoken",
      environment: "production",
      category: "import_completion",
      alert: { title: "t", body: "b" },
    });
    assertEquals(
      calls[0]!.url.startsWith("https://api.push.apple.com/3/device/"),
      true,
    );
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 400 BadDeviceToken → reason=bad_device_token", async () => {
  const { restore } = installMockFetch(() =>
    new Response(
      JSON.stringify({ reason: "BadDeviceToken" }),
      { status: 400, headers: { "content-type": "application/json" } },
    )
  );
  try {
    const result = await sendAPNsPush({
      token: "dead",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
      assertEquals(result.reason, "bad_device_token");
      assertEquals(result.apnsReason, "BadDeviceToken");
    }
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 410 Unregistered → reason=bad_device_token", async () => {
  const { restore } = installMockFetch(() =>
    new Response(
      JSON.stringify({ reason: "Unregistered" }),
      { status: 410, headers: { "content-type": "application/json" } },
    )
  );
  try {
    const result = await sendAPNsPush({
      token: "gone",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "bad_device_token");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 429 TooManyRequests → reason=rate_limited", async () => {
  const { restore } = installMockFetch(() =>
    new Response(
      JSON.stringify({ reason: "TooManyRequests" }),
      { status: 429, headers: { "content-type": "application/json" } },
    )
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "rate_limited");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 503 → reason=server_error (caller retries)", async () => {
  const { restore } = installMockFetch(() =>
    new Response(null, { status: 503 })
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "server_error");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: fetch throws → reason=network", async () => {
  const { restore } = installMockFetch(() => {
    throw new Error("socket timeout");
  });
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
      assertEquals(result.reason, "network");
      assertNotEquals(result.apnsReason, undefined);
    }
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 400 PayloadTooLarge → reason=config_invalid (NOT bad_device_token)", async () => {
  // Pre-fix: every 400 → bad_device_token, so pgmq-dispatch would null
  // healthy tokens on payload/config regressions. Post-fix (review C4):
  // only 400+BadDeviceToken is classified as dead token; all other 400s
  // are config_invalid and surface to ops as retryable-after-intervention.
  const { restore } = installMockFetch(() =>
    new Response(
      JSON.stringify({ reason: "PayloadTooLarge" }),
      { status: 400, headers: { "content-type": "application/json" } },
    )
  );
  try {
    const result = await sendAPNsPush({
      token: "healthy_token",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
      assertEquals(result.reason, "config_invalid");
      assertEquals(result.apnsReason, "PayloadTooLarge");
    }
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 400 with unparseable body → reason=config_invalid (conservative)", async () => {
  // No JSON body / apnsReason unknown → don't assume bad_device_token.
  // Conservative choice: config_invalid preserves the device token while
  // surfacing the failure to ops.
  const { restore } = installMockFetch(() => new Response("", { status: 400 }));
  try {
    const result = await sendAPNsPush({
      token: "token_with_unknown_400",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) {
      assertEquals(result.reason, "config_invalid");
      assertEquals(result.apnsReason, undefined);
    }
  } finally {
    restore();
  }
});

// SCA-323: APNs documents only {400, 403, 410, 429} as 4xx. Pre-fix
// any other 4xx (rare 404 / 451 from gateway maintenance) mapped to
// `config_invalid`, which pgmq-dispatch re-throws and retries through
// MAX_ATTEMPTS, then dead-letters as a permanent config bug — burning
// the retry budget on a 60s gateway blip. Treat unknown 4xx as
// retryable `server_error` so the retry loop has a chance to recover.

// SCA-352 reclassified 404 + 405 from "server_error retry" to
// "config_invalid permanent" — they're documented Apple permanent
// failures (path bug / Method Not Allowed) and burning the retry
// budget against them is wasteful. The 451 fallthrough is what
// SCA-323 was originally about — unrecognized statuses still go to
// server_error so a future Apple-side widening doesn't dead-letter.

Deno.test("sendAPNsPush: 404 → reason=config_invalid (SCA-352, was server_error in SCA-323)", async () => {
  const { restore } = installMockFetch(() =>
    new Response(null, { status: 404 })
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "config_invalid");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 405 Method Not Allowed → reason=config_invalid (SCA-352)", async () => {
  const { restore } = installMockFetch(() =>
    new Response(null, { status: 405 })
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "config_invalid");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 451 (legal/blocked, unknown) → reason=server_error (SCA-323 fallthrough)", async () => {
  const { restore } = installMockFetch(() =>
    new Response(null, { status: 451 })
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "server_error");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 401 ExpiredProviderToken → reason=config_invalid (SCA-352)", async () => {
  const { restore } = installMockFetch(() =>
    new Response(
      JSON.stringify({ reason: "ExpiredProviderToken" }),
      { status: 401, headers: { "content-type": "application/json" } },
    )
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "config_invalid");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 408 Request Timeout → reason=rate_limited (SCA-352)", async () => {
  const { restore } = installMockFetch(() =>
    new Response(null, { status: 408 })
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "rate_limited");
  } finally {
    restore();
  }
});

Deno.test("sendAPNsPush: 403 MissingProviderToken → reason=config_invalid", async () => {
  const { restore } = installMockFetch(() =>
    new Response(
      JSON.stringify({ reason: "MissingProviderToken" }),
      { status: 403, headers: { "content-type": "application/json" } },
    )
  );
  try {
    const result = await sendAPNsPush({
      token: "x",
      environment: "sandbox",
      category: "reactivation",
      alert: { title: "t", body: "b" },
    });
    assertEquals(result.ok, false);
    if (!result.ok) assertEquals(result.reason, "config_invalid");
  } finally {
    restore();
  }
});
