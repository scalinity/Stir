// SentryReporter
//
// Real SentrySDK-backed `SentryReporting` implementation, swapped in by
// StirApp.init() when `AppConfig.sentry` is populated. Falls back to
// NoOpSentryReporter when Sentry DSN is absent (dev without a DSN, tests).
//
// Identity tagging: always `canonical_user_key_hash` (16-char SHA-256),
// never the raw canonical key. Respects spec §11 redaction requirement.

import Foundation
import OSLog
import Sentry

final class SentryReporter: SentryReporting, @unchecked Sendable {
    static let shared = SentryReporter()
    private var isInitialized = false

    private init() {}

    /// Initialize the Sentry SDK. Idempotent — second call is a no-op.
    func initialize(dsn: String, release: String, environment: String = "development") {
        guard !isInitialized else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = release
            options.environment = environment
            options.enableAutoPerformanceTracing = true
            options.enableAutoSessionTracking = true
            options.enableAppHangTrackingV2 = true
            // Minimal PII: no raw user text, no request bodies (spec §11
            // redaction). Send only structured errors + stack traces.
            options.sendDefaultPii = false
        }
        isInitialized = true
        Logger.telemetry.info("sentry initialized (release=\(release, privacy: .public))")
    }

    /// Attach the canonical-key hash as the Sentry user context. No PII.
    func setUserContext(keyHash: String) {
        guard isInitialized else { return }
        let user = Sentry.User()
        user.userId = keyHash
        SentrySDK.setUser(user)
    }

    // MARK: - SentryReporting conformance

    func captureError(_ error: any Error, context: [String: String]) {
        guard isInitialized else { return }
        SentrySDK.capture(error: error) { scope in
            for (k, v) in context {
                scope.setTag(value: v, key: k)
            }
        }
    }

    func breadcrumb(category: String, message: String, data: [String: String]) {
        guard isInitialized else { return }
        let breadcrumb = Breadcrumb(level: .info, category: category)
        breadcrumb.message = message
        breadcrumb.data = data
        SentrySDK.addBreadcrumb(breadcrumb)
    }
}
