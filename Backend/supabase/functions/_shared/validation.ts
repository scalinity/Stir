// Zod schemas for Edge Function request bodies.
//
// Every handler parses the request body through the relevant schema before
// touching the database. Failures surface as VAL-01 with structured
// field_errors for Sentry debugging on the iOS side.

import { z, ZodError } from 'zod';
import type { FieldError } from './errors.ts';

// ---------------------------------------------------------------------------
// /v1/session/bootstrap
// ---------------------------------------------------------------------------
//
// installation_id: UUID v4 generated in iOS keychain. Required.
// cloudkit_user_record_name: Opaque CloudKit userRecordName (e.g. `_abc...`).
//   Optional — absent on local-only users.
// build: iOS build string, e.g. "1.0.0 (42)". Required for telemetry.
// os_version: iOS version string, e.g. "17.5.1". Required for telemetry.

export const SessionBootstrapRequest = z.object({
  installation_id: z.string().uuid(),
  cloudkit_user_record_name: z.string().min(1).max(256).optional(),
  build: z.string().min(1).max(64),
  os_version: z.string().min(1).max(64),
}).strict();

export type SessionBootstrapRequest = z.infer<typeof SessionBootstrapRequest>;

// ---------------------------------------------------------------------------
// /v1/config/bootstrap (no body; GET with JWT)
// ---------------------------------------------------------------------------
// Placeholder: future GETs may accept query params (e.g. ?include=prompts,flags)
// to trim the payload. Step 1 returns everything unconditionally.

// ---------------------------------------------------------------------------
// Zod → FieldError[] helper
// ---------------------------------------------------------------------------

/** Convert a ZodError into the structured field_errors wire format. */
export function zodToFieldErrors(err: ZodError): FieldError[] {
  return err.issues.map((issue) => ({
    field: issue.path.length > 0 ? issue.path.map(String).join('.') : '<root>',
    issue: issue.message,
  }));
}
