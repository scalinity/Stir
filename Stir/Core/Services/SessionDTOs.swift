// SessionDTOs
//
// Wire-format types for /v1/session/bootstrap and /v1/config/bootstrap.
// Matches the step-1 Deno handler response shape exactly — do NOT drift
// without also updating Backend/supabase/functions/session-bootstrap and
// config-bootstrap handlers.
//
// Per Round-1 answer: bootstrap returns feature_flags as an array of
// {key, value, is_enabled, rollout_pct} objects. prompts[] is
// ONLY returned by /v1/config/bootstrap, not by /v1/session/bootstrap.

import Foundation

// MARK: - Request

struct BootstrapRequest: Encodable, Sendable, Equatable {
    let installationID: String
    let cloudKitUserRecordName: String?
    let cloudKitWebAuthToken: String?
    let build: String
    let osVersion: String

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case cloudKitUserRecordName = "cloudkit_user_record_name"
        case cloudKitWebAuthToken = "cloudkit_web_auth_token"
        case build
        case osVersion = "os_version"
    }
}

// MARK: - Response (bootstrap)

struct BootstrapResponse: Decodable, Sendable, Equatable {
    let sessionJWT: String
    let canonicalUserKey: String
    let isNewUser: Bool
    let entitlements: Entitlements
    let featureFlags: [FeatureFlag]

    enum CodingKeys: String, CodingKey {
        case sessionJWT = "session_jwt"
        case canonicalUserKey = "canonical_user_key"
        case isNewUser = "is_new_user"
        case entitlements
        case featureFlags = "feature_flags"
    }

    struct Entitlements: Decodable, Sendable, Equatable {
        let tier: Tier
        let billingState: BillingState
        let isTrial: Bool
        let expiresAt: Date?
        let voiceEnabled: Bool
        let billingRetryBanner: Bool
        let quotas: [Quota]

        enum CodingKeys: String, CodingKey {
            case tier
            case billingState = "billing_state"
            case isTrial = "is_trial"
            case expiresAt = "expires_at"
            case voiceEnabled = "voice_enabled"
            case billingRetryBanner = "billing_retry_banner"
            case quotas
        }
    }

    struct Quota: Decodable, Sendable, Equatable {
        let featureKey: FeatureKey
        let used: Int
        let cap: Int
        let periodEnd: String  // ISO date; iOS displays via DateFormatter

        enum CodingKeys: String, CodingKey {
            case featureKey = "feature_key"
            case used
            case cap
            case periodEnd = "period_end"
        }
    }

    struct FeatureFlag: Decodable, Sendable, Equatable {
        let key: String
        let value: FlagValue
        let isEnabled: Bool
        let rolloutPct: Int

        enum CodingKeys: String, CodingKey {
            case key
            case value
            case isEnabled = "is_enabled"
            case rolloutPct = "rollout_pct"
        }
    }
}

// MARK: - Response (config-bootstrap)

struct ConfigBootstrapResponse: Decodable, Sendable, Equatable {
    let entitlements: BootstrapResponse.Entitlements
    let featureFlags: [BootstrapResponse.FeatureFlag]
    let prompts: [Prompt]

    enum CodingKeys: String, CodingKey {
        case entitlements
        case featureFlags = "feature_flags"
        case prompts
    }

    struct Prompt: Decodable, Sendable, Equatable {
        let featureKey: String
        let version: String
        let providerModel: String
        let schemaHash: String
        let isDefault: Bool
        let isEnabled: Bool

        enum CodingKeys: String, CodingKey {
            case featureKey = "feature_key"
            case version
            case providerModel = "provider_model"
            case schemaHash = "schema_hash"
            case isDefault = "is_default"
            case isEnabled = "is_enabled"
        }
    }
}

// MARK: - Error response

struct ErrorResponseBody: Decodable, Sendable, Equatable {
    let error: String          // ErrorCode rawValue
    let message: String
    let fieldErrors: [FieldError]?
    let reason: String?        // AUTH-01 reason

    enum CodingKeys: String, CodingKey {
        case error
        case message
        case fieldErrors = "field_errors"
        case reason
    }
}

// MARK: - Flag value

/// Union type for `feature_flags[].value`. The wire format can carry bool,
/// string, number, or null; this enum decodes to the richest non-null type.
enum FlagValue: Decodable, Sendable, Equatable {
    case null
    case bool(Bool)
    case string(String)
    case int(Int)
    case double(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self)  { self = .bool(b); return }
        if let i = try? container.decode(Int.self)   { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .double(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "FlagValue: not bool/int/double/string/null",
        )
    }

    /// Convenience extractors.
    var boolValue: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    var stringValue: String? { if case let .string(s) = self { return s } else { return nil } }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
}
