// OSLog Loggers for Stir.
//
// One Logger per subsystem/category so Console.app and Instruments filter cleanly.
// CLAUDE.md §"Working-with-Daniel rules": no `print()`, ever.
//
// Usage:
//   Logger.identity.info("canonical key resolved: \(keyHash, privacy: .public)")
//   Logger.supabase.error("bootstrap failed: \(error.localizedDescription)")
//
// Privacy semantics: never emit raw canonical_user_key or JWT content.
// Always hash canonical_user_key via `CanonicalKeyHash` before logging.

import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.scalinity.stir"

    /// App-lifecycle events (launch, foreground, background, termination).
    static let app = Logger(subsystem: subsystem, category: "app")

    /// RootCoordinator routing decisions.
    static let coordinator = Logger(subsystem: subsystem, category: "coordinator")

    /// IdentityService (CloudKit account status + Keychain install UUID).
    static let identity = Logger(subsystem: subsystem, category: "identity")

    /// EntitlementService (tier / billing_state / quotas).
    static let entitlement = Logger(subsystem: subsystem, category: "entitlement")

    /// SupabaseSessionClient (bootstrap, config-bootstrap, AUTH-01 retry).
    static let supabase = Logger(subsystem: subsystem, category: "supabase")

    /// Core Data + NSPersistentCloudKitContainer.
    static let coreData = Logger(subsystem: subsystem, category: "coredata")

    /// CloudKit integration layer (account changes, sync state).
    static let cloudKit = Logger(subsystem: subsystem, category: "cloudkit")

    /// Telemetry (PostHog emission + Sentry breadcrumbs).
    static let telemetry = Logger(subsystem: subsystem, category: "telemetry")

    /// Onboarding flow events.
    static let onboarding = Logger(subsystem: subsystem, category: "onboarding")

    /// Configuration loading (AppConfig).
    static let config = Logger(subsystem: subsystem, category: "config")

    /// UI-layer events — Cook Mode, timers, sheets. Step 4.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
