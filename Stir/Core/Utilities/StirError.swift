// StirError
//
// App-wide typed error. All thrown errors from Stir services should surface
// as a `StirError` case so the presenter layer can map deterministically to
// user copy via `ErrorPresenter`.
//
// Categorization mirrors the backend `ErrorCode` enum but adds client-only
// cases (configuration, Core Data, CloudKit availability).

import Foundation

enum StirError: Error, Sendable {
    // -- Network / HTTP --------------------------------------------------
    /// 5xx from backend after retry exhaustion, or URL-level network failure.
    case networkUnreachable(underlying: (any Error)?)

    /// App-layer timeout wrapping a hung request. URLSession's default
    /// `timeoutIntervalForResource` is effectively infinite (7 days), so a
    /// partial-response hang at the TCP level would park an async call
    /// indefinitely without this. Thrown by `withTimeout(seconds:)`.
    case timeout(operation: String, seconds: Double)

    /// Structured 4xx/5xx server error with its typed code.
    case server(code: ErrorCode, message: String, fieldErrors: [FieldError])

    /// Server returned success status but body was malformed or unparseable.
    case malformedResponse(description: String)

    // -- Auth ------------------------------------------------------------
    /// AUTH-01 with typed reason. iOS re-bootstrap path reads `.reason`.
    case auth(reason: AuthReason, message: String)

    // -- Validation ------------------------------------------------------
    /// VAL-01 — client-send-wrong-body. Never retried.
    case validation(fieldErrors: [FieldError], message: String)

    // -- Entitlement / Quota --------------------------------------------
    /// ENT-VOICE-01 or BILL-01 — user lacks entitlement.
    case entitlementRequired(code: ErrorCode, message: String)

    /// RATE-01 — monthly quota exhausted.
    case rateLimited(resetDate: Date?, message: String)

    /// VOICE-SESSION-01 — voice session lifecycle failure (session_id
    /// missing / superseded / owned-by-other). Distinct from
    /// `entitlementRequired(.entVoice01)` which is a Premium upsell
    /// path; this case MUST rebuild the voice driver without a paywall.
    /// `reason` is optional so a future backend response missing the
    /// field doesn't crash the decode — iOS defaults to the generic
    /// rebuild path.
    case voiceSessionInvalid(reason: VoiceSessionReason?, message: String)

    // -- Configuration ---------------------------------------------------
    case configuration(AppConfigError)

    // -- Persistence -----------------------------------------------------
    case coreData(underlying: (any Error))
    case cloudKit(underlying: (any Error))

    // -- Catch-all -------------------------------------------------------
    case unknown(underlying: (any Error))
}

extension StirError {
    /// The `ErrorCode` that best represents this error for presentation.
    var presentableCode: ErrorCode {
        switch self {
        case .networkUnreachable:          return .net01
        case .timeout:                     return .net01
        case .server(let code, _, _):      return code
        case .malformedResponse:           return .net01
        case .auth:                        return .auth01
        case .validation:                  return .val01
        case .entitlementRequired(let c, _): return c
        case .rateLimited:                 return .rate01
        case .voiceSessionInvalid:         return .voiceSession01
        case .configuration:               return .net01
        case .coreData, .cloudKit:         return .sync01
        case .unknown:                     return .net01
        }
    }
}

extension StirError: CustomStringConvertible {
    var description: String {
        switch self {
        case .networkUnreachable(let underlying):
            return "network unreachable — \(underlying?.localizedDescription ?? "no underlying error")"
        case .timeout(let operation, let seconds):
            return "timeout — \(operation) exceeded \(seconds)s"
        case .server(let code, let message, _):
            return "server error \(code.rawValue): \(message)"
        case .malformedResponse(let description):
            return "malformed response: \(description)"
        case .auth(let reason, let message):
            return "auth error (\(reason.rawValue)): \(message)"
        case .validation(let fieldErrors, let message):
            let joined = fieldErrors.map { "\($0.field)=\($0.issue)" }.joined(separator: ", ")
            return "validation failed: \(message) [\(joined)]"
        case .entitlementRequired(let code, let message):
            return "entitlement required (\(code.rawValue)): \(message)"
        case .rateLimited(let resetDate, let message):
            let reset = resetDate.map { "resets \($0)" } ?? "no reset date"
            return "rate limited: \(message) (\(reset))"
        case .voiceSessionInvalid(let reason, let message):
            return "voice session invalid (\(reason?.rawValue ?? "unknown")): \(message)"
        case .configuration(let appConfigError):
            return "configuration error: \(appConfigError)"
        case .coreData(let underlying):
            return "core data error: \(underlying.localizedDescription)"
        case .cloudKit(let underlying):
            return "cloudkit error: \(underlying.localizedDescription)"
        case .unknown(let underlying):
            return "unknown error: \(underlying.localizedDescription)"
        }
    }
}
