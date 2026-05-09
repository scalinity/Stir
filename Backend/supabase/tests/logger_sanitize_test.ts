// SCA-273 (S7 from /review-5) — unit tests for sanitizeErrorForLog's
// new defense-in-depth redaction of CloudKit query-string credentials.
//
// Threat model: today no callsite logs the upstream-fetch URL or
// echoes it through err.message, but on some Deno runtimes a
// `TypeError` produced by a failed fetch embeds the request URL in
// `.message`. The `verifyCloudKitIdentity` flow constructs a URL with
// `ckAPIToken=` and `ckWebAuthToken=` query params (Apple's CloudKit
// Web Services API has no header alternative). Belt-and-suspenders:
// strip those values from any string we sanitize, so a future log
// line that picks them up via err.message is automatically safe.

import { assertEquals } from '@std/assert';
import { sanitizeErrorForLog } from '../functions/_shared/logger.ts';

Deno.test('sanitizeErrorForLog: redacts ckAPIToken value from err.message', () => {
  const err = new Error(
    'TypeError: failed fetch https://api.apple-cloudkit.com/database/1/X/production/public/users/caller?ckAPIToken=AAAA-BBBB-CCCC&ckWebAuthToken=tok-XYZ',
  );
  const sanitized = sanitizeErrorForLog(err);
  if (sanitized.message.includes('AAAA-BBBB-CCCC')) {
    throw new Error(`ckAPIToken value leaked: ${sanitized.message}`);
  }
  if (sanitized.message.includes('tok-XYZ')) {
    throw new Error(`ckWebAuthToken value leaked: ${sanitized.message}`);
  }
  // The KEYS should remain (so the redacted positions are still
  // visible to a debugging operator); only the VALUES are scrubbed.
  if (!sanitized.message.includes('ckAPIToken=<REDACTED>')) {
    throw new Error(`ckAPIToken redaction not applied: ${sanitized.message}`);
  }
  if (!sanitized.message.includes('ckWebAuthToken=<REDACTED>')) {
    throw new Error(`ckWebAuthToken redaction not applied: ${sanitized.message}`);
  }
});

Deno.test('sanitizeErrorForLog: redaction is case-insensitive', () => {
  const err = new Error('CKAPItoken=secret123&ckwebauthtoken=tok2');
  const sanitized = sanitizeErrorForLog(err);
  if (sanitized.message.includes('secret123') || sanitized.message.includes('tok2')) {
    throw new Error(`case-variant token leaked: ${sanitized.message}`);
  }
});

Deno.test('sanitizeErrorForLog: leaves non-credential URLs alone', () => {
  const err = new Error('failed fetch https://example.com/api?foo=bar&baz=qux');
  const sanitized = sanitizeErrorForLog(err);
  // Non-credential keys should remain intact.
  assertEquals(sanitized.message.includes('foo=bar'), true);
  assertEquals(sanitized.message.includes('baz=qux'), true);
});

Deno.test('sanitizeErrorForLog: still truncates to 200 chars after redaction', () => {
  const longSuffix = 'X'.repeat(500);
  const err = new Error('ckAPIToken=secret&' + longSuffix);
  const sanitized = sanitizeErrorForLog(err);
  if (sanitized.message.length > 200) {
    throw new Error(`message exceeded 200-char cap: length=${sanitized.message.length}`);
  }
});
