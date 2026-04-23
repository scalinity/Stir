// ErrorCode
//
// Mirror of the backend/spec error-code matrix (CLAUDE.md §"Error code matrix"
// and spec §6). Every backend response with a 4xx/5xx status carries
// `{ error: "<code>", message, ...structured_details }`. iOS decodes the code
// here and routes to `ErrorPresenter` for user-facing copy.
//
// Codes are frozen — adding one requires updating BOTH CLAUDE.md and spec §6.
// Never invent a new code in iOS code only.

import Foundation

enum ErrorCode: String, Sendable, Codable, CaseIterable {
    case net01 = "NET-01"          // network unreachable (or 500-class server)
    case ai01 = "AI-01"            // AI temporarily unavailable
    case ai02 = "AI-02"            // low confidence / needs review
    case ai03 = "AI-03"            // taking longer than expected
    case aiVoice01 = "AI-VOICE-01" // Live API down; text fallback active
    case import01 = "IMPORT-01"    // recipe import parse failed
    case permCam01 = "PERM-CAM-01"
    case permMic01 = "PERM-MIC-01"
    case permPhoto01 = "PERM-PHOTO-01"
    case permRem01 = "PERM-REM-01"
    case sync01 = "SYNC-01"        // iCloud unavailable
    case rate01 = "RATE-01"        // monthly quota exhausted
    case bill01 = "BILL-01"        // entitlement uncertain
    case pay01 = "PAY-01"          // purchase failed
    case entVoice01 = "ENT-VOICE-01" // voice requires Premium+
    case entMultiImage01 = "ENT-MULTI-IMAGE-01" // multi-image scan is Pro-only
    case entLeftovers01 = "ENT-LEFTOVERS-01" // leftovers mode requires Premium+
    case val01 = "VAL-01"          // request body validation failure
    case auth01 = "AUTH-01"        // session missing/expired/malformed/sig-invalid
    case methodNotAllowed01 = "METHOD-NOT-ALLOWED-01"  // 405 — client bug, never user-visible
}

/// Backend field-error shape for VAL-01.
struct FieldError: Sendable, Equatable, Codable {
    let field: String
    let issue: String
}

/// AUTH-01 reason enum (401 response carries this). See CLAUDE.md
/// §"AUTH-01 response shape" for severity + handling per reason.
///
///   missing           — no Authorization header (info, silent retry)
///   expired           — JWT past `exp` (info, silent retry)
///   malformed         — JWT structure invalid (error + silent retry)
///   signatureInvalid  — signature didn't verify (error + alert)
///   userStale         — JWT valid but canonical_user_key no longer resolves
///                       (merged forward, row missing). Info severity, silent retry.
enum AuthReason: String, Sendable, Equatable, Codable {
    case missing
    case expired
    case malformed
    case signatureInvalid = "signature_invalid"
    case userStale = "user_stale"
}
