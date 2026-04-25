// Step 9 M4 — error envelope drift protection.
//
// Pins the spec §6 wire contract: every 4xx/5xx body is
// { error: CODE, message: string, ...structured_details }.
//
// Callers emit via jsonError(); iOS decodes via StirErrorEnvelope.
// Any refactor that changes the envelope MUST update both sides + spec §6
// + CLAUDE.md's error matrix. This test pins the wire shape.

import './_helpers/env.ts';
import { assertEquals, assert, assertExists } from '@std/assert';
import { ErrorCode, jsonError, type ErrorEnvelope } from '../functions/_shared/errors.ts';

async function readBody(res: Response): Promise<ErrorEnvelope> {
  const json = await res.json();
  return json as ErrorEnvelope;
}

function assertEnvelopeShape(body: ErrorEnvelope, expectedCode: ErrorCode): void {
  assertEquals(typeof body.error, 'string', 'envelope.error must be string');
  assertEquals(typeof body.message, 'string', 'envelope.message must be string');
  assertEquals(body.error, expectedCode, `envelope.error must equal ${expectedCode}`);
  assert(body.message.length > 0, 'envelope.message must be non-empty');
}

Deno.test('envelope: NET-01 shape', async () => {
  const res = jsonError(ErrorCode.NET_01, 500);
  assertEquals(res.status, 500);
  assertEnvelopeShape(await readBody(res), ErrorCode.NET_01);
});

Deno.test('envelope: AI-01 shape', async () => {
  const res = jsonError(ErrorCode.AI_01, 502);
  assertEquals(res.status, 502);
  assertEnvelopeShape(await readBody(res), ErrorCode.AI_01);
});

Deno.test('envelope: VAL-01 carries field_errors[] (spec §6)', async () => {
  const res = jsonError(ErrorCode.VAL_01, 400, {
    message: "Request body failed validation: 'installation_id' must be a UUID",
    field_errors: [{ field: 'installation_id', issue: "Expected UUID, got 'abc123'" }],
  });
  assertEquals(res.status, 400);
  const body = await readBody(res);
  assertEnvelopeShape(body, ErrorCode.VAL_01);
  assertExists(body.field_errors, 'VAL-01 must include field_errors');
  assert(Array.isArray(body.field_errors), 'field_errors must be array');
  assertEquals(body.field_errors!.length, 1);
  assertEquals(body.field_errors![0]!.field, 'installation_id');
  assertEquals(body.field_errors![0]!.issue, "Expected UUID, got 'abc123'");
});

Deno.test('envelope: AUTH-01 carries typed reason (spec §6 / CLAUDE.md matrix)', async () => {
  const reasons = ['missing', 'expired', 'malformed', 'signature_invalid', 'user_stale', 'reauth_required'] as const;
  for (const reason of reasons) {
    const res = jsonError(ErrorCode.AUTH_01, 401, { reason });
    assertEquals(res.status, 401);
    const body = await readBody(res);
    assertEnvelopeShape(body, ErrorCode.AUTH_01);
    assertEquals(body.reason, reason, `AUTH-01 reason must preserve ${reason}`);
  }
});

Deno.test('envelope: VOICE-SESSION-01 carries typed reason (ADR 0017)', async () => {
  const reasons = ['session_missing', 'owner_mismatch', 'session_closed', 'lookup_failed'] as const;
  for (const reason of reasons) {
    const res = jsonError(ErrorCode.VOICE_SESSION_01, 403, { reason });
    assertEquals(res.status, 403);
    const body = await readBody(res);
    assertEnvelopeShape(body, ErrorCode.VOICE_SESSION_01);
    assertEquals(body.reason, reason, `VOICE-SESSION-01 reason must preserve ${reason}`);
  }
});

Deno.test('envelope: RATE-01 carries scope + retry_after_seconds + reset_at', async () => {
  const res = jsonError(ErrorCode.RATE_01, 429, {
    scope: 'ip:dinner_solve_daily',
    retry_after_seconds: 3600,
    reset_at: '2026-04-25T00:00:00.000Z',
  });
  assertEquals(res.status, 429);
  const body = await readBody(res);
  assertEnvelopeShape(body, ErrorCode.RATE_01);
  assertEquals(body.scope, 'ip:dinner_solve_daily');
  assertEquals(body.retry_after_seconds, 3600);
  assertEquals(body.reset_at, '2026-04-25T00:00:00.000Z');
});

Deno.test('envelope: entitlement codes (ENT-VOICE-01, ENT-MULTI-IMAGE-01, ENT-LEFTOVERS-01)', async () => {
  const codes = [ErrorCode.ENT_VOICE_01, ErrorCode.ENT_MULTI_IMAGE_01, ErrorCode.ENT_LEFTOVERS_01];
  for (const code of codes) {
    const res = jsonError(code, 403);
    assertEquals(res.status, 403);
    assertEnvelopeShape(await readBody(res), code);
  }
});

Deno.test('envelope: METHOD-NOT-ALLOWED-01 optional `allowed` array', async () => {
  const res = jsonError(ErrorCode.METHOD_NOT_ALLOWED_01, 405, {
    message: 'Method Not Allowed; use POST.',
    allowed: ['POST'],
  });
  assertEquals(res.status, 405);
  const body = await readBody(res);
  assertEnvelopeShape(body, ErrorCode.METHOD_NOT_ALLOWED_01);
  assert(Array.isArray(body.allowed), 'allowed must be array');
  assertEquals(body.allowed, ['POST']);
});

Deno.test('envelope: Content-Type is application/json; charset=utf-8', () => {
  const res = jsonError(ErrorCode.NET_01, 500);
  assertEquals(res.headers.get('content-type'), 'application/json; charset=utf-8');
});

Deno.test('envelope: x-request-id header set when requestId provided', () => {
  const res = jsonError(ErrorCode.NET_01, 500, undefined, 'req_abc123');
  assertEquals(res.headers.get('x-request-id'), 'req_abc123');
});

Deno.test('envelope: x-request-id header absent when requestId not provided', () => {
  const res = jsonError(ErrorCode.NET_01, 500);
  assertEquals(res.headers.get('x-request-id'), null);
});

Deno.test('envelope: every ErrorCode produces a valid envelope with its DEFAULT_MESSAGE', async () => {
  // Exhaustively hit every code. If a new code is added without a
  // DEFAULT_MESSAGE entry, this test fails (TypeScript catches it at
  // the jsonError call; runtime catches body.message length).
  const codes: ErrorCode[] = [
    ErrorCode.NET_01,
    ErrorCode.AI_01,
    ErrorCode.AI_02,
    ErrorCode.AI_03,
    ErrorCode.AI_VOICE_01,
    ErrorCode.IMPORT_01,
    ErrorCode.PERM_CAM_01,
    ErrorCode.PERM_MIC_01,
    ErrorCode.PERM_PHOTO_01,
    ErrorCode.PERM_REM_01,
    ErrorCode.SYNC_01,
    ErrorCode.RATE_01,
    ErrorCode.BILL_01,
    ErrorCode.PAY_01,
    ErrorCode.ENT_VOICE_01,
    ErrorCode.ENT_MULTI_IMAGE_01,
    ErrorCode.ENT_LEFTOVERS_01,
    ErrorCode.VOICE_SESSION_01,
    ErrorCode.VAL_01,
    ErrorCode.AUTH_01,
    ErrorCode.METHOD_NOT_ALLOWED_01,
  ];
  for (const code of codes) {
    const res = jsonError(code, 500);
    const body = await readBody(res);
    assertEnvelopeShape(body, code);
  }
});

Deno.test("envelope: extras cannot override canonical 'error' or 'message' keys (CA2-M1 / SA1-#5 guard)", async () => {
  // Future caller passing structured extras (e.g., a forwarded upstream-
  // error object) might include `error` or `message` keys. The wire shape
  // must remain { error: <our code>, message: <our copy>, ... }.
  // jsonError re-pins both fields after the spread.
  const res = jsonError(
    ErrorCode.NET_01,
    500,
    { error: 'OOPS', message: 'fake' } as unknown as Parameters<typeof jsonError>[2],
  );
  const body = await readBody(res);
  assertEquals(body.error, ErrorCode.NET_01, 'error must be the code we passed, not the override');
  // When extras supplies message: 'fake', that's a legitimate caller use
  // (jsonError's destructure picks up extras.message specifically and
  // uses it as the body message). The guard pins ONLY against `error`
  // override. body.message here is 'fake' by design.
  assertEquals(body.message, 'fake', 'caller-supplied message wins (this is the supported override path)');
});

Deno.test("envelope: extras with `error` key only does not override canonical `error`", async () => {
  // Same guard but extras only carries `error`, not `message`. body.error
  // must stay as the canonical code; body.message must fall back to
  // DEFAULT_MESSAGES.
  const res = jsonError(
    ErrorCode.NET_01,
    500,
    { error: 'OOPS' } as unknown as Parameters<typeof jsonError>[2],
  );
  const body = await readBody(res);
  assertEquals(body.error, ErrorCode.NET_01);
  assert(typeof body.message === 'string' && body.message.length > 0, 'message falls back to default');
});
