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

  // Step-1 additions (also added to CLAUDE.md + spec §6)
  VAL_01 = 'VAL-01',
  AUTH_01 = 'AUTH-01',
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
  // VAL-01 message is dev-oriented: iOS shows generic copy from ErrorPresenter.
  [ErrorCode.VAL_01]: 'Request body failed validation.',
  // AUTH-01 is internal; iOS re-bootstraps silently.
  [ErrorCode.AUTH_01]: 'Session expired or missing.',
};

export interface FieldError {
  field: string;
  issue: string;
}

export type AuthReason = 'missing' | 'expired' | 'malformed' | 'signature_invalid';

export interface ErrorExtras {
  message?: string;
  field_errors?: FieldError[];
  reason?: AuthReason;
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
export function jsonOk(payload: unknown, requestId?: string, status = 200): Response {
  const headers: Record<string, string> = {
    'content-type': 'application/json; charset=utf-8',
  };
  if (requestId) headers['x-request-id'] = requestId;
  return new Response(JSON.stringify(payload), { status, headers });
}
