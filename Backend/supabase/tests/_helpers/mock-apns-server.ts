// SCA-115 — mock APNs HTTP/2 server fixture for integration tests.
//
// The exported surface is `scriptableApnsFetch(...)` — a fetch-shape
// function that records every request and returns a scripted
// Response. This is the seam `_setApnsFetchOverrideForTests()`
// accepts in `_shared/apns.ts`. Every processPushSend integration
// test wants this shape: deterministic, no socket setup, no port
// selection, no cleanup. Asserts on header + URL shape happen on
// the recorded calls.
//
// SCA-315 S17: the original SCA-115 ticket also wired a
// `startMockApnsServer(...)` real-Deno-server fixture for symmetry,
// but it shipped without a caller and stayed unreferenced through
// W2/W3/W4 review cycles. Deleted as dead weight; the
// scriptable-fetch surface covers every integration test we
// actually run. If a future test genuinely needs a real socket
// (TLS handshake timing, HTTP/2 framing-level assertions), file a
// fresh SCA-* and reintroduce — the prior shape is recoverable
// from git history.
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
