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

    // MARK: - Debug

    /// Clear all shared keys. Used on sign-out / delete account and in
    /// tests between cases.
    public func clearAll() {
        defaults.removeObject(forKey: Self.tonightKey)
        defaults.removeObject(forKey: Self.tierKey)
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
