// PostHog raw-HTTP capture for Edge Functions.
//
// Deno-native, no SDK. Posts to /i/v0/e/ with a single event per call.
// Fire-and-forget via EdgeRuntime.waitUntil so the caller's HTTP response
// isn't gated on the capture. Observability is best-effort — a failed
// capture logs a warning and never throws, never retries, never blocks.
//
// Env vars (set via `supabase secrets set`):
//   POSTHOG_PUBLIC_API_KEY  public project key (same key iOS uses; safe
//                           in Edge Function env, same trust tier as
//                           SUPABASE_ANON_KEY which is also public)
//   POSTHOG_HOST            ingest host, e.g. https://us.i.posthog.com
//                           defaults to US cloud if unset
//
// Privacy posture: callers never pass user content. `properties` must
// contain only tokens / costs / latencies / model metadata. The `$ai_input`
// and `$ai_output_choices` blob fields from PostHog's LLM spec are
// deliberately not surfaced here — Stir's rule is no-content-capture.

import type { Logger } from './logger.ts';

const POSTHOG_API_KEY = Deno.env.get('POSTHOG_PUBLIC_API_KEY');
const POSTHOG_HOST = Deno.env.get('POSTHOG_HOST') ?? 'https://us.i.posthog.com';

if (!POSTHOG_API_KEY) {
  console.warn(
    JSON.stringify({
      level: 'warn',
      msg: 'posthog_env_missing',
      detail:
        'POSTHOG_PUBLIC_API_KEY missing; $ai_generation/$ai_trace captures will no-op.',
    }),
  );
}

// One-time boot-side confirmation of which PostHog project this Edge
// Function writes to. Prints the 8-char key prefix (phc_XXXXXX…) so ops
// can cross-check against iOS's Config.xcconfig without leaking the full
// key. If backend + iOS ever diverge on the key, events split silently
// across projects; this log is the ground-truth sanity check.
//
// Multi-worker behavior: `posthogInitLogged` is module-scoped per-worker.
// Supabase Edge Runtime spins up multiple isolated workers per function,
// so this log fires ONCE per worker process — expect a handful of
// identical emissions after a cold start. That's desirable: multiple
// workers confirming the same config is stronger evidence than a single
// log, and total volume is tiny.
let posthogInitLogged = false;
function logPosthogInitOnce(log: Logger): void {
  if (posthogInitLogged || !POSTHOG_API_KEY) return;
  posthogInitLogged = true;
  log.info('posthog_init', {
    host: POSTHOG_HOST,
    key_prefix: POSTHOG_API_KEY.slice(0, 8),
  });
}

// ---------------------------------------------------------------------------
// Low-level capture
// ---------------------------------------------------------------------------

export interface PosthogEventBody {
  /** PostHog event name. For LLM Observability: "$ai_generation" | "$ai_trace". */
  event: string;
  /** User identifier. Stir: canonical_user_key_hash (16-char SHA-256). */
  distinctId: string;
  /** Event properties. $-prefixed keys are PostHog-reserved. */
  properties: Record<string, unknown>;
  /** ISO-8601 UTC; defaults to now. */
  timestamp?: string;
}

/**
 * Fire a single PostHog event. Non-blocking: kicks a Promise onto
 * `EdgeRuntime.waitUntil` and returns immediately. Errors are logged
 * but never thrown.
 *
 * If POSTHOG_PUBLIC_API_KEY is missing, the call no-ops silently — the
 * env-missing warning at module load tells ops to fix config; re-warning
 * on every capture would drown the log stream.
 */
export function capturePosthogEvent(
  log: Logger,
  body: PosthogEventBody,
): void {
  if (!POSTHOG_API_KEY) return;

  logPosthogInitOnce(log);

  const payload = {
    api_key: POSTHOG_API_KEY,
    event: body.event,
    distinct_id: body.distinctId,
    properties: body.properties,
    timestamp: body.timestamp ?? new Date().toISOString(),
  };

  const task = (async () => {
    try {
      const res = await fetch(`${POSTHOG_HOST}/i/v0/e/`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(payload),
      });
      // PostHog's capture endpoint returns 200 on accepted; anything else
      // is a warning-level ops signal, not an error (user's request has
      // already succeeded by now).
      if (!res.ok) {
        const text = await res.text().catch(() => '<no body>');
        log.warn('posthog_capture_non_2xx', {
          status: res.status,
          event: body.event,
          body_preview: text.slice(0, 200),
        });
      }
    } catch (err) {
      // Network errors, DNS, TLS. Swallow — `log.warn` emits structured
      // JSON via the standard logger; ops can alert on posthog_capture_threw.
      log.warn('posthog_capture_threw', {
        event: body.event,
        err: err instanceof Error ? err.message : String(err),
      });
    }
  })();

  const runtime = (globalThis as { EdgeRuntime?: { waitUntil: (p: Promise<unknown>) => void } })
    .EdgeRuntime;
  if (runtime?.waitUntil) {
    runtime.waitUntil(task);
  }
  // Else: task is running on the event loop; we intentionally do NOT await.
}
