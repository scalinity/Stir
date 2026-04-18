// SupabaseSessionClient
//
// URLSession-backed client for /v1/session/bootstrap + /v1/config/bootstrap.
// Handles the step-2 prompt's requirements:
//
//   - Stores session JWT in Keychain, not UserDefaults
//   - On 401 AUTH-01 from any authenticated call: clears JWT, re-bootstraps
//     once using the cached (installationID, cloudKitRecordName), retries
//     the original request ONCE. If retry also 401s, surfaces NET-01.
//   - On 400 VAL-01: captures to Sentry at error severity with
//     structured field_errors, throws StirError.validation. Never retries.
//   - On 5xx: exponential backoff 0.5s / 1.5s / 3s (three retries), then
//     throws StirError.networkUnreachable.
//
// Not yet implemented (lands with step 3+):
//   - performAuthenticated<T>(_:) — generic typed wrapper for /v1/ai/*
//
// Design notes:
//   - Actor isolates cachedJWT + lastBootstrapIdentity mutation.
//   - URLSession + Keychain + Sentry injected for testability.
//   - Snake-case JSON keys handled via per-struct CodingKeys (not
//     `.convertFromSnakeCase`) so DTOs stay explicit about wire shape.

import Foundation
import OSLog

actor SupabaseSessionClient {
    private let config: AppConfig
    private let keychain: any KeychainStoring
    private let urlSession: URLSession
    private let sentry: any SentryReporting
    private let clock: any Clock<Duration>

    /// Cached session JWT (mirrors Keychain `.sessionJWT`).
    private var cachedJWT: String?

    /// Last-successful bootstrap's identity — used for silent AUTH-01 retry.
    private var lastBootstrapIdentity: (installationID: String, cloudKitRecordName: String?)?

    init(
        config: AppConfig,
        keychain: any KeychainStoring = KeychainStorage.shared,
        urlSession: URLSession = .shared,
        sentry: any SentryReporting = NoOpSentryReporter(),
        clock: any Clock<Duration> = ContinuousClock(),
    ) {
        self.config = config
        self.keychain = keychain
        self.urlSession = urlSession
        self.sentry = sentry
        self.clock = clock

        // Prime cachedJWT from Keychain so authenticated calls can run across
        // app relaunches without a mandatory re-bootstrap on every cold start.
        // (RootCoordinator still re-bootstraps once on cold start to refresh
        // entitlements; this cache covers the gap between launch and bootstrap
        // completing.)
        if let jwt = try? keychain.read(key: .sessionJWT) {
            self.cachedJWT = jwt
        }
    }

    // MARK: - Public surface

    @discardableResult
    func bootstrap(
        installationID: String,
        cloudKitRecordName: String?,
    ) async throws -> BootstrapResponse {
        let body = BootstrapRequest(
            installationID: installationID,
            cloudKitUserRecordName: cloudKitRecordName,
            build: config.build,
            osVersion: config.osVersion,
        )

        let request = try buildRequest(
            path: "/functions/v1/session-bootstrap",
            method: "POST",
            body: body,
            authenticated: false,
        )

        let response: BootstrapResponse = try await perform(
            request,
            attempt: 0,
            retriedAuth: true,
            // `retriedAuth: true` means "don't attempt AUTH-01 retry on this
            // call" — bootstrap itself doesn't carry a session JWT so AUTH-01
            // is impossible, and retry would loop.
        )

        // Persist JWT + identity for future authenticated calls.
        do {
            try keychain.write(response.sessionJWT, key: .sessionJWT)
            self.cachedJWT = response.sessionJWT
            self.lastBootstrapIdentity = (installationID, cloudKitRecordName)
        } catch {
            Logger.supabase.error("failed to persist session JWT: \(error.localizedDescription, privacy: .public)")
            // Non-fatal — the in-memory cachedJWT still works this session.
            self.cachedJWT = response.sessionJWT
            self.lastBootstrapIdentity = (installationID, cloudKitRecordName)
        }

        return response
    }

    func configBootstrap() async throws -> ConfigBootstrapResponse {
        let request = try buildRequest(
            path: "/functions/v1/config-bootstrap",
            method: "GET",
            body: Optional<String>.none,
            authenticated: true,
        )
        return try await perform(request, attempt: 0, retriedAuth: false)
    }

    /// Reserved for step 3+ AI endpoints. Shapes the same AUTH-01 silent-
    /// retry + 5xx backoff as bootstrap; delegates to `perform` after
    /// building an authenticated request.
    func performAuthenticated<T: Decodable & Sendable>(
        _ request: URLRequest,
    ) async throws -> T {
        var mutable = request
        mutable.addValue("application/json", forHTTPHeaderField: "accept")
        // Attach JWT + apikey. Caller is expected to have set the URL + body.
        if let jwt = cachedJWT {
            mutable.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        mutable.setValue(config.supabase.anonKey, forHTTPHeaderField: "apikey")
        return try await perform(mutable, attempt: 0, retriedAuth: false)
    }

    /// Remove the cached JWT — called on explicit sign-out flows or when
    /// AUTH-01 re-bootstrap exhausts its single retry.
    func clearSession() {
        cachedJWT = nil
        try? keychain.delete(key: .sessionJWT)
    }

    // MARK: - Request building

    private func buildRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        authenticated: Bool,
    ) throws -> URLRequest {
        let url = config.supabase.url.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        // `apikey` is the PostgREST gateway requirement; anon key is public
        // and safe to bundle per Supabase's RLS-enforced design.
        request.setValue(config.supabase.anonKey, forHTTPHeaderField: "apikey")

        if authenticated {
            guard let jwt = cachedJWT else {
                // No JWT cached — treat as AUTH-01 reason=missing so the
                // caller's re-bootstrap path kicks in.
                throw StirError.auth(reason: .missing, message: "no cached session JWT")
            }
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }

        // Only encode non-empty bodies. Optional<String>.none sentinel means
        // no body (used for GETs that don't carry payload).
        if let body = Self.unwrapOptional(body) {
            request.httpBody = try JSONEncoder.stir.encode(body)
        }

        return request
    }

    /// Unwrap `Optional<T>` used as a sentinel for empty bodies.
    private static func unwrapOptional<Body: Encodable>(_ value: Body) -> Body? {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional, mirror.children.isEmpty {
            return nil
        }
        return value
    }

    // MARK: - Perform (retry + AUTH-01 loop)

    private func perform<Response: Decodable & Sendable>(
        _ request: URLRequest,
        attempt: Int,
        retriedAuth: Bool,
    ) async throws -> Response {
        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            Logger.supabase.error(
                "urlsession failure: \(error.localizedDescription, privacy: .public)",
            )
            // URL-level failures (DNS, offline) = network-unreachable.
            if attempt < 3 {
                try await backoff(attempt: attempt)
                return try await perform(request, attempt: attempt + 1, retriedAuth: retriedAuth)
            }
            throw StirError.networkUnreachable(underlying: error)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw StirError.malformedResponse(description: "not an HTTPURLResponse")
        }

        switch http.statusCode {
        case 200 ..< 300:
            do {
                return try JSONDecoder.stir.decode(Response.self, from: data)
            } catch {
                Logger.supabase.error(
                    "decode failed (status=\(http.statusCode)): \(error.localizedDescription, privacy: .public)",
                )
                throw StirError.malformedResponse(description: error.localizedDescription)
            }

        case 400:
            let body = try parseErrorBody(data)
            let code = ErrorCode(rawValue: body.error) ?? .val01
            if code == .val01 {
                let fieldErrors = body.fieldErrors ?? []
                let stirError = StirError.validation(
                    fieldErrors: fieldErrors,
                    message: body.message,
                )
                Logger.supabase.error(
                    "VAL-01 at \(request.url?.path ?? "?", privacy: .public): \(body.message, privacy: .public)",
                )
                sentry.captureError(
                    stirError,
                    context: [
                        "endpoint": request.url?.path ?? "?",
                        "code": body.error,
                        "field_errors": fieldErrors.map { "\($0.field):\($0.issue)" }
                            .joined(separator: ","),
                    ],
                )
                throw stirError
            }
            throw StirError.server(code: code, message: body.message, fieldErrors: body.fieldErrors ?? [])

        case 401:
            let body = try parseErrorBody(data)
            let reason = AuthReason(rawValue: body.reason ?? "missing") ?? .missing
            Logger.supabase.info("AUTH-01 reason=\(reason.rawValue, privacy: .public)")
            if !retriedAuth {
                // Silent re-bootstrap + retry ONCE.
                guard let identity = lastBootstrapIdentity else {
                    // No identity cached — caller must handle.
                    throw StirError.auth(reason: reason, message: body.message)
                }
                _ = try await bootstrap(
                    installationID: identity.installationID,
                    cloudKitRecordName: identity.cloudKitRecordName,
                )
                // Rebuild the request with fresh JWT.
                var retried = request
                if let jwt = cachedJWT {
                    retried.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
                }
                return try await perform(retried, attempt: 0, retriedAuth: true)
            }
            // Retry already consumed — surface.
            throw StirError.auth(reason: reason, message: body.message)

        case 403:
            let body = try parseErrorBody(data)
            let code = ErrorCode(rawValue: body.error) ?? .bill01
            throw StirError.entitlementRequired(code: code, message: body.message)

        case 429:
            let body = try? parseErrorBody(data)
            throw StirError.rateLimited(resetDate: nil, message: body?.message ?? "rate limited")

        case 500 ..< 600:
            Logger.supabase.warning(
                "5xx from \(request.url?.path ?? "?", privacy: .public): status=\(http.statusCode)",
            )
            if attempt < 3 {
                try await backoff(attempt: attempt)
                return try await perform(request, attempt: attempt + 1, retriedAuth: retriedAuth)
            }
            throw StirError.networkUnreachable(underlying: nil)

        default:
            Logger.supabase.error(
                "unexpected status \(http.statusCode) from \(request.url?.path ?? "?", privacy: .public)",
            )
            throw StirError.malformedResponse(description: "unexpected status \(http.statusCode)")
        }
    }

    private func parseErrorBody(_ data: Data) throws -> ErrorResponseBody {
        do {
            return try JSONDecoder.stir.decode(ErrorResponseBody.self, from: data)
        } catch {
            throw StirError.malformedResponse(
                description: "failed to decode ErrorResponseBody: \(error.localizedDescription)",
            )
        }
    }

    private func backoff(attempt: Int) async throws {
        // 0.5s, 1.5s, 3.0s per step-2 spec.
        let ms: Int
        switch attempt {
        case 0: ms = 500
        case 1: ms = 1500
        default: ms = 3000
        }
        try await clock.sleep(for: .milliseconds(ms))
    }
}

// MARK: - JSON coding helpers

extension JSONEncoder {
    static var stir: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var stir: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            // Postgres TIMESTAMPTZ serializes with optional fractional seconds.
            for formatter in [ISO8601DateFormatter.stirWithFractional,
                              ISO8601DateFormatter.stirWithoutFractional] {
                if let date = formatter.date(from: string) { return date }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "expected ISO8601 date: \(string)",
            )
        }
        return decoder
    }
}

extension ISO8601DateFormatter {
    static let stirWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let stirWithoutFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// Sendable conformance on ISO8601DateFormatter (reference type, thread-safe
// per docs but not marked Sendable by default).
extension ISO8601DateFormatter: @unchecked @retroactive Sendable {}
