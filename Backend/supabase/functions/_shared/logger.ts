// Structured JSON logger for Edge Functions.
//
// Output: one JSON object per line to stdout. Captured by Supabase's
// function log pipeline. Never emit the raw canonical_user_key or JWT —
// use hashCanonicalKey() before attaching. User free-text is allowed
// only when the user has opted into diagnostics (not applicable in step 1).
//
// Usage:
//   const log = await createLogger(requestId, '/v1/session/bootstrap', canonicalKey?);
//   log.info('bootstrap_start', { is_new_user: true });
//   log.warn('validation_failed', { field_errors });
//   log.error('alias_merge_failed', err, { retry_count: 2 });

import { hashCanonicalKey } from './hashing.ts';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface Logger {
  debug(msg: string, meta?: Record<string, unknown>): void;
  info(msg: string, meta?: Record<string, unknown>): void;
  warn(msg: string, meta?: Record<string, unknown>): void;
  error(msg: string, err?: unknown, meta?: Record<string, unknown>): void;
}

interface LogEntry {
  ts: string;
  level: LogLevel;
  endpoint: string;
  request_id: string;
  msg: string;
  canonical_key_hash?: string;
  err?: { name: string; message: string; stack?: string };
  [key: string]: unknown;
}

export async function createLogger(
  requestId: string,
  endpoint: string,
  canonicalUserKey?: string,
): Promise<Logger> {
  const keyHash = canonicalUserKey ? await hashCanonicalKey(canonicalUserKey) : undefined;

  function emit(level: LogLevel, msg: string, meta?: Record<string, unknown>, err?: unknown): void {
    const entry: LogEntry = {
      ts: new Date().toISOString(),
      level,
      endpoint,
      request_id: requestId,
      msg,
    };
    if (keyHash) entry.canonical_key_hash = keyHash;
    if (meta) Object.assign(entry, meta);
    if (err !== undefined) {
      // Bounded error serialization — third-party APIs (notably
      // Gemini) can echo ~100 chars of the user's request back in
      // `.message`, so an unbounded pass-through accumulates PII
      // (scan OCR output, recipe titles, dietary rules) into log
      // retention. Truncate at 200 chars; stack is already bounded
      // by the framework. CR3-C2 (2026-04-24).
      entry.err = sanitizeErrorForLog(err);
    }
    const line = JSON.stringify(entry);
    if (level === 'error') console.error(line);
    else if (level === 'warn') console.warn(line);
    else console.log(line);
  }

  return {
    debug: (msg, meta) => emit('debug', msg, meta),
    info: (msg, meta) => emit('info', msg, meta),
    warn: (msg, meta) => emit('warn', msg, meta),
    error: (msg, err, meta) => emit('error', msg, meta, err),
  };
}

/** Generate or honor an incoming x-request-id header. */
export function requestIdFrom(req: Request): string {
  const incoming = req.headers.get('x-request-id');
  if (incoming && /^[A-Za-z0-9_\-:.]{1,128}$/.test(incoming)) return incoming;
  return crypto.randomUUID();
}

/// Convert an unknown thrown value into a bounded, log-safe shape.
/// Use this at any site that wants `err: ...` in a meta dict instead of
/// the `err` parameter to `log.error(...)` — unbounded `String(err)`
/// can leak user content that third-party APIs echoed back inside
/// `.message`. 200-char truncation matches the inline bound used by
/// the structured logger emit path. CR3-C2 (2026-04-24).
export interface SanitizedError {
  name: string;
  message: string;
  kind: 'error' | 'non_error';
}
export function sanitizeErrorForLog(err: unknown): SanitizedError {
  if (err instanceof Error) {
    return {
      name: err.name,
      message: err.message.slice(0, 200),
      kind: 'error',
    };
  }
  // Non-Error thrown value. Record the shape ("non_error") without
  // recursing into arbitrary structure — a Zod issue or SDK error
  // object stringified raw can carry Zod's `received` echo.
  return { name: 'NonError', message: typeof err, kind: 'non_error' };
}
