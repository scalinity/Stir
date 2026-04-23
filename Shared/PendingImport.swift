// PendingImport
//
// App Group queue entry dropped by StirShareExtension and picked up
// by the main Stir app on next foreground. Extensions run in their
// own short-lived process; rather than plumb the full AIDispatch +
// session-auth stack into the extension bundle, the extension writes
// a tiny payload here and the main app processes it with its
// already-warm auth state.
//
// Flow:
//   Safari → Share → Stir     (extension writes PendingImport)
//   system brings user home  (extension is 2–5s of friction)
//   user reopens Stir         (.active foreground in RootView)
//   main app reads pending    (ImportViewModel handles submit)
//   RecipePlan lands in Saved
//
// Single-slot queue — we keep only the latest share. If the user
// shares two recipes before re-opening Stir, the second overwrites.
// Queueing multiple requires a real task queue which is out of v1
// scope; the UX is "share the one you actually want to cook."

import Foundation

public struct PendingImport: Codable, Sendable, Equatable, Identifiable {
    /// Stable UUID assigned at share-time. Replaces the prior Date-based
    /// id — Date had millisecond precision but could collide in the
    /// rare "two shares, same millisecond" case and leaked timing info
    /// into SwiftUI diagnostics.
    public let id: UUID

    /// URL shared from Safari / Reader / browser extension. Mutually
    /// exclusive with `text` at the source level but we tolerate both
    /// being present if iOS hands them over.
    public let url: String?
    /// Plain-text shared payload (Notes → Share → Stir, etc.).
    public let text: String?
    /// Wall-clock time the extension wrote this. Main app uses this
    /// to surface "just now" copy and to reject entries older than a
    /// few hours (avoid zombie re-import if the user somehow never
    /// returned to Stir after sharing).
    public let capturedAt: Date
    /// canonical_user_key of the account active in the main app at
    /// share time. The main app's consume path compares this against
    /// the current bootstrap identity; mismatch → drop with a toast
    /// so a share doesn't cross-user-bleed into a different iCloud
    /// account (SA2-10, CWE-345). Nil is legal for legacy payloads
    /// written before this field existed; those fall through to the
    /// current-user path to stay back-compat during upgrade.
    public let consumingUserKey: String?

    public init(
        id: UUID = UUID(),
        url: String?,
        text: String?,
        capturedAt: Date,
        consumingUserKey: String? = nil,
    ) {
        self.id = id
        self.url = url
        self.text = text
        self.capturedAt = capturedAt
        self.consumingUserKey = consumingUserKey
    }

    /// Returns the more specific source type implied by the payload.
    /// URL wins when both are present (Safari's share-to-Stir ships
    /// both a URL and a fallback text representation; URL is authoritative).
    public var impliedSource: String {
        if let url, !url.isEmpty { return "share_sheet" }
        return "pasted_text"
    }

    public var displayLabel: String {
        if let url, !url.isEmpty { return url }
        if let text, !text.isEmpty { return String(text.prefix(80)) }
        return ""
    }
}
