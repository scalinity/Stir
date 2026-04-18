// AppConfig
//
// Typed accessor for build-time configuration flowing from `Config.xcconfig`
// through Info.plist `$(VAR)` substitution into the running bundle. Loaded
// once at launch (commit 9 calls `AppConfig.load()` in `StirApp`) and passed
// to services via SwiftUI environment.
//
// Supabase values are REQUIRED — missing them is a fatal configuration error
// that surfaces as a user-visible "app not configured" screen rather than a
// crash. PostHog/Sentry/RevenueCat are OPTIONAL — if absent, the corresponding
// SDK just isn't initialized (degrading gracefully into OSLog-only).

import Foundation

struct AppConfig: Sendable, Equatable {
    struct Supabase: Sendable, Equatable {
        let url: URL
        let anonKey: String
    }

    struct PostHog: Sendable, Equatable {
        let apiKey: String
        /// Defaults to the PostHog US host. Override via Info.plist `PostHogHost`
        /// if a project is provisioned in the EU cloud.
        let host: URL
    }

    struct Sentry: Sendable, Equatable {
        let dsn: String
    }

    struct RevenueCat: Sendable, Equatable {
        let publicAPIKey: String
    }

    let supabase: Supabase
    let posthog: PostHog?
    let sentry: Sentry?
    let revenueCat: RevenueCat?

    /// Build identifier surfaced in telemetry + the bootstrap body.
    /// Format: "<CFBundleShortVersionString> (<CFBundleVersion>)".
    let build: String

    /// iOS version string at launch, surfaced in telemetry + bootstrap body.
    let osVersion: String
}

extension AppConfig {
    static func load(from bundle: Bundle = .main) throws -> AppConfig {
        let info = bundle.infoDictionary ?? [:]

        // --- Supabase (required) ---
        let rawUrl = try Self.requireString(
            info, key: "SupabaseURL", missing: .missingSupabaseURL,
        )
        // Guard against shipping placeholder Config.xcconfig values (accidental
        // leak of Config.xcconfig.example content). Any value that equals
        // `$(VAR_NAME)` literal means the build-time substitution didn't resolve.
        if rawUrl.hasPrefix("$(") { throw AppConfigError.unresolvedPlaceholder("SupabaseURL") }
        guard let url = URL(string: rawUrl), url.scheme != nil else {
            throw AppConfigError.invalidSupabaseURL(rawUrl)
        }

        let anonKey = try Self.requireString(
            info, key: "SupabaseAnonKey", missing: .missingSupabaseAnonKey,
        )
        if anonKey.hasPrefix("$(") { throw AppConfigError.unresolvedPlaceholder("SupabaseAnonKey") }

        // --- PostHog (optional, but populated in prod per CLAUDE.md) ---
        let posthog: PostHog? = {
            let key = Self.optionalString(info, key: "PostHogPublicAPIKey")
            guard let key, !key.hasPrefix("$("), !key.isEmpty else { return nil }
            let hostString = Self.optionalString(info, key: "PostHogHost")
                ?? "https://us.i.posthog.com"
            guard let host = URL(string: hostString) else { return nil }
            return PostHog(apiKey: key, host: host)
        }()

        // --- Sentry (optional) ---
        let sentry: Sentry? = {
            let dsn = Self.optionalString(info, key: "SentryDSNPublic")
            guard let dsn, !dsn.hasPrefix("$("), !dsn.isEmpty else { return nil }
            return Sentry(dsn: dsn)
        }()

        // --- RevenueCat (optional; step 5 activates) ---
        let revenueCat: RevenueCat? = {
            let key = Self.optionalString(info, key: "RevenueCatPublicAPIKey")
            guard let key, !key.hasPrefix("$("), !key.isEmpty else { return nil }
            return RevenueCat(publicAPIKey: key)
        }()

        // --- Build metadata ---
        let short = Self.optionalString(info, key: "CFBundleShortVersionString") ?? "0.0.0"
        let bundleVersion = Self.optionalString(info, key: "CFBundleVersion") ?? "0"
        let build = "\(short) (\(bundleVersion))"

        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString

        return AppConfig(
            supabase: Supabase(url: url, anonKey: anonKey),
            posthog: posthog,
            sentry: sentry,
            revenueCat: revenueCat,
            build: build,
            osVersion: osVersion,
        )
    }

    private static func requireString(
        _ info: [String: Any],
        key: String,
        missing: AppConfigError,
    ) throws -> String {
        guard let value = info[key] as? String, !value.isEmpty else {
            throw missing
        }
        return value
    }

    private static func optionalString(_ info: [String: Any], key: String) -> String? {
        guard let value = info[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}

// ASSUMPTION: Info.plist → AppConfig is the single config-loading mechanism.
// No UserDefaults fallback, no .env.local file, no hidden env var override.
// If Config.xcconfig isn't populated, the app refuses to launch with a
// clear diagnostic rather than limping along with defaults. Flag if wrong.

enum AppConfigError: Error, Equatable, Sendable {
    case missingSupabaseURL
    case invalidSupabaseURL(String)
    case missingSupabaseAnonKey
    case unresolvedPlaceholder(String)
}

extension AppConfigError: CustomStringConvertible {
    var description: String {
        switch self {
        case .missingSupabaseURL:
            return "SupabaseURL missing from Info.plist — check Config.xcconfig is populated."
        case .invalidSupabaseURL(let raw):
            return "SupabaseURL is not a valid URL: \(raw)"
        case .missingSupabaseAnonKey:
            return "SupabaseAnonKey missing from Info.plist — check Config.xcconfig is populated."
        case .unresolvedPlaceholder(let key):
            return "\(key) still contains `$(…)` — xcconfig substitution failed. Check Config.xcconfig has no typos in the key name."
        }
    }
}

