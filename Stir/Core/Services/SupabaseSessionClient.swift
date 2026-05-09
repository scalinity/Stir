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
    private let cloudKitWebAuthTokenProvider: (@Sendable (String) async -> String?)?

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
        cloudKitWebAuthTokenProvider: (@Sendable (String) async -> String?)? = nil,
    ) {
        self.config = config
        self.keychain = keychain
        self.urlSession = urlSession
        self.sentry = sentry
        self.clock = clock
        self.cloudKitWebAuthTokenProvider = cloudKitWebAuthTokenProvider

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
        cloudKitWebAuthToken: String? = nil,
    ) async throws -> BootstrapResponse {
        let body = BootstrapRequest(
            installationID: installationID,
            cloudKitUserRecordName: cloudKitRecordName,
            cloudKitWebAuthToken: await resolveCloudKitWebAuthToken(
                explicitToken: cloudKitWebAuthToken,
                cloudKitRecordName: cloudKitRecordName,
            ),
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
            authenticated: true,
        )
        return try await perform(request, attempt: 0, retriedAuth: false)
    }

    private func resolveCloudKitWebAuthToken(
        explicitToken: String?,
        cloudKitRecordName: String?,
    ) async -> String? {
        if let explicitToken { return explicitToken }
        guard cloudKitRecordName != nil,
              let apiToken = config.cloudKit?.apiToken,
              !apiToken.isEmpty,
              let cloudKitWebAuthTokenProvider else { return nil }
        return await cloudKitWebAuthTokenProvider(apiToken)
    }

    /// Used by step 3+ AI endpoints. Shapes the same AUTH-01 silent-retry +
    /// 5xx backoff as bootstrap; delegates to `perform` after attaching
    /// JWT + apikey.
    func performAuthenticated<T: Decodable & Sendable>(
        _ request: URLRequest,
    ) async throws -> T {
        var mutable = request
        mutable.addValue("application/json", forHTTPHeaderField: "accept")
        if let jwt = cachedJWT {
            mutable.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        mutable.setValue(config.supabase.anonKey, forHTTPHeaderField: "apikey")
        return try await perform(mutable, attempt: 0, retriedAuth: false)
    }

    /// Variant for endpoints that return 204 No Content (voice-turn-usage).
    /// Same AUTH-01 silent-retry + 5xx backoff as `performAuthenticated`;
    /// skips JSON-decode entirely on 2xx so an empty response body doesn't
    /// trigger `malformedResponse`.
    func performAuthenticatedNoContent(_ request: URLRequest) async throws {
        var mutable = request
        mutable.addValue("application/json", forHTTPHeaderField: "accept")
        if let jwt = cachedJWT {
            mutable.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        mutable.setValue(config.supabase.anonKey, forHTTPHeaderField: "apikey")
        try await performNoContent(mutable, attempt: 0, retriedAuth: false)
    }

    /// Streaming variant for SSE endpoints (dinner-solve). Returns the
    /// response headers + an AsyncBytes stream the caller consumes directly.
    /// Status is checked ONCE at header time; AUTH-01 triggers a silent
    /// re-bootstrap + single retry before handing off the stream.
    ///
    /// Non-2xx responses are fully read, JSON-parsed, and thrown as typed
    /// StirError — same shape as the non-streaming path.
    func performAuthenticatedStream(
        _ request: URLRequest,
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        return try await performStream(request: request, retriedAuth: false)
    }

    private func performStream(
        request inRequest: URLRequest,
        retriedAuth: Bool,
    ) async throws -> (response: HTTPURLResponse, bytes: URLSession.AsyncBytes) {
        var request = inRequest
        request.addValue("text/event-stream", forHTTPHeaderField: "accept")
        if let jwt = cachedJWT {
            request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        request.setValue(config.supabase.anonKey, forHTTPHeaderField: "apikey")

        let (bytes, urlResponse): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, urlResponse) = try await urlSession.bytes(for: request)
        } catch {
            Logger.supabase.error("stream urlsession failure: \(error.localizedDescription, privacy: .public)")
            throw StirError.networkUnreachable(underlying: error)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw StirError.malformedResponse(description: "not an HTTPURLResponse")
        }

        switch http.statusCode {
        case 200 ..< 300:
            return (http, bytes)

        case 401:
            // Drain the error body so we can parse reason.
            let errData = try await readAllBytes(bytes)
            let body = try? parseErrorBody(errData)
            let reason = AuthReason(rawValue: body?.reason ?? "missing") ?? .missing
            logAuth01(
                reason: reason,
                message: body?.message ?? "stream 401",
                endpoint: inRequest.url?.path ?? "?",
            )
            // reauth_required (ADR 0023) bypasses silent retry — see perform().
            if reason == .reauthRequired {
                throw StirError.auth(reason: reason, message: body?.message ?? "reauth required")
            }
            if !retriedAuth, let identity = lastBootstrapIdentity {
                _ = try await bootstrap(
                    installationID: identity.installationID,
                    cloudKitRecordName: identity.cloudKitRecordName,
                )
                return try await performStream(request: inRequest, retriedAuth: true)
            }
            throw StirError.auth(reason: reason, message: body?.message ?? "session missing")

        case 403:
            let errData = try await readAllBytes(bytes)
            let body = try parseErrorBody(errData)
            let code = ErrorCode(rawValue: body.error) ?? .bill01
            // VOICE-SESSION-01 is a lifecycle failure (session expired/
            // superseded/foreign), NOT an entitlement failure — MUST
            // NOT paywall the user. Route via a dedicated case so the
            // handler rebuilds the voice driver silently. See ADR 0017.
            if code == .voiceSession01 {
                let reason = body.reason.flatMap(VoiceSessionReason.init(rawValue:))
                throw StirError.voiceSessionInvalid(reason: reason, message: body.message)
            }
            throw StirError.entitlementRequired(code: code, message: body.message)

        case 429:
            let errData = try await readAllBytes(bytes)
            let body = try? parseErrorBody(errData)
            throw StirError.rateLimited(resetDate: nil, message: body?.message ?? "rate limited")

        case 400:
            let errData = try await readAllBytes(bytes)
            let body = try parseErrorBody(errData)
            let code = ErrorCode(rawValue: body.error) ?? .val01
            if code == .val01 {
                throw StirError.validation(fieldErrors: body.fieldErrors ?? [], message: body.message)
            }
            throw StirError.server(code: code, message: body.message, fieldErrors: body.fieldErrors ?? [])

        case 500 ..< 600:
            let errData = try await readAllBytes(bytes)
            let body = try? parseErrorBody(errData)
            throw StirError.server(
                code: ErrorCode(rawValue: body?.error ?? "") ?? .ai01,
                message: body?.message ?? "upstream error",
                fieldErrors: body?.fieldErrors ?? [],
            )

        default:
            throw StirError.malformedResponse(description: "unexpected stream status \(http.statusCode)")
        }
    }

    private func readAllBytes(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count > 64 * 1024 { break } // safety cap on error bodies
        }
        return buffer
    }

    /// Remove the cached JWT — called on explicit sign-out flows or when
    /// AUTH-01 re-bootstrap exhausts its single retry.
    func clearSession() {
        cachedJWT = nil
        try? keychain.delete(key: .sessionJWT)
    }

    // MARK: - Request building

    /// Build a request carrying a JSON body.
    private func buildRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        authenticated: Bool,
    ) throws -> URLRequest {
        var request = try buildBodylessRequest(
            path: path, method: method, authenticated: authenticated,
        )
        request.httpBody = try JSONEncoder.stir.encode(body)
        return request
    }

    /// Build a request with no body (GETs, bodiless POSTs).
    private func buildRequest(
        path: String,
        method: String,
        authenticated: Bool,
    ) throws -> URLRequest {
        try buildBodylessRequest(path: path, method: method, authenticated: authenticated)
    }

    private func buildBodylessRequest(
        path: String,
        method: String,
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

        return request
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
            logAuth01(reason: reason, message: body.message, endpoint: request.url?.path ?? "?")
            // reauth_required (ADR 0023) short-circuits the silent-retry path.
            // Admin used users.force_reauth and wants THIS user kicked — silent
            // re-bootstrap would issue a fresh JWT (iat > reauth_required_at)
            // and bypass the ceremony. Surface immediately so RootCoordinator
            // can route to SIWA re-flow.
            if reason == .reauthRequired {
                throw StirError.auth(reason: reason, message: body.message)
            }
            if !retriedAuth {
                // Silent re-bootstrap + retry ONCE.
                guard let identity = lastBootstrapIdentity else {
                    // No identity cached — caller must handle.
                    throw StirError.auth(reason: reason, message: body.message)
                }
                // SCA-253 (W5 from /review-5): if the prior bootstrap had a
                // CloudKit record claim AND the on-device token provider
                // can no longer mint a fresh ckWebAuthToken (CK transient
                // outage, app backgrounded mid-mint, provider torn down),
                // a silent re-bootstrap WITHOUT the token would (post
                // SCA-136 verifier activation) trigger the server's
                // `missing_web_auth_token` strip — re-rooting the
                // `ck:<record>` identity to `install:<uuid>` for the
                // rest of the JWT lifetime. Detect that case and surface
                // AUTH-01 to the caller instead of silently rebooting,
                // so RootCoordinator can route through the SIWA re-flow
                // (or a fresh CK status check on next foreground) rather
                // than burning the user's identity on a transient.
                //
                // SCA-245 (C2) trust-mode era is fine without this guard
                // because verifier_unconfigured preserves record_name —
                // but once the verifier is activated, this is the gate
                // that prevents a one-way identity shift.
                if identity.cloudKitRecordName != nil {
                    let freshToken = await resolveCloudKitWebAuthToken(
                        explicitToken: nil,
                        cloudKitRecordName: identity.cloudKitRecordName,
                    )
                    if freshToken == nil {
                        Logger.supabase.warning(
                            "silent re-bootstrap aborted: CK record claim cached but token provider returned nil; surfacing AUTH-01 to avoid identity-shift",
                        )
                        throw StirError.auth(reason: reason, message: body.message)
                    }
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

    /// 2xx-or-typed-error variant that never tries to decode a response
    /// body. Shares the auth-retry + 5xx-backoff semantics of `perform`
    /// so callers behave identically on failure, but succeeds silently
    /// on empty 2xx responses.
    private func performNoContent(
        _ request: URLRequest,
        attempt: Int,
        retriedAuth: Bool,
    ) async throws {
        let (data, urlResponse): (Data, URLResponse)
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            Logger.supabase.error(
                "urlsession failure (no-content): \(error.localizedDescription, privacy: .public)",
            )
            if attempt < 3 {
                try await backoff(attempt: attempt)
                try await performNoContent(request, attempt: attempt + 1, retriedAuth: retriedAuth)
                return
            }
            throw StirError.networkUnreachable(underlying: error)
        }

        guard let http = urlResponse as? HTTPURLResponse else {
            throw StirError.malformedResponse(description: "not an HTTPURLResponse")
        }

        switch http.statusCode {
        case 200 ..< 300:
            return

        case 400:
            let body = try parseErrorBody(data)
            let code = ErrorCode(rawValue: body.error) ?? .val01
            if code == .val01 {
                throw StirError.validation(fieldErrors: body.fieldErrors ?? [], message: body.message)
            }
            throw StirError.server(code: code, message: body.message, fieldErrors: body.fieldErrors ?? [])

        case 401:
            let body = try parseErrorBody(data)
            let reason = AuthReason(rawValue: body.reason ?? "missing") ?? .missing
            logAuth01(reason: reason, message: body.message, endpoint: request.url?.path ?? "?")
            // reauth_required (ADR 0023) bypasses silent retry — see perform().
            if reason == .reauthRequired {
                throw StirError.auth(reason: reason, message: body.message)
            }
            if !retriedAuth {
                guard let identity = lastBootstrapIdentity else {
                    throw StirError.auth(reason: reason, message: body.message)
                }
                _ = try await bootstrap(
                    installationID: identity.installationID,
                    cloudKitRecordName: identity.cloudKitRecordName,
                )
                var retried = request
                if let jwt = cachedJWT {
                    retried.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
                }
                try await performNoContent(retried, attempt: 0, retriedAuth: true)
                return
            }
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
                "5xx (no-content) from \(request.url?.path ?? "?", privacy: .public): status=\(http.statusCode)",
            )
            if attempt < 3 {
                try await backoff(attempt: attempt)
                try await performNoContent(request, attempt: attempt + 1, retriedAuth: retriedAuth)
                return
            }
            throw StirError.networkUnreachable(underlying: nil)

        default:
            throw StirError.malformedResponse(description: "unexpected no-content status \(http.statusCode)")
        }
    }

    /// Differentiated AUTH-01 logging per CLAUDE.md §"AUTH-01 response shape":
    ///
    ///   missing | expired | user_stale  → `info` (silent-retry path)
    ///   malformed | signature_invalid   → `error` + Sentry capture (client
    ///                                      bug or backend-secret rotation;
    ///                                      needs operator attention)
    ///
    /// Central helper so both the stream + non-stream 401 handlers use the
    /// same severity map. Adding a new AuthReason must update this switch.
    private func logAuth01(reason: AuthReason, message: String, endpoint: String) {
        switch reason {
        case .missing, .expired, .userStale, .reauthRequired:
            // reauthRequired is routine support / admin flow — info severity.
            // The distinguishing concern (kick the session) is handled by
            // callers routing StirError.auth(reason: .reauthRequired) to
            // RootCoordinator.forceReauth(), not by our log level here.
            Logger.supabase.info(
                "AUTH-01 reason=\(reason.rawValue, privacy: .public) endpoint=\(endpoint, privacy: .public)",
            )
        case .malformed, .signatureInvalid:
            Logger.supabase.error(
                "AUTH-01 reason=\(reason.rawValue, privacy: .public) endpoint=\(endpoint, privacy: .public) message=\(message, privacy: .public)",
            )
            sentry.captureError(
                StirError.auth(reason: reason, message: message),
                context: [
                    "endpoint": endpoint,
                    "auth_reason": reason.rawValue,
                ],
            )
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
//
// Shared encoder/decoder instances. `JSONEncoder`/`JSONDecoder` are thread-safe
// when used in a read-only configuration — Apple's Foundation team confirmed
// this for Swift 5+ (`JSONEncoder.encode` is re-entrant). The prior `static var`
// computed pattern allocated a fresh encoder on every access, which hits hot
// paths: snapshot persist on every hydrate, AIDispatch request body encoding,
// bootstrap response decode, and every Core Data JSON column read (pantry
// snapshot / constraints / source asset IDs). `static let` caches a single
// configured instance per-process, eliminating the allocation cost and the
// `static_var_encoder_nonisolated_race` pattern where a concurrent reader
// could observe a partially-initialized encoder on first access.

extension JSONEncoder {
    static let stir: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    static let stir: JSONDecoder = {
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
    }()
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
