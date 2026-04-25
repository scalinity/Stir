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
    // Voice session lifecycle failure — session_id no longer valid for this
    // user. Distinct from ENT-VOICE-01 (entitlement) and AI-VOICE-01 (AI
    // pipeline). Handler rebuilds the voice driver silently; MUST NOT
    // paywall. `reason` field discriminates four subcases:
    //   session_missing  — row absent (expired past 2h owner retention)
    //   session_closed   — row present, superseded by a newer mint
    //   owner_mismatch   — row present but owned by a different user (IDOR
    //                      attempt or VM bug; log + rebuild generically)
    //   lookup_failed    — DB error during owner-row lookup (HTTP 500;
    //                      neither Gemini-related nor user-retryable;
    //                      log + rebuild generically)
    // See ADR 0017, CLAUDE.md §Error code matrix.
    case voiceSession01 = "VOICE-SESSION-01"
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
///   reauthRequired    — JWT issued before app_users.reauth_required_at; admin
///                       used users.force_reauth to boot this session. Maps to
///                       SIWA re-flow (NOT silent retry) — rotate Keychain
///                       install_id, clear canonical_user_key, nav to SIWA.
///                       See ADR 0023.
enum AuthReason: String, Sendable, Equatable, Codable {
    case missing
    case expired
    case malformed
    case signatureInvalid = "signature_invalid"
    case userStale = "user_stale"
    case reauthRequired = "reauth_required"
}

/// VOICE-SESSION-01 reason enum. Backend emits one of these on the 403
/// (or 500 for lookupFailed) response; iOS uses them for Sentry breadcrumb
/// attribution and ops dashboard filtering. All four reasons share the
/// same handler path (rebuild voice driver) — the distinction is
/// observability, not control flow. See CLAUDE.md §Error code matrix +
/// ADR 0017.
///
///   sessionMissing  — owner row absent (expired past 2h retention, or
///                     client held a stale session_id from before the
///                     owner table landed). HTTP 403.
///   sessionClosed   — owner row present but superseded by a newer mint
///                     for this user (common: refresh swap raced with
///                     an in-flight turn POST). HTTP 403.
///   ownerMismatch   — owner row present but owned by a different
///                     canonical_user_key (IDOR attempt or VM bug —
///                     alert ops if rate climbs). HTTP 403.
///   lookupFailed    — DB error during voice_session_owners SELECT (e.g.,
///                     transient connectivity, replica lag). HTTP 500.
///                     Neither Gemini-related nor user-retryable — same
///                     silent-rebuild path as the 403 reasons; the
///                     distinction is server-side observability.
enum VoiceSessionReason: String, Sendable, Equatable, Codable {
    case sessionMissing = "session_missing"
    case sessionClosed = "session_closed"
    case ownerMismatch = "owner_mismatch"
    case lookupFailed = "lookup_failed"
}
