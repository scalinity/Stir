// Shared wire-format regexes used across Edge Functions.
//
// Hosted in a leaf module (no other `_shared/*` imports) so peers like
// `auth.ts` and `validation.ts` can both consume without creating a
// directional edge between them. SCA-407 promoted these out of
// `validation.ts` to remove that peer-to-peer coupling.

// SCA-380: UUID v4 (RFC 4122) — version nibble == 4, variant nibbles
// ∈ {8,9,a,b}. Both upper- and lower-case hex accepted so iOS's
// `UUID().uuidString` (uppercase) and JS/CLI-generated UUIDs
// (lowercase) both pass. Rejects v1/v5/v7 shapes that happen to
// pass Zod's permissive `.uuid()` check.
export const UUID_V4_REGEX =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$/;

// SCA-380: control-character filter for free-form telemetry strings.
// Rejects all C0 + DEL + C1 controls (CR, LF, tab, NUL, escape, etc).
// Used by `validation.ts` to wrap untrusted-string fields (`build`,
// `os_version`, `cloudkit_web_auth_token`, image base64) so a
// malicious client can't inject CRLF (`"1.0.0\r\nfake_log_line
// spoofed=true"`) into a downstream structured-log parser.
export const CONTROL_CHAR_REGEX = /[\x00-\x1f\x7f-\x9f]/;
