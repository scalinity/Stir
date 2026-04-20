// SentryReporting
//
// Abstraction over Sentry capture. Step 5 (this commit) uses the NoOp impl
// because Sentry SDK isn't initialized until commit 9. Once StirApp.init
// calls `SentrySDK.start(...)`, replace the injected instance with
// `SentryReporter` (concrete impl in Stir/Integrations/Sentry/ — commit 9).
//
// Injection is structured so SupabaseSessionClient can emit VAL-01 /
// AUTH-01 severity events without knowing whether Sentry is live.

import Foundation

protocol SentryReporting: Sendable {
    /// Capture an error at `error` severity. `context` is a free-form tag bag
    /// (e.g., `["feature": "bootstrap", "canonical_key_hash": "<hex>"]`).
    func captureError(_ error: any Error, context: [String: String])

    /// Record a breadcrumb (not a captured event) for timeline context.
    func breadcrumb(category: String, message: String, data: [String: String])

    /// Bind the session's user context to the canonical-key hash.
    /// Protocol-level so tests + the NoOp path participate. Prior code
    /// downcast to the concrete `SentryReporter`, which silently skipped
    /// identity tagging in any non-prod wiring.
    func setUserContext(keyHash: String)
}

struct NoOpSentryReporter: SentryReporting {
    func captureError(_ error: any Error, context: [String: String]) {
        // Intentional no-op. OSLog is the fallback until commit 9 wires the
        // real Sentry-backed instance. Keeping this silent avoids logging
        // the same error twice.
    }

    func breadcrumb(category: String, message: String, data: [String: String]) {
        // no-op
    }

    func setUserContext(keyHash: String) {
        // no-op
    }
}
