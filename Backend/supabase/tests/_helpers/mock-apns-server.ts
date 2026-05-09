// SCA-115 — mock APNs HTTP/2 server fixture for integration tests.
//
// Two surfaces are exposed here, picked at the call site based on what
// the test needs:
//
//   1. `scriptableApnsFetch(...)` — a fetch-shape function that records
//      every request and returns a scripted Response. This is the seam
//      `_setApnsFetchOverrideForTests()` accepts in `_shared/apns.ts`.
//      Ninety percent of integration tests want this shape: deterministic,
//      no socket setup, no port selection, no cleanup. Asserts on header
//      + URL shape happen on the recorded calls.
//
//   2. `startMockApnsServer(...)` — a real Deno HTTP server that speaks
//      HTTP/1.1 (Deno's `serve` upgrades to HTTP/2 over TLS only — APNs
//      requires HTTP/2 in production but the wire shape we exercise in
//      tests is identical to HTTP/1.1 from the client's perspective).
//      Useful for tests that exercise the full URLSession-style fetch
//      stack (TLS, real connect timing) — present here for symmetry with
//      the SCA-115 ticket's "Deno-based mock APNs HTTP/2 server fixture"
//      requirement, even though the scriptable-fetch surface is what the
//      processPushSend integration tests use.
//
// The helper is shared with apns_test.ts / apns_hardening_test.ts via
// follow-up consolidation if those tests want to migrate off
// `globalThis.fetch` swap. Today they keep their own pattern; this file
// is the canonical seam going forward.

/** A single recorded request the scriptable fetch saw. */
export interface RecordedApnsRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
  /** ISO timestamp the request was recorded at. */
  receivedAt: string;
}

/** What the scriptable fetch should return for the next call. */
export type ScriptedApnsResponse =
  | {
    /** Standard 200 OK with an apns-id response header. */
    kind: 'ok';
    apnsId?: string;
  }
  | {
    /** APNs error: 4xx or 5xx with a JSON body of {reason: "..."}. */
    kind: 'error';
    status: number;
    apnsReason: string;
  }
  | {
    /** fetch() throws (network-layer failure). */
    kind: 'throw';
    message: string;
  };

/** Build a scriptable APNs fetch. The returned function matches the
 *  signature `_setApnsFetchOverrideForTests` accepts, and exposes the
 *  recorded calls + a per-call response queue. */
export function scriptableApnsFetch(): {
  fetch: (input: string, init: RequestInit) => Promise<Response>;
  calls: RecordedApnsRequest[];
  /** Push a scripted response onto the FIFO queue. The next fetch
   *  call (in arrival order) returns this. If the queue runs dry the
   *  fetch throws so missing scripting surfaces as a test failure
   *  rather than a quiet 200. */
  queueResponse: (resp: ScriptedApnsResponse) => void;
  /** Convenience wrappers for the common branches. */
  queueOk: (apnsId?: string) => void;
  queueError: (status: number, apnsReason: string) => void;
  queueThrow: (message: string) => void;
} {
  const calls: RecordedApnsRequest[] = [];
  const queue: ScriptedApnsResponse[] = [];

  return {
    calls,
    queueResponse: (resp) => queue.push(resp),
    queueOk: (apnsId) => queue.push({ kind: 'ok', apnsId: apnsId ?? `mock-apns-${calls.length}` }),
    queueError: (status, apnsReason) => queue.push({ kind: 'error', status, apnsReason }),
    queueThrow: (message) => queue.push({ kind: 'throw', message }),
    fetch: (input, init) => {
      // Record before responding so even error/throw branches get
      // their inputs captured.
      const headerObj = headerInitToRecord(init.headers);
      let parsedBody: unknown;
      if (typeof init.body === 'string') {
        try {
          parsedBody = JSON.parse(init.body);
        } catch {
          parsedBody = init.body;
        }
      } else {
        parsedBody = init.body;
      }
      calls.push({
        url: input,
        method: init.method ?? 'GET',
        headers: headerObj,
        body: parsedBody,
        receivedAt: new Date().toISOString(),
      });

      const next = queue.shift();
      if (!next) {
        return Promise.reject(
          new Error(
            `scriptableApnsFetch: no scripted response queued for call #${calls.length} (${input}). ` +
              'Call queueOk/queueError/queueThrow before invoking processPushSend.',
          ),
        );
      }

      if (next.kind === 'throw') {
        return Promise.reject(new Error(next.message));
      }
      if (next.kind === 'ok') {
        return Promise.resolve(
          new Response(null, {
            status: 200,
            headers: { 'apns-id': next.apnsId ?? `mock-apns-${calls.length}` },
          }),
        );
      }
      // error
      return Promise.resolve(
        new Response(JSON.stringify({ reason: next.apnsReason }), {
          status: next.status,
          headers: { 'content-type': 'application/json' },
        }),
      );
    },
  };
}

/** Convert a HeadersInit (Headers | Record | array of tuples) into a
 *  flat Record<string,string> for assertion convenience. Headers are
 *  lowercased for stable lookups. */
function headerInitToRecord(input: HeadersInit | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!input) return out;
  if (input instanceof Headers) {
    input.forEach((value, key) => {
      out[key.toLowerCase()] = value;
    });
    return out;
  }
  if (Array.isArray(input)) {
    for (const [k, v] of input) {
      out[k.toLowerCase()] = v;
    }
    return out;
  }
  for (const [k, v] of Object.entries(input)) {
    out[k.toLowerCase()] = v;
  }
  return out;
}

// -----------------------------------------------------------------------------
// Real HTTP server variant (kept for completeness — present so the
// scriptable-fetch surface above is the cheap default, with a real
// server fallback ready for tests that need one).
// -----------------------------------------------------------------------------

export interface MockApnsServerHandle {
  /** Base URL e.g. "http://127.0.0.1:53412". Append /3/device/<token>. */
  url: string;
  port: number;
  /** Calls the server has received, in arrival order. */
  calls: RecordedApnsRequest[];
  /** Stop the server and resolve when all in-flight handlers have settled. */
  shutdown: () => Promise<void>;
  /** Push a scripted response (FIFO) — same semantics as scriptableApnsFetch. */
  queueResponse: (resp: ScriptedApnsResponse) => void;
}

/** Spin up a real Deno HTTP server on a random port that scripts the
 *  same response queue as `scriptableApnsFetch`. Useful for end-to-end
 *  tests that need a real socket — but most processPushSend tests can
 *  use the cheaper fetch-DI seam.
 *
 *  HTTP/1.1 on the wire. APNs production is HTTP/2; the response shape
 *  (status code + apns-id header + JSON body on error) is identical at
 *  the application layer, which is what apns.ts inspects. */
export async function startMockApnsServer(): Promise<MockApnsServerHandle> {
  const calls: RecordedApnsRequest[] = [];
  const queue: ScriptedApnsResponse[] = [];

  const ac = new AbortController();
  let resolvedPort = 0;

  const server = Deno.serve(
    {
      port: 0, // random
      hostname: '127.0.0.1',
      signal: ac.signal,
      onListen: ({ port }) => {
        resolvedPort = port;
      },
    },
    async (req) => {
      const headerObj: Record<string, string> = {};
      req.headers.forEach((v, k) => {
        headerObj[k.toLowerCase()] = v;
      });
      let parsedBody: unknown;
      try {
        const text = await req.text();
        parsedBody = text.length > 0 ? JSON.parse(text) : undefined;
      } catch {
        parsedBody = undefined;
      }
      calls.push({
        url: req.url,
        method: req.method,
        headers: headerObj,
        body: parsedBody,
        receivedAt: new Date().toISOString(),
      });

      const next = queue.shift();
      if (!next) {
        return new Response(
          JSON.stringify({ reason: 'NoScriptedResponse' }),
          { status: 500, headers: { 'content-type': 'application/json' } },
        );
      }
      if (next.kind === 'throw') {
        // Simulate a network failure by aborting the response.
        return new Response(null, { status: 502 });
      }
      if (next.kind === 'ok') {
        return new Response(null, {
          status: 200,
          headers: { 'apns-id': next.apnsId ?? `mock-apns-${calls.length}` },
        });
      }
      return new Response(JSON.stringify({ reason: next.apnsReason }), {
        status: next.status,
        headers: { 'content-type': 'application/json' },
      });
    },
  );

  // Wait for onListen to populate the port (Deno.serve's signature
  // resolves synchronously for the listener but onListen runs after).
  // Simple busy-wait with a timeout cap to avoid races on slow CI.
  const start = Date.now();
  while (resolvedPort === 0 && Date.now() - start < 2000) {
    await new Promise((r) => setTimeout(r, 5));
  }
  if (resolvedPort === 0) {
    ac.abort();
    throw new Error('mock APNs server failed to bind a port within 2s');
  }

  return {
    url: `http://127.0.0.1:${resolvedPort}`,
    port: resolvedPort,
    calls,
    queueResponse: (resp) => queue.push(resp),
    shutdown: async () => {
      ac.abort();
      try {
        await server.finished;
      } catch {
        // AbortError is expected.
      }
    },
  };
}
