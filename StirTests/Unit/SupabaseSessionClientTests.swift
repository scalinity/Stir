// SupabaseSessionClientTests
//
// URLProtocol-mocked client tests. Covers the step-2 prompt's error matrix:
//   - Happy-path bootstrap → JWT persisted to Keychain
//   - AUTH-01 on config-bootstrap → silent re-bootstrap + retry once
//   - VAL-01 → Sentry capture + throw StirError.validation
//   - 5xx → exponential backoff (we verify retries, not exact timing)

import Foundation
import XCTest
@testable import Stir

final class SupabaseSessionClientTests: XCTestCase {
    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    func test_bootstrap_happyPath_persistsJWTToKeychain() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/session-bootstrap")
            XCTAssertEqual(request.httpMethod, "POST")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "application/json"])!,
                    Self.bootstrapResponseJSON())
        }
        let keychain = MockKeychain()
        let client = SupabaseSessionClient(
            config: Self.config(),
            keychain: keychain,
            urlSession: MockURLProtocol.stubSession(),
            sentry: NoOpSentryReporter(),
            clock: ImmediateClock(),
        )

        let response = try await client.bootstrap(
            installationID: "test-install",
            cloudKitRecordName: nil,
        )

        XCTAssertEqual(response.sessionJWT, "test.jwt.value")
        XCTAssertEqual(response.entitlements.tier, .free)
        XCTAssertEqual(response.entitlements.quotas.count, 3)
        XCTAssertEqual(keychain.snapshot[.sessionJWT], "test.jwt.value")
    }

    func test_bootstrap_withCloudKitRecord_fetchesWebAuthTokenForBody() async throws {
        let tokenCalls = CallsBox()
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/functions/v1/session-bootstrap")
            let payload = try XCTUnwrap(Self.jsonBody(request))
            XCTAssertEqual(payload["cloudkit_user_record_name"] as? String, "_1234567890abcdef1234567890abcdef")
            XCTAssertEqual(payload["cloudkit_web_auth_token"] as? String, "web-token-1")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "application/json"])!,
                    Self.bootstrapResponseJSON())
        }
        let client = SupabaseSessionClient(
            config: Self.config(cloudKitAPIKey: "cloudkit-api-token"),
            keychain: MockKeychain(),
            urlSession: MockURLProtocol.stubSession(),
            sentry: NoOpSentryReporter(),
            clock: ImmediateClock(),
            cloudKitWebAuthTokenProvider: { apiToken in
                XCTAssertEqual(apiToken, "cloudkit-api-token")
                tokenCalls.append("token")
                return "web-token-1"
            },
        )

        _ = try await client.bootstrap(
            installationID: "iid",
            cloudKitRecordName: "_1234567890abcdef1234567890abcdef",
        )

        XCTAssertEqual(tokenCalls.snapshot, ["token"])
    }

    func test_configBootstrap_AUTH01_retriesAfterReBootstrap() async throws {
        let callsBox = CallsBox()
        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            callsBox.append(path)

            if path == "/functions/v1/session-bootstrap" {
                // bootstrap returns fresh JWT
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Self.bootstrapResponseJSON(jwt: "fresh.jwt.value"))
            }
            if path == "/functions/v1/config-bootstrap" {
                // First call: 401 AUTH-01 expired. Second (post-retry): 200.
                let attemptsSoFar = callsBox.snapshot.filter { $0 == path }.count
                if attemptsSoFar == 1 {
                    let body = "{\"error\":\"AUTH-01\",\"message\":\"expired\",\"reason\":\"expired\"}".data(using: .utf8)!
                    return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, body)
                } else {
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            Self.configBootstrapResponseJSON())
                }
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }

        let keychain = MockKeychain()
        let client = SupabaseSessionClient(
            config: Self.config(),
            keychain: keychain,
            urlSession: MockURLProtocol.stubSession(),
            sentry: NoOpSentryReporter(),
            clock: ImmediateClock(),
        )

        // Prime identity cache by calling bootstrap once.
        _ = try await client.bootstrap(installationID: "iid", cloudKitRecordName: nil)
        callsBox.clear()

        // Now call config-bootstrap — expect 401 → re-bootstrap → retry → 200.
        let response = try await client.configBootstrap()
        XCTAssertEqual(response.prompts.count, 3)  // whatever we stub

        // Verify the sequence: config-bootstrap, session-bootstrap (retry), config-bootstrap.
        let calls = callsBox.snapshot
        XCTAssertEqual(calls, [
            "/functions/v1/config-bootstrap",
            "/functions/v1/session-bootstrap",
            "/functions/v1/config-bootstrap",
        ])
    }

    func test_bootstrap_VAL01_throwsValidation_capturesOnSentry() async throws {
        final class SpySentry: SentryReporting, @unchecked Sendable {
            let lock = NSLock()
            private var _captured: [(any Error, [String: String])] = []
            var captured: [(any Error, [String: String])] {
                lock.lock(); defer { lock.unlock() }; return _captured
            }
            func captureError(_ error: any Error, context: [String: String]) {
                lock.lock(); defer { lock.unlock() }
                _captured.append((error, context))
            }
            func breadcrumb(category: String, message: String, data: [String: String]) {}
            func setUserContext(keyHash: String) {}
        }

        MockURLProtocol.handler = { request in
            let body = #"{"error":"VAL-01","message":"bad body","field_errors":[{"field":"installation_id","issue":"not a UUID"}]}"#.data(using: .utf8)!
            return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, body)
        }

        let sentry = SpySentry()
        let client = SupabaseSessionClient(
            config: Self.config(),
            keychain: MockKeychain(),
            urlSession: MockURLProtocol.stubSession(),
            sentry: sentry,
            clock: ImmediateClock(),
        )

        do {
            _ = try await client.bootstrap(installationID: "iid", cloudKitRecordName: nil)
            XCTFail("expected StirError.validation")
        } catch {
            guard case StirError.validation(let fields, let message) = error else {
                return XCTFail("expected .validation got \(error)")
            }
            XCTAssertEqual(fields.first?.field, "installation_id")
            XCTAssertEqual(message, "bad body")
        }

        XCTAssertEqual(sentry.captured.count, 1, "VAL-01 should capture exactly once")
    }

    func test_5xx_retriesThreeTimesThenThrowsNetworkUnreachable() async throws {
        let callsBox = CallsBox()
        MockURLProtocol.handler = { request in
            callsBox.append(request.url?.path ?? "")
            return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = SupabaseSessionClient(
            config: Self.config(),
            keychain: MockKeychain(),
            urlSession: MockURLProtocol.stubSession(),
            sentry: NoOpSentryReporter(),
            clock: ImmediateClock(),
        )

        do {
            _ = try await client.bootstrap(installationID: "iid", cloudKitRecordName: nil)
            XCTFail("expected StirError.networkUnreachable")
        } catch {
            guard case StirError.networkUnreachable = error else {
                return XCTFail("expected .networkUnreachable got \(error)")
            }
        }
        // 3 retries + original = 4 attempts
        XCTAssertEqual(callsBox.snapshot.count, 4)
    }

    // MARK: - Helpers

    private static func config() -> AppConfig {
        AppConfig(
            supabase: AppConfig.Supabase(
                url: URL(string: "https://test.supabase.co")!,
                anonKey: "test-anon",
            ),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            build: "1.0.0 (1)",
            osVersion: "17.5",
        )
    }

    private static func config(cloudKitAPIKey: String) -> AppConfig {
        AppConfig(
            supabase: AppConfig.Supabase(
                url: URL(string: "https://test.supabase.co")!,
                anonKey: "test-anon",
            ),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            cloudKit: AppConfig.CloudKit(apiToken: cloudKitAPIKey),
            build: "1.0.0 (1)",
            osVersion: "17.5",
        )
    }

    private static func jsonBody(_ request: URLRequest) -> [String: Any]? {
        let data: Data
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        } else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func bootstrapResponseJSON(jwt: String = "test.jwt.value") -> Data {
        """
        {
          "session_jwt": "\(jwt)",
          "canonical_user_key": "install:test-uuid",
          "is_new_user": true,
          "entitlements": {
            "tier": "free",
            "billing_state": "none",
            "is_trial": false,
            "expires_at": null,
            "voice_enabled": false,
            "billing_retry_banner": false,
            "standing_pantry_cap": 25,
            "quotas": [
              { "feature_key": "dinner_solve", "used": 0, "cap": 6, "period_end": "2026-05-18" },
              { "feature_key": "voice_cook_session", "used": 0, "cap": 0, "period_end": "2026-05-18" },
              { "feature_key": "recipe_import", "used": 0, "cap": 2, "period_end": "2026-05-18" }
            ]
          },
          "feature_flags": []
        }
        """.data(using: .utf8)!
    }

    private static func configBootstrapResponseJSON() -> Data {
        """
        {
          "entitlements": {
            "tier": "free",
            "billing_state": "none",
            "is_trial": false,
            "expires_at": null,
            "voice_enabled": false,
            "billing_retry_banner": false,
            "standing_pantry_cap": 25,
            "quotas": []
          },
          "feature_flags": [],
          "prompts": [
            { "feature_key": "dinner_solve", "version": "0.0.0", "provider_model": "gemini-3-flash-preview", "schema_hash": "", "is_default": true, "is_enabled": false },
            { "feature_key": "pantry_parse", "version": "0.0.0", "provider_model": "gemini-3-flash-preview", "schema_hash": "", "is_default": true, "is_enabled": false },
            { "feature_key": "cook_turn", "version": "0.0.0", "provider_model": "gemini-3-flash-preview", "schema_hash": "", "is_default": true, "is_enabled": false }
          ]
        }
        """.data(using: .utf8)!
    }
}

// MARK: - Supporting types

/// Fast clock for tests — zero actual sleep.
struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        let value: Int
        func advanced(by duration: Duration) -> Instant { Instant(value: value) }
        func duration(to other: Instant) -> Duration { .zero }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.value < rhs.value }
    }
    var now: Instant { Instant(value: 0) }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {}
}

/// Shared-state helper for accumulating call traces across the MockURLProtocol
/// handler (which runs on background URLSession threads).
final class CallsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    func append(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(path)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        _calls.removeAll()
    }

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
}
