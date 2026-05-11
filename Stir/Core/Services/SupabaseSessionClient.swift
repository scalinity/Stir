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
        return try await performStream(request: request, retriedAuth: false, retried5xx: false)
    }

    private func performStream(
        request inRequest: URLRequest,
        retriedAuth: Bool,
        retried5xx: Bool,
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

        // 2xx returns the live byte stream so the caller can consume SSE chunks.
        // Any non-2xx fully drains the bytes into Data, hands them to the
        // shared classifier, and throws — matching pre-extraction behavior
        // (status checked once at header time; no 5xx retry on streams).
        if (200 ..< 300).contains(http.statusCode) {
            return (http, bytes)
        }

        let errData = try await readAllBytes(bytes)
        let outcome = HTTPErrorHandler.classify(
            status: http.statusCode,
            data: errData,
            requestPath: inRequest.url?.path ?? "?",
        )

        switch outcome {
        case .success:
            // Unreachable — guarded above.
            return (http, bytes)

        case let .auth(reason, message):
            logAuth01(reason: reason, message: message, endpoint: inRequest.url?.path ?? "?")
            // reauth_required (ADR 0023) bypasses silent retry — see perform().
            if reason == .reauthRequired {
                throw StirError.auth(reason: reason, message: message)
            }
            if !retriedAuth, let identity = lastBootstrapIdentity {
                _ = try await bootstrap(
                    installationID: identity.installationID,
                    cloudKitRecordName: identity.cloudKitRecordName,
                )
                return try await performStream(
                    request: inRequest,
                    retriedAuth: true,
                    retried5xx: retried5xx,
                )
            }
            throw StirError.auth(reason: reason, message: message)

        case let .validation(stirError, _):
            // Stream variant intentionally does NOT capture VAL-01 to Sentry —
            // matches pre-extraction behavior. perform() captures because its
            // request body is the most-likely culprit; stream callers
            // (dinner-solve) compose bodies that perform() already validated.
            throw stirError

        case let .retryable5xx(stirError):
            // SCA-297 (W5): give the stream variant ONE pre-stream-handoff
            // retry on 5xx. Previously the stream path threw immediately on
            // a single transient Gemini 502, while perform/performNoContent
            // retried 3x — asymmetric user-visible behavior for the same
            // upstream failure. One additional attempt is cheap (stream
            // hasn't started yielding bytes yet) and preserves dinner-solve
            // resilience when Gemini hiccups mid-handshake. The 0.5s backoff
            // matches `perform`'s attempt-0 step.
            Logger.supabase.warning(
                "5xx (stream) from \(inRequest.url?.path ?? "?", privacy: .public): status=\(http.statusCode)",
            )
            if !retried5xx {
                try await backoff(attempt: 0)
                return try await performStream(
                    request: inRequest,
                    retriedAuth: retriedAuth,
                    retried5xx: true,
                )
            }
            throw stirError

        case let .nonRetryableError(stirError),
             let .unexpectedStatus(stirError):
            // Stream's non-retryable buckets surface immediately.
            throw stirError
        }
    }

    private func readAllBytes(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var buffer = Data()
        let cap = 64 * 1024
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= cap { break } // safety cap on error bodies
        }
        if buffer.count >= cap {
            // SCA-297 (W6): visibility for the silent-truncation case. A
            // 64 KiB cap is fine for typed error envelopes (kilobytes at
            // most), but if it ever trips the downstream `classify` is
            // parsing an incomplete JSON tail — the .malformedResponse
            // path is taken silently. Logging at warning level surfaces
            // the truncation in Console.app + Sentry breadcrumbs.
            Logger.supabase.warning(
                "performStream error-body drained to cap (64 KiB) — body may be truncated, parsed error may be incomplete",
            )
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

        let outcome = HTTPErrorHandler.classify(
            status: http.statusCode,
            data: data,
            requestPath: request.url?.path ?? "?",
        )

        switch outcome {
        case .success:
            do {
                return try JSONDecoder.stir.decode(Response.self, from: data)
            } catch {
                Logger.supabase.error(
                    "decode failed (status=\(http.statusCode)): \(error.localizedDescription, privacy: .public)",
                )
                throw StirError.malformedResponse(description: error.localizedDescription)
            }

        case let .auth(reason, message):
            return try await handleAuthRetry(
                reason: reason,
                message: message,
                originalRequest: request,
                retriedAuth: retriedAuth,
            ) { retriedRequest in
                try await self.perform(retriedRequest, attempt: 0, retriedAuth: true)
            }

        case let .validation(stirError, sentryContext):
            Logger.supabase.error(
                "VAL-01 at \(request.url?.path ?? "?", privacy: .public): \(sentryContext["code"] ?? "VAL-01", privacy: .public)",
            )
            sentry.captureError(stirError, context: sentryContext)
            throw stirError

        case let .nonRetryableError(stirError):
            throw stirError

        case let .retryable5xx(stirError):
            Logger.supabase.warning(
                "5xx from \(request.url?.path ?? "?", privacy: .public): status=\(http.statusCode)",
            )
            if attempt < 3 {
                try await backoff(attempt: attempt)
                return try await perform(request, attempt: attempt + 1, retriedAuth: retriedAuth)
            }
            // SCA-297 (W4): retry-exhausted policy lives in a single helper so
            // perform + performNoContent stay in sync. Preserves the typed
            // server StirError as `underlying:` so Sentry breadcrumbs +
            // ErrorPresenter retain the upstream code (AI-01 vs INTERNAL-01)
            // rather than collapsing every retry-exhausted 5xx to bare
            // networkUnreachable.
            throw handleRetryExhausted(stirError: stirError)

        case let .unexpectedStatus(stirError):
            Logger.supabase.error(
                "unexpected status \(http.statusCode) from \(request.url?.path ?? "?", privacy: .public)",
            )
            throw stirError
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

        let outcome = HTTPErrorHandler.classify(
            status: http.statusCode,
            data: data,
            requestPath: request.url?.path ?? "?",
        )

        switch outcome {
        case .success:
            return

        case let .auth(reason, message):
            try await handleAuthRetryNoContent(
                reason: reason,
                message: message,
                originalRequest: request,
                retriedAuth: retriedAuth,
            )

        case let .validation(stirError, _):
            // performNoContent intentionally does not capture VAL-01 to
            // Sentry — matches pre-extraction behavior. Callers of the
            // no-content variant (voice-turn-usage) carry server-validated
            // bodies; a VAL-01 here is a programmer error worth surfacing
            // through the standard error pipeline.
            throw stirError

        case let .nonRetryableError(stirError):
            throw stirError

        case let .retryable5xx(stirError):
            Logger.supabase.warning(
                "5xx (no-content) from \(request.url?.path ?? "?", privacy: .public): status=\(http.statusCode)",
            )
            if attempt < 3 {
                try await backoff(attempt: attempt)
                try await performNoContent(request, attempt: attempt + 1, retriedAuth: retriedAuth)
                return
            }
            // SCA-297 (W4): shared retry-exhausted policy. See `perform`.
            throw handleRetryExhausted(stirError: stirError)

        case .unexpectedStatus:
            // Pre-extraction wording differed for no-content; preserve it so
            // callers parsing log strings (or Sentry breadcrumbs) keep working.
            throw StirError.malformedResponse(
                description: "unexpected no-content status \(http.statusCode)",
            )
        }
    }

    /// Shared AUTH-01 silent-retry execution. Logs the reason + handles the
    /// `reauth_required` short-circuit (ADR 0023) and the SCA-253 CK-token
    /// freshness guard, then re-bootstraps and retries via the variant's
    /// supplied closure. Used by `perform`; `performNoContent` calls a thin
    /// twin because the void-returning shape can't share a generic `T` with
    /// the typed-decode variant.
    private func handleAuthRetry<T>(
        reason: AuthReason,
        message: String,
        originalRequest: URLRequest,
        retriedAuth: Bool,
        retry: (URLRequest) async throws -> T,
    ) async throws -> T {
        logAuth01(reason: reason, message: message, endpoint: originalRequest.url?.path ?? "?")
        // reauth_required (ADR 0023) short-circuits the silent-retry path.
        // Admin used users.force_reauth and wants THIS user kicked — silent
        // re-bootstrap would issue a fresh JWT (iat > reauth_required_at)
        // and bypass the ceremony. Surface immediately so RootCoordinator
        // can route to SIWA re-flow.
        if reason == .reauthRequired {
            throw StirError.auth(reason: reason, message: message)
        }
        if retriedAuth {
            // Retry already consumed — surface.
            throw StirError.auth(reason: reason, message: message)
        }
        // Silent re-bootstrap + retry ONCE.
        guard let identity = lastBootstrapIdentity else {
            // No identity cached — caller must handle.
            throw StirError.auth(reason: reason, message: message)
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
        if identity.cloudKitRecordName != nil {
            let freshToken = await resolveCloudKitWebAuthToken(
                explicitToken: nil,
                cloudKitRecordName: identity.cloudKitRecordName,
            )
            if freshToken == nil {
                Logger.supabase.warning(
                    "silent re-bootstrap aborted: CK record claim cached but token provider returned nil; surfacing AUTH-01 to avoid identity-shift",
                )
                throw StirError.auth(reason: reason, message: message)
            }
        }
        _ = try await bootstrap(
            installationID: identity.installationID,
            cloudKitRecordName: identity.cloudKitRecordName,
        )
        // Rebuild the request with fresh JWT.
        var retried = originalRequest
        // SCA-311 S22: clear the Authorization header BEFORE the
        // `if let jwt = cachedJWT` rebind. The retried request inherits
        // `originalRequest`'s headers, which still carry the prior
        // (now-stale, just-401'd) JWT. If the post-bootstrap path
        // produces no fresh JWT (cachedJWT stayed nil — should not
        // happen, but defensive), reusing the stale header would
        // surface as another stale-`expired` 401 from PostgREST.
        // Stripping unconditionally means a JWT-less retry reaches
        // the server with no Authorization header at all, which
        // PostgREST surfaces as `reason=missing` — the correct
        // signal so RootCoordinator can route to SIWA re-flow.
        retried.setValue(nil, forHTTPHeaderField: "Authorization")
        if let jwt = cachedJWT {
            retried.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        }
        return try await retry(retried)
    }

    /// Void-returning twin of `handleAuthRetry` for `performNoContent`.
    /// Identical policy; separate signature so the no-content path doesn't
    /// allocate a wrapper for a discarded return value.
    private func handleAuthRetryNoContent(
        reason: AuthReason,
        message: String,
        originalRequest: URLRequest,
        retriedAuth: Bool,
    ) async throws {
        try await handleAuthRetry(
            reason: reason,
            message: message,
            originalRequest: originalRequest,
            retriedAuth: retriedAuth,
        ) { retried in
            try await self.performNoContent(retried, attempt: 0, retriedAuth: true)
        }
    }

    /// SCA-297 (W4): single source of truth for the retry-exhausted 5xx
    /// policy used by both `perform` and `performNoContent`. Preserves the
    /// upstream typed `StirError.server` as the `underlying:` so callers
    /// (Sentry breadcrumbs, ErrorPresenter routing, future telemetry)
    /// retain the original error code instead of collapsing to a bare
    /// `networkUnreachable(underlying: nil)`. Wire shape — `.networkUnreachable`
    /// — is preserved so the presenter layer's "offline UX" path still
    /// fires on retry-exhausted Gemini hiccups, matching pre-SCA-297 behavior.
    private nonisolated func handleRetryExhausted(stirError: StirError) -> StirError {
        return .networkUnreachable(underlying: stirError)
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
