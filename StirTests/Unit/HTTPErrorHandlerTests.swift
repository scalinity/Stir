// HTTPErrorHandlerTests
//
// Direct unit coverage for `HTTPErrorHandler.classify` (extracted in SCA-119).
// Faster than the integration tests in SupabaseSessionClientTests because it
// drops URLProtocol mocking + the actor wrapper — every branch in the
// classifier is exercised in microseconds.
//
// Branches covered: 2xx success, 400 VAL-01 (with field_errors → sentry
// context), 400 non-VAL-01 → server error, 401 typed AuthReason (each case
// + reason fallback when body unparseable), 403 entitlement, 403
// VOICE-SESSION-01 with reason discriminator (ADR 0017), 429 rate limited,
// 5xx with body + 5xx without body, unexpected status (1xx, 3xx).

import Foundation
import XCTest
@testable import Stir

final class HTTPErrorHandlerTests: XCTestCase {
    // MARK: - 2xx

    func test_2xx_returnsSuccess() {
        for status in [200, 201, 204, 299] {
            let result = HTTPErrorHandler.classify(
                status: status,
                data: Data(),
                requestPath: "/v1/test",
            )
            guard case .success = result else {
                return XCTFail("expected .success for status \(status), got \(result)")
            }
        }
    }

    // MARK: - 400 VAL-01

    func test_400_VAL01_returnsValidation_withSentryContext() throws {
        let body = #"{"error":"VAL-01","message":"bad body","field_errors":[{"field":"installation_id","issue":"not a UUID"},{"field":"build","issue":"missing"}]}"#
            .data(using: .utf8)!

        let result = HTTPErrorHandler.classify(
            status: 400,
            data: body,
            requestPath: "/functions/v1/session-bootstrap",
        )

        guard case let .validation(error, context) = result else {
            return XCTFail("expected .validation, got \(result)")
        }
        guard case let .validation(fieldErrors, message) = error else {
            return XCTFail("expected StirError.validation, got \(error)")
        }
        XCTAssertEqual(message, "bad body")
        XCTAssertEqual(fieldErrors.map(\.field), ["installation_id", "build"])
        XCTAssertEqual(context["endpoint"], "/functions/v1/session-bootstrap")
        XCTAssertEqual(context["code"], "VAL-01")
        XCTAssertEqual(context["field_errors"], "installation_id:not a UUID,build:missing")
    }

    func test_400_VAL01_emptyFieldErrors_producesEmptySentryString() throws {
        let body = #"{"error":"VAL-01","message":"bad body"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 400, data: body, requestPath: "/x")
        guard case let .validation(_, context) = result else {
            return XCTFail("expected .validation")
        }
        XCTAssertEqual(context["field_errors"], "")
    }

    func test_400_unknownCode_fallsBackToVAL01() {
        // Per pre-extraction behavior: ErrorCode(rawValue: body.error) ?? .val01
        // means an unknown error string at 400 still gets classified as
        // validation. Lock it in so a future refactor doesn't accidentally
        // reroute these to .nonRetryableError.
        let body = #"{"error":"WAT-99","message":"weird"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 400, data: body, requestPath: "/x")
        guard case .validation = result else {
            return XCTFail("expected .validation, got \(result)")
        }
    }

    func test_400_unparseableBody_returnsNonRetryableMalformed() {
        let result = HTTPErrorHandler.classify(
            status: 400,
            data: Data("not json".utf8),
            requestPath: "/x",
        )
        guard case let .nonRetryableError(error) = result else {
            return XCTFail("expected .nonRetryableError, got \(result)")
        }
        guard case .malformedResponse = error else {
            return XCTFail("expected .malformedResponse, got \(error)")
        }
    }

    // MARK: - 401 AUTH-01

    func test_401_eachAuthReason_decodesCorrectly() {
        let cases: [(rawReason: String, expected: AuthReason)] = [
            ("missing", .missing),
            ("expired", .expired),
            ("malformed", .malformed),
            ("signature_invalid", .signatureInvalid),
            ("user_stale", .userStale),
            ("reauth_required", .reauthRequired),
        ]
        for (raw, expected) in cases {
            let body = #"{"error":"AUTH-01","message":"x","reason":"\#(raw)"}"#.data(using: .utf8)!
            let result = HTTPErrorHandler.classify(status: 401, data: body, requestPath: "/x")
            guard case let .auth(reason, _) = result else {
                XCTFail("expected .auth for reason=\(raw), got \(result)")
                continue
            }
            XCTAssertEqual(reason, expected, "raw=\(raw)")
        }
    }

    func test_401_unparseableBody_defaultsToMissing() {
        // Matches pre-extraction performStream behavior — the stream variant
        // could call this with empty/malformed bytes when the server returned
        // a bare 401 without a body. Default reason ensures the auth-retry
        // path still kicks in instead of throwing malformedResponse.
        let result = HTTPErrorHandler.classify(
            status: 401,
            data: Data(),
            requestPath: "/x",
        )
        guard case let .auth(reason, message) = result else {
            return XCTFail("expected .auth, got \(result)")
        }
        XCTAssertEqual(reason, .missing)
        XCTAssertEqual(message, "session missing")
    }

    func test_401_unknownReasonValue_defaultsToMissing() {
        let body = #"{"error":"AUTH-01","message":"x","reason":"future_reason"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 401, data: body, requestPath: "/x")
        guard case let .auth(reason, _) = result else {
            return XCTFail("expected .auth")
        }
        XCTAssertEqual(reason, .missing)
    }

    // MARK: - 403 entitlement / VOICE-SESSION-01

    func test_403_entVoice01_returnsEntitlementRequired() {
        let body = #"{"error":"ENT-VOICE-01","message":"voice is Premium+"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 403, data: body, requestPath: "/x")
        guard case let .nonRetryableError(error) = result else {
            return XCTFail("expected .nonRetryableError")
        }
        guard case let .entitlementRequired(code, message) = error else {
            return XCTFail("expected .entitlementRequired, got \(error)")
        }
        XCTAssertEqual(code, .entVoice01)
        XCTAssertEqual(message, "voice is Premium+")
    }

    func test_403_voiceSession01_routesToVoiceSessionInvalid() {
        let body = #"{"error":"VOICE-SESSION-01","message":"session closed","reason":"session_closed"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 403, data: body, requestPath: "/x")
        guard case let .nonRetryableError(error) = result else {
            return XCTFail("expected .nonRetryableError")
        }
        guard case let .voiceSessionInvalid(reason, message) = error else {
            return XCTFail("expected .voiceSessionInvalid, got \(error)")
        }
        XCTAssertEqual(reason, .sessionClosed)
        XCTAssertEqual(message, "session closed")
    }

    func test_403_voiceSession01_unknownReason_decodesNil() {
        let body = #"{"error":"VOICE-SESSION-01","message":"x","reason":"future_reason"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 403, data: body, requestPath: "/x")
        guard case let .nonRetryableError(.voiceSessionInvalid(reason, _)) = result else {
            return XCTFail("expected .voiceSessionInvalid")
        }
        XCTAssertNil(reason)
    }

    func test_403_unknownCode_fallsBackToBill01() {
        let body = #"{"error":"WAT-99","message":"weird"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 403, data: body, requestPath: "/x")
        guard case let .nonRetryableError(.entitlementRequired(code, _)) = result else {
            return XCTFail("expected .entitlementRequired")
        }
        XCTAssertEqual(code, .bill01)
    }

    func test_403_unparseableBody_returnsNonRetryableMalformed() {
        let result = HTTPErrorHandler.classify(status: 403, data: Data("ugh".utf8), requestPath: "/x")
        guard case let .nonRetryableError(error) = result else {
            return XCTFail("expected .nonRetryableError")
        }
        guard case .malformedResponse = error else {
            return XCTFail("expected .malformedResponse, got \(error)")
        }
    }

    // MARK: - 429 RATE-01

    func test_429_returnsRateLimited() {
        let body = #"{"error":"RATE-01","message":"slow down"}"#.data(using: .utf8)!
        let result = HTTPErrorHandler.classify(status: 429, data: body, requestPath: "/x")
        guard case let .nonRetryableError(error) = result else {
            return XCTFail("expected .nonRetryableError")
        }
        guard case let .rateLimited(_, message) = error else {
            return XCTFail("expected .rateLimited, got \(error)")
        }
        XCTAssertEqual(message, "slow down")
    }

    func test_429_unparseableBody_defaultMessage() {
        let result = HTTPErrorHandler.classify(status: 429, data: Data(), requestPath: "/x")
        guard case let .nonRetryableError(.rateLimited(_, message)) = result else {
            return XCTFail("expected .rateLimited")
        }
        XCTAssertEqual(message, "rate limited")
    }

    // MARK: - 5xx

    func test_5xx_withBody_returnsRetryableServerError() {
        let body = #"{"error":"AI-01","message":"upstream"}"#.data(using: .utf8)!
        for status in [500, 502, 503, 599] {
            let result = HTTPErrorHandler.classify(status: status, data: body, requestPath: "/x")
            guard case let .retryable5xx(error) = result else {
                XCTFail("expected .retryable5xx for \(status), got \(result)")
                continue
            }
            guard case let .server(code, message, _) = error else {
                XCTFail("expected .server for \(status), got \(error)")
                continue
            }
            XCTAssertEqual(code, .ai01)
            XCTAssertEqual(message, "upstream")
        }
    }

    func test_5xx_withoutBody_defaultsToAI01() {
        let result = HTTPErrorHandler.classify(status: 503, data: Data(), requestPath: "/x")
        guard case let .retryable5xx(.server(code, message, _)) = result else {
            return XCTFail("expected .retryable5xx server")
        }
        XCTAssertEqual(code, .ai01)
        XCTAssertEqual(message, "upstream error")
    }

    // MARK: - unexpected

    func test_unexpectedStatus_outsideRanges_throwsMalformed() {
        for status in [100, 199, 304] {
            let result = HTTPErrorHandler.classify(status: status, data: Data(), requestPath: "/x")
            guard case let .unexpectedStatus(error) = result else {
                XCTFail("expected .unexpectedStatus for \(status), got \(result)")
                continue
            }
            guard case let .malformedResponse(description) = error else {
                XCTFail("expected .malformedResponse for \(status), got \(error)")
                continue
            }
            XCTAssertTrue(description.contains("\(status)"), "description=\(description)")
        }
    }
}
