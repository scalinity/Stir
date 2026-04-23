// Typed error envelope used by every /v1/... endpoint.
//
// Contract: response body is always { error: CODE, message: string, ...extras }.
// Codes match the matrix in CLAUDE.md §"Error code matrix" plus two step-1
// additions: VAL-01 (request validation) and AUTH-01 (session missing/expired).
//
// Usage:
//   return jsonError(ErrorCode.VAL_01, 400, { field_errors: [...] });
//   return jsonError(ErrorCode.AUTH_01, 401, { reason: 'expired' });

export enum ErrorCode {
  // Network / infra
  NET_01 = 'NET-01',
  AI_01 = 'AI-01',
  AI_02 = 'AI-02',
  AI_03 = 'AI-03',
  AI_VOICE_01 = 'AI-VOICE-01',

  // Imports
  IMPORT_01 = 'IMPORT-01',

  // Permissions
  PERM_CAM_01 = 'PERM-CAM-01',
  PERM_MIC_01 = 'PERM-MIC-01',
  PERM_PHOTO_01 = 'PERM-PHOTO-01',
  PERM_REM_01 = 'PERM-REM-01',

  // Sync / billing / entitlements
  SYNC_01 = 'SYNC-01',
  RATE_01 = 'RATE-01',
  BILL_01 = 'BILL-01',
  PAY_01 = 'PAY-01',
  ENT_VOICE_01 = 'ENT-VOICE-01',
  ENT_MULTI_IMAGE_01 = 'ENT-MULTI-IMAGE-01',
  ENT_LEFTOVERS_01 = 'ENT-LEFTOVERS-01',

  // Voice session lifecycle (distinct from ENT-VOICE-01 entitlement
  // failures and AI-VOICE-01 pipeline failures). Emitted by
  // voice-turn-usage when the session_id the caller posted under is
  // no longer valid for this user — either missing (expired past the
  // 2h owner-row retention), superseded by a newer mint, or owned by
  // a different user (IDOR). iOS handles by rebuilding the voice
  // driver silently; NEVER by presenting a paywall. See ADR 0017
  // and CLAUDE.md §Error code matrix for the three `reason` values.
  VOICE_SESSION_01 = 'VOICE-SESSION-01',

  // Step-1 additions (also added to CLAUDE.md + spec §6)
  VAL_01 = 'VAL-01',
  AUTH_01 = 'AUTH-01',
  // HTTP-405: wrong method on a known endpoint. Client bug only; never
  // user-visible. Distinct from VAL-01 (which is body-validation failure)
  // so dashboards can separate "iOS sent GET where POST expected" from
  // "iOS sent malformed body".
  METHOD_NOT_ALLOWED_01 = 'METHOD-NOT-ALLOWED-01',
}

// Default message map. Step 1 endpoints only use a subset; the rest are
// here so later handlers don't re-duplicate copy.
const DEFAULT_MESSAGES: Record<ErrorCode, string> = {
  [ErrorCode.NET_01]: "Couldn't reach Stir right now. Check your connection and try again.",
  [ErrorCode.AI_01]: 'Dinner planning is temporarily unavailable.',
  [ErrorCode.AI_02]: "I'm not confident about a few ingredients.",
  [ErrorCode.AI_03]: 'This is taking longer than expected.',
  [ErrorCode.AI_VOICE_01]: 'Voice mode running in reduced quality.',
  [ErrorCode.IMPORT_01]: "Couldn't turn that recipe into clean steps yet.",
  [ErrorCode.PERM_CAM_01]: 'Camera access is off.',
  [ErrorCode.PERM_MIC_01]: 'Microphone access is off.',
  [ErrorCode.PERM_PHOTO_01]: 'Photos access is off.',
  [ErrorCode.PERM_REM_01]: 'Reminders access is off.',
  [ErrorCode.SYNC_01]: "iCloud Sync isn't available.",
  [ErrorCode.RATE_01]: "You've used all of this month's available actions for your plan.",
  [ErrorCode.BILL_01]: "We couldn't confirm your subscription right now.",
  [ErrorCode.PAY_01]: "Purchase didn't go through.",
  [ErrorCode.ENT_VOICE_01]: 'Cook Mode voice is a Premium feature.',
  [ErrorCode.ENT_MULTI_IMAGE_01]: 'Multi-image scan is available on Pro. Upgrade to scan your whole kitchen at once.',
  [ErrorCode.ENT_LEFTOVERS_01]: 'Leftovers mode is a Premium feature.',
  [ErrorCode.VOICE_SESSION_01]: 'Voice session is no longer valid. Start a new session.',
  // VAL-01 message is dev-oriented: iOS shows generic copy from ErrorPresenter.
  [ErrorCode.VAL_01]: 'Request body failed validation.',
  // AUTH-01 is internal; iOS re-bootstraps silently.
  [ErrorCode.AUTH_01]: 'Session expired or missing.',
  // Client bug — iOS should never hit this path in a shipped build.
  [ErrorCode.METHOD_NOT_ALLOWED_01]: 'HTTP method not allowed on this endpoint.',
};

export interface FieldError {
  field: string;
  issue: string;
}

// AuthReason enum — iOS silent-retry path branches on this value for log
// severity and Sentry alerting. See CLAUDE.md §"AUTH-01 response shape".
//
//   missing            no Authorization header (iOS: info, silent retry)
//   expired            JWT past its `exp` (iOS: info, silent retry)
//   malformed          header present but JWT structure invalid (iOS: error)
//   signature_invalid  JWT structure OK, signature doesn't verify (iOS: error + alert)
//   user_stale         JWT valid but its canonical_user_key no longer resolves
//                      (merged forward, missing row, etc.) (iOS: info, silent retry)
export type AuthReason =
  | 'missing'
  | 'expired'
  | 'malformed'
  | 'signature_invalid'
  | 'user_stale';

/** Voice-session lifecycle reasons attached to ENT-VOICE-01 / AI-VOICE-01
 *  403 responses (P1-B / SA2-W4, 2026-04-23). Typed so the compiler
 *  guarantees the handler emits a known value and iOS can switch
 *  exhaustively on it for dashboard attribution.
 *
 *    session_missing   — /v1/ai/voice-turn-usage POST under a session_id
 *                        with no owner row (mint never happened, or row
 *                        purged by 2h retention).
 *    owner_mismatch    — session_id owned by a different canonical_user_key
 *                        than the authenticated caller (IDOR attempt).
 *    session_closed    — session_id owned by the caller but superseded by
 *                        a newer mint (closed_at IS NOT NULL on the row).
 */
export type VoiceSessionReason =
  | 'session_missing'
  | 'owner_mismatch'
  | 'session_closed';

export interface ErrorExtras {
  message?: string;
  field_errors?: FieldError[];
  reason?: AuthReason | VoiceSessionReason;
  [key: string]: unknown;
}

/** Build a typed JSON error Response with optional extras. */
export function jsonError(
  code: ErrorCode,
  status: number,
  extras: ErrorExtras = {},
  requestId?: string,
): Response {
  const { message, ...rest } = extras;
  const body: Record<string, unknown> = {
    error: code,
    message: message ?? DEFAULT_MESSAGES[code],
    ...rest,
  };
  const headers: Record<string, string> = {
    'content-type': 'application/json; charset=utf-8',
  };
  if (requestId) headers['x-request-id'] = requestId;
  return new Response(JSON.stringify(body), { status, headers });
}

/** Build a typed JSON success Response. */
export function jsonOk(
  payload: unknown,
  requestId?: string,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  const headers: Record<string, string> = {
    'content-type': 'application/json; charset=utf-8',
    ...extraHeaders,
  };
  if (requestId) headers['x-request-id'] = requestId;
  return new Response(JSON.stringify(payload), { status, headers });
}
