// SCA-380: pure Zod unit tests for SessionBootstrapRequest defensive
// refinements. Lives separately from session_bootstrap_test.ts (which
// is integration: real HTTP, real Postgres) so the CRLF / NUL pins
// run as a fast file-level invariant — no edge-runtime restart needed
// when the schema changes.
//
// What's covered:
//   * `build` rejects CR/LF/NUL/other control characters (CRLF spoof
//     of structured log lines).
//   * `os_version` rejects the same.
//   * Healthy `build` + `os_version` still parse — the refine is
//     targeted, not blanket-deny on punctuation.
//   * Pre-SCA-380 wire shape (no extras, no missing fields) still
//     parses — `.strict()` posture preserved.

import { assertEquals } from '@std/assert';
import { SessionBootstrapRequest } from '../functions/_shared/validation.ts';

const baseValidBody = {
  installation_id: 'a'.padEnd(8, '0') + '-' + '1'.padEnd(4, '0') + '-' +
    '4' + '0'.repeat(3) + '-' + '8' + '0'.repeat(3) + '-' + '0'.repeat(12),
  build: '1.2.3 (456)',
  os_version: '17.5.1',
};

Deno.test('SessionBootstrapRequest: clean baseline parses (refine is targeted, not blanket)', () => {
  const result = SessionBootstrapRequest.safeParse(baseValidBody);
  assertEquals(result.success, true);
});

Deno.test('SessionBootstrapRequest: rejects CRLF in build', () => {
  const result = SessionBootstrapRequest.safeParse({
    ...baseValidBody,
    build: '1.0.0\r\nfake_log_line spoofed=true',
  });
  assertEquals(result.success, false);
});

Deno.test('SessionBootstrapRequest: rejects NUL in os_version', () => {
  const result = SessionBootstrapRequest.safeParse({
    ...baseValidBody,
    os_version: '17.5' + String.fromCharCode(0) + 'injected',
  });
  assertEquals(result.success, false);
});

Deno.test('SessionBootstrapRequest: rejects bare LF in build', () => {
  const result = SessionBootstrapRequest.safeParse({
    ...baseValidBody,
    build: '1.0.0\ninjected',
  });
  assertEquals(result.success, false);
});

Deno.test('SessionBootstrapRequest: rejects tab in os_version', () => {
  const result = SessionBootstrapRequest.safeParse({
    ...baseValidBody,
    os_version: '17.5\tinjected',
  });
  assertEquals(result.success, false);
});

Deno.test('SessionBootstrapRequest: rejects DEL (0x7f) in build', () => {
  const result = SessionBootstrapRequest.safeParse({
    ...baseValidBody,
    build: '1.0.0' + String.fromCharCode(0x7f),
  });
  assertEquals(result.success, false);
});

Deno.test('SessionBootstrapRequest: still rejects unknown extra keys (.strict() preserved)', () => {
  const result = SessionBootstrapRequest.safeParse({
    ...baseValidBody,
    rogue_field: 'should-trip-strict',
  });
  assertEquals(result.success, false);
});
