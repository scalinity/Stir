// FlagOutputService — POSTs /v1/ops/flag-output from iOS.
//
// Wraps SupabaseSessionClient so the existing AUTH-01 silent retry + 5xx
// backoff apply. Called from CookModeRoot's "Report issue" overflow menu
// item + SubstitutionSheet's result view (step 8 scope).
//
// Dedup is server-side: same user + same request_id within 24h returns the
// existing flag id with dedup=true — iOS UX shows the same "Thanks — this
// helps us improve" confirmation regardless, so users don't learn whether
// their report was new or a retry.

import Foundation
import OSLog

actor FlagOutputService {
    private let session: SupabaseSessionClient
    private let config: AppConfig

    init(session: SupabaseSessionClient, config: AppConfig) {
        self.session = session
        self.config = config
    }

    /// Feature keys accepted by the backend. Mirror of zod enum in
    /// Backend/supabase/functions/ops-flag-output/index.ts.
    enum FeatureKey: String, Sendable {
        case dinnerSolve = "dinner_solve"
        case substitution
        case cookTurn = "cook_turn"
        case recipeImport = "recipe_import"
        case pantryParse = "pantry_parse"
        case groceryGenerate = "grocery_generate"
        case cookModeRealtime = "cook_mode_realtime"
    }

    struct FlagOutputRequest: Encodable, Sendable {
        let featureKey: FeatureKey
        let requestID: String
        let flagReason: String
        let contextSnapshot: [String: AnyEncodable]?

        enum CodingKeys: String, CodingKey {
            case featureKey = "feature_key"
            case requestID = "request_id"
            case flagReason = "flag_reason"
            case contextSnapshot = "context_snapshot"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(featureKey.rawValue, forKey: .featureKey)
            try c.encode(requestID, forKey: .requestID)
            try c.encode(flagReason, forKey: .flagReason)
            try c.encodeIfPresent(contextSnapshot, forKey: .contextSnapshot)
        }
    }

    struct FlagOutputResponse: Decodable, Sendable {
        let ok: Bool
        let flaggedOutputID: String
        let dedup: Bool

        enum CodingKeys: String, CodingKey {
            case ok
            case flaggedOutputID = "flagged_output_id"
            case dedup
        }
    }

    /// Submit a user-initiated flag. Throws `StirError.auth` on session
    /// failures (caller should re-bootstrap); `StirError.validation` on
    /// empty/oversize reason; network errors bubble as `StirError.network`.
    func flagOutput(
        featureKey: FeatureKey,
        requestID: String,
        flagReason: String,
        contextSnapshot: [String: AnyEncodable]? = nil,
    ) async throws -> FlagOutputResponse {
        // Client-side validation matches the server's zod schema (1..500
        // chars) so we fail loudly before round-trip rather than with a
        // VAL-01 after.
        let trimmed = flagReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StirError.validation(fieldErrors: [], message: "flag reason cannot be empty")
        }
        guard trimmed.count <= 500 else {
            throw StirError.validation(
                fieldErrors: [],
                message: "flag reason exceeds 500 chars (\(trimmed.count))",
            )
        }

        let body = FlagOutputRequest(
            featureKey: featureKey,
            requestID: requestID,
            flagReason: trimmed,
            contextSnapshot: contextSnapshot,
        )
        let url = config.supabase.url.appendingPathComponent("/functions/v1/ops-flag-output")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        request.addValue("application/json", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder.stir.encode(body)

        Logger.flagOutput.info(
            "flag_output_dispatch feature=\(featureKey.rawValue, privacy: .public) request_id=\(requestID, privacy: .public)",
        )
        let response: FlagOutputResponse = try await session.performAuthenticated(request)
        Logger.flagOutput.info(
            "flag_output_complete id=\(response.flaggedOutputID, privacy: .public) dedup=\(response.dedup, privacy: .public)",
        )
        return response
    }
}

// Small type-erased Encodable wrapper for the heterogeneous context_snapshot
// map. Lets callers pass { "recipe_plan_id": uuid, "step_index": 3 } without
// a bespoke struct per feature.
struct AnyEncodable: Encodable, Sendable {
    private let _encode: @Sendable (Encoder) throws -> Void
    init<T: Encodable & Sendable>(_ value: T) {
        self._encode = { encoder in try value.encode(to: encoder) }
    }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }
}

// Logger subsystem tag. Added here so the existing Logger pattern keeps the
// subsystem-by-file convention without growing Utilities/Logging.
extension Logger {
    static let flagOutput = Logger(subsystem: "app.stir", category: "flag-output")
}
