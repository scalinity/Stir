// SharedStorage
//
// Thin wrapper over the App Group UserDefaults shared between the main
// app, StirWidgets, and StirShareExtension. Lives in `Shared/` and is
// compiled into every target that needs cross-process reads/writes.
//
// What lives here:
//   - TonightSnapshot — the latest SuggestedDish trio (widget render)
//   - Tier string — "free" | "premium" | "pro" for widget Premium gating
//     without a round-trip to Supabase from the extension process
//
// What does NOT live here:
//   - Session JWTs, PII, recipe detail, CloudKit record names
//   - Anything that would duplicate CloudKit's authoritative store
//
// Staleness: the widget process has no network; every render reflects
// the last write from the main app. SolveViewModel writes on solve
// completion; EntitlementService writes tier on bootstrap / webhook
// refresh. WidgetCenter.reloadAllTimelines() is called from the main
// app after each write so the widget pulls fresh values immediately.

import Foundation

public struct SharedStorage: @unchecked Sendable {
    private let defaults: UserDefaults

    /// Suite-backed init. Falls back to `.standard` if the app group
    /// isn't yet configured (tests, bootstrap path). Production builds
    /// MUST have the group registered — the widget can't read without it.
    public init(suiteName: String = AppGroup.identifier) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// Injection seam for unit tests. Production callers use `init()`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    // MARK: - TonightSnapshot

    private static let tonightKey = "stir.tonight.snapshot.v1"

    public func writeTonight(_ snapshot: TonightSnapshot?) {
        guard let snapshot else {
            defaults.removeObject(forKey: Self.tonightKey)
            return
        }
        if let data = try? Self.encoder().encode(snapshot) {
            defaults.set(data, forKey: Self.tonightKey)
        }
    }

    public func readTonight() -> TonightSnapshot? {
        guard let data = defaults.data(forKey: Self.tonightKey) else { return nil }
        return try? Self.decoder().decode(TonightSnapshot.self, from: data)
    }

    // MARK: - Tier (widget Premium gating)

    private static let tierKey = "stir.user.tier.v1"

    public func writeTier(_ tier: String) {
        defaults.set(tier, forKey: Self.tierKey)
    }

    public func readTier() -> String? {
        defaults.string(forKey: Self.tierKey)
    }

    // MARK: - Canonical user key (share-extension user binding)

    /// Main app writes the active canonical_user_key at bootstrap so the
    /// share extension — which has no Supabase access — can bind a
    /// PendingImport to a specific user (CWE-345 defense against
    /// cross-iCloud-account payload bleed).
    private static let canonicalUserKeyKey = "stir.user.canonicalKey.v1"

    public func writeCanonicalUserKey(_ key: String?) {
        if let key {
            defaults.set(key, forKey: Self.canonicalUserKeyKey)
        } else {
            defaults.removeObject(forKey: Self.canonicalUserKeyKey)
        }
    }

    public func readCanonicalUserKey() -> String? {
        defaults.string(forKey: Self.canonicalUserKeyKey)
    }

    // MARK: - Widget first-seen (Retention funnel — widget_added emission)

    /// Widget process writes the timestamp of the first timeline fetch.
    /// Main app drains on foreground to emit the `widget_added` product
    /// event exactly once per installation (spec §15 Retention funnel).
    /// Returning nil means "already drained or never seen."
    private static let widgetFirstSeenKey = "stir.widget.firstSeenAt.v1"

    /// Widget-side writer. Idempotent: writes only if the key isn't
    /// already set, so subsequent timeline refreshes don't bump the
    /// timestamp (which would break "first seen" semantics).
    public func markWidgetFirstSeenIfNeeded(now: Date = Date()) {
        if defaults.object(forKey: Self.widgetFirstSeenKey) != nil { return }
        defaults.set(now.timeIntervalSince1970, forKey: Self.widgetFirstSeenKey)
    }

    /// Main-app-side drain. Reads the timestamp and clears the key in
    /// one hop — subsequent calls return nil so the widget_added event
    /// never double-fires for the same installation.
    public func drainWidgetFirstSeen() -> Date? {
        guard defaults.object(forKey: Self.widgetFirstSeenKey) != nil else { return nil }
        let ts = defaults.double(forKey: Self.widgetFirstSeenKey)
        defaults.removeObject(forKey: Self.widgetFirstSeenKey)
        return Date(timeIntervalSince1970: ts)
    }

    // MARK: - PendingImport (share extension queue)

    private static let pendingImportKey = "stir.pendingImport.v1"

    public func writePendingImport(_ pending: PendingImport?) {
        guard let pending else {
            defaults.removeObject(forKey: Self.pendingImportKey)
            return
        }
        if let data = try? Self.encoder().encode(pending) {
            defaults.set(data, forKey: Self.pendingImportKey)
        }
    }

    public func readPendingImport() -> PendingImport? {
        guard let data = defaults.data(forKey: Self.pendingImportKey) else { return nil }
        return try? Self.decoder().decode(PendingImport.self, from: data)
    }

    /// Atomically read + clear. Used by the main app on foreground to
    /// process the extension's queued entry without risking a replay
    /// on a subsequent foreground.
    public func consumePendingImport() -> PendingImport? {
        let pending = readPendingImport()
        if pending != nil {
            writePendingImport(nil)
        }
        return pending
    }

    /// User-scoped consume: drops the payload if its `consumingUserKey`
    /// doesn't match `currentUserKey` (user signed out + into a
    /// different iCloud account between share + re-open). Returns nil
    /// for mismatched or absent payloads; caller can treat that as "no
    /// pending import" — the drop is silent from the user's POV apart
    /// from an optional toast surfaced by the caller. Legacy payloads
    /// written before the consumingUserKey field existed are accepted
    /// (nil == unbound == same-user) for one-release back-compat.
    public func consumePendingImport(currentUserKey: String?) -> PendingImport? {
        guard let pending = readPendingImport() else { return nil }
        // Always clear so a second-foreground doesn't replay. Even if
        // we reject this payload the slot is now free for the next
        // share.
        writePendingImport(nil)
        if let bound = pending.consumingUserKey,
           let currentUserKey,
           bound != currentUserKey {
            return nil
        }
        return pending
    }

    // MARK: - Debug

    /// Clear all shared keys. Used on sign-out / delete account and in
    /// tests between cases.
    public func clearAll() {
        defaults.removeObject(forKey: Self.tonightKey)
        defaults.removeObject(forKey: Self.tierKey)
        defaults.removeObject(forKey: Self.canonicalUserKeyKey)
        defaults.removeObject(forKey: Self.widgetFirstSeenKey)
        defaults.removeObject(forKey: Self.pendingImportKey)
    }

    // MARK: - Coders
    //
    // Inline, cross-target. The main app has a richer `JSONEncoder.stir`
    // in SupabaseSessionClient with Postgres-timestamp tolerance, but
    // that path is main-app-only; the widget target sees only what's
    // in `Shared/`. Snapshot payloads use plain ISO8601 which both
    // encoders handle cleanly.

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
