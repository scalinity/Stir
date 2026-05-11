// HTTPErrorHandler
//
// Shared status-translation core for `SupabaseSessionClient.perform`,
// `performNoContent`, and `performStream`. Each variant previously carried a
// near-identical ~100-LOC switch that decoded the typed error body, mapped
// status codes to `StirError` cases (AUTH-01, VAL-01, ENT-*, RATE-01,
// VOICE-SESSION-01, 5xx, etc.), and short-circuited on `reauth_required`.
// Lifted here so a new AuthReason or error code lands in one place.
//
// Design notes:
//   - This helper is pure — no actor state, no I/O. It returns a classification
//     describing what the variant should do; the variant executes the policy
//     (silent rebootstrap retry on AUTH-01 lives in the actor because it
//     touches `lastBootstrapIdentity` and the request rebuild).
//   - 5xx retry semantics differ between variants (perform/performNoContent
//     retry up to 3x with backoff; performStream does not). The classification
//     surfaces 5xx as `.retryable5xx` so each variant decides its own policy.
//   - VAL-01 still produces a Sentry context dict pre-built here; the variant
//     just hands it to its injected `SentryReporting` and throws the error.
//   - The `reauth_required` AuthReason (ADR 0023) MUST short-circuit the
//     silent-retry path. The variant inspects `.auth(reason:)` and skips
//     re-bootstrap when reason == `.reauthRequired`.

import Foundation

/// Outcome of mapping an HTTP response (status + decoded body) to either a
/// `StirError` or a control-flow signal for the calling perform-variant.
enum HTTPErrorMappingResult: Sendable {
    /// 2xx — caller proceeds with body decode (or returns void).
    case success

    /// 401 AUTH-01. Caller decides whether to short-circuit on
    /// `.reauthRequired` (ADR 0023) or attempt a silent re-bootstrap retry.
    case auth(reason: AuthReason, message: String)

    /// 400 VAL-01 — request body validation failure. `sentryContext` is
    /// prebuilt for `SentryReporting.captureError(_:context:)`.
    case validation(StirError, sentryContext: [String: String])

    /// 400 non-VAL-01, 403 (entitlement / VOICE-SESSION-01), 429.
    /// Caller throws unconditionally — never retried.
    case nonRetryableError(StirError)

    /// 500-599. Caller decides whether to back off + retry (perform /
    /// performNoContent) or surface immediately (performStream).
    case retryable5xx(StirError)

    /// Anything outside the documented status ranges. Caller throws
    /// `.malformedResponse` so callers don't silently treat unknown
    /// codes as success.
    case unexpectedStatus(StirError)
}

enum HTTPErrorHandler {
    /// Map an HTTP response to a `HTTPErrorMappingResult`. Pure.
    ///
    /// - Parameters:
    ///   - status: `HTTPURLResponse.statusCode`.
    ///   - data: Response body bytes (may be empty on URL-level failure paths,
    ///     but those should never reach this helper — surface them via
    ///     `.networkUnreachable` before calling `classify`).
    ///   - requestPath: The originating `URLRequest.url?.path`, used only for
    ///     the VAL-01 Sentry context. `?` if unavailable.
    static func classify(
        status: Int,
        data: Data,
        requestPath: String,
    ) -> HTTPErrorMappingResult {
        switch status {
        case 200 ..< 300:
            return .success

        case 400:
            return classify400(data: data, requestPath: requestPath)

        case 401:
            return classify401(data: data)

        case 403:
            return classify403(data: data)

        case 429:
            let body = try? parseErrorBody(data)
            return .nonRetryableError(
                .rateLimited(resetDate: nil, message: body?.message ?? "rate limited"),
            )

        case 500 ..< 600:
            // perform / performNoContent retry per their own policy; performStream
            // throws. Both variants should log the 5xx via their own loggers
            // before invoking the retry path (status code surfaces in the
            // returned StirError already).
            //
            // SCA-297 (W3): Default-code selection is path-aware. AI endpoints
            // (`/v1/ai/*`) keep the historical AI-01 fallback so the UI maps
            // "AI temporarily unavailable" copy. Non-AI 5xx (gateway,
            // session-bootstrap, config-bootstrap, ops-admin, push-register)
            // synthesizes INTERNAL-01 — distinct from NET-01 so iOS copy can
            // say "server" not "network", and it doesn't mis-attribute Gemini
            // outages onto unrelated backend failures.
            let body = try? parseErrorBody(data)
            let parsedCode = ErrorCode(rawValue: body?.error ?? "")
            let defaultCode: ErrorCode = requestPath.contains("/v1/ai/") ? .ai01 : .internal01
            return .retryable5xx(
                .server(
                    code: parsedCode ?? defaultCode,
                    message: body?.message ?? "upstream error",
                    fieldErrors: body?.fieldErrors ?? [],
                ),
            )

        default:
            return .unexpectedStatus(
                .malformedResponse(description: "unexpected status \(status)"),
            )
        }
    }

    // MARK: - Status-specific helpers

    private static func classify400(
        data: Data,
        requestPath: String,
    ) -> HTTPErrorMappingResult {
        let body: ErrorResponseBody
        do {
            body = try parseErrorBody(data)
        } catch let stirError as StirError {
            // `parseErrorBody` only ever throws `StirError.malformedResponse`
            // (see its do/catch rethrow). Match on the concrete type so the
            // SCA-119-era `as? StirError ?? .malformedResponse(...)` fallback
            // — which was unreachable dead code (SCA-297 W16) — goes away.
            return .nonRetryableError(stirError)
        } catch {
            // Defensive: if `parseErrorBody`'s throw contract ever broadens
            // beyond StirError, surface a stable malformed-response shape
            // rather than crashing.
            return .nonRetryableError(.malformedResponse(
                description: "400 with unparseable body",
            ))
        }
        let code = ErrorCode(rawValue: body.error) ?? .val01
        if code == .val01 {
            let fieldErrors = body.fieldErrors ?? []
            let stirError = StirError.validation(
                fieldErrors: fieldErrors,
                message: body.message,
            )
            let sentryContext: [String: String] = [
                "endpoint": requestPath,
                "code": body.error,
                "field_errors": fieldErrors.map { "\($0.field):\($0.issue)" }
                    .joined(separator: ","),
            ]
            return .validation(stirError, sentryContext: sentryContext)
        }
        return .nonRetryableError(
            .server(
                code: code,
                message: body.message,
                fieldErrors: body.fieldErrors ?? [],
            ),
        )
    }

    private static func classify401(data: Data) -> HTTPErrorMappingResult {
        // 401 bodies normally carry typed AUTH-01 reason. If the body fails
        // to parse (legacy server error path or empty body from
        // performStream's error drain), default reason=missing so the caller
        // still routes through its standard auth-retry path. Matches the
        // pre-extraction behavior in `performStream` (`body?.reason ?? "missing"`).
        let body = try? parseErrorBody(data)
        let reason = AuthReason(rawValue: body?.reason ?? "missing") ?? .missing
        let message = body?.message ?? "session missing"
        return .auth(reason: reason, message: message)
    }

    private static func classify403(data: Data) -> HTTPErrorMappingResult {
        let body: ErrorResponseBody
        do {
            body = try parseErrorBody(data)
        } catch let stirError as StirError {
            // See classify400 — SCA-297 W16. `parseErrorBody` only throws
            // `StirError.malformedResponse`; the prior `as?` fallback was
            // unreachable.
            return .nonRetryableError(stirError)
        } catch {
            return .nonRetryableError(.malformedResponse(
                description: "403 with unparseable body",
            ))
        }
        let code = ErrorCode(rawValue: body.error) ?? .bill01
        // VOICE-SESSION-01 (ADR 0017) is a lifecycle failure, NOT an
        // entitlement failure — MUST NOT paywall. Distinct StirError case so
        // callers can rebuild the voice driver silently.
        if code == .voiceSession01 {
            let reason = body.reason.flatMap(VoiceSessionReason.init(rawValue:))
            return .nonRetryableError(
                .voiceSessionInvalid(reason: reason, message: body.message),
            )
        }
        return .nonRetryableError(
            .entitlementRequired(code: code, message: body.message),
        )
    }

    /// Decode the typed error envelope. Throws `.malformedResponse` (rather
    /// than the raw `DecodingError`) so callers can surface a stable error
    /// shape if the body isn't a valid `ErrorResponseBody`.
    private static func parseErrorBody(_ data: Data) throws -> ErrorResponseBody {
        do {
            return try JSONDecoder.stir.decode(ErrorResponseBody.self, from: data)
        } catch {
            throw StirError.malformedResponse(
                description: "failed to decode ErrorResponseBody: \(error.localizedDescription)",
            )
        }
    }
}
