// EntitlementService
//
// THE source of truth for `tier`, `billingState`, `voiceEnabled`, and the
// three metered quotas. Never read tier/billing state directly from the
// bootstrap response body or from Core Data — always go through the
// observable service so views get automatic redraws on changes.
//
// Contract per step-2 prompt:
//   - Hydrate from `/v1/session/bootstrap` response on app launch +
//     foreground.
//   - Expose `canAccess(_ gate: FeatureGate) -> EntitlementDecision` and
//     let every feature gate in the UI consult this.
//   - Keychain-backed 24h snapshot for offline fallback when bootstrap fails.
//
// @Observable + @MainActor rather than actor so SwiftUI views get
// synchronous property access on the main thread. Writes go through
// `hydrate()` which is also MainActor-bound.

import Foundation
import Observation
import OSLog

enum FeatureGate: String, Sendable, CaseIterable {
    /// Premium+ voice Cook Mode.
    case voiceCookMode
    /// Premium+ saved favorites (one-tap recipes).
    case savedFavorites
    /// Premium+ Home Screen widget.
    case widgets
    /// Premium+ App Intents / Shortcuts.
    case shortcutsAppIntents
    /// Premium+ leftovers mode.
    case leftoversMode
    /// Pro multi-image scan (single-image scan unmetered for all tiers).
    case multiImageScan
    /// Pro priority inference queue.
    case priorityInferenceQueue
    /// Dinner Solve (metered).
    case dinnerSolve
    /// Recipe Import (metered).
    case recipeImport
}

enum EntitlementDecision: Equatable, Sendable {
    case allowed
    case blockedByTier(required: Tier)
    case blockedByQuota(feature: FeatureKey, used: Int, cap: Int, resetDate: Date?)
    case blockedByBilling(BillingState)
}

@MainActor
@Observable
final class EntitlementService {
    struct QuotaSnapshot: Codable, Sendable, Equatable {
        let used: Int
        let cap: Int
        /// ISO-8601 date string of the period boundary; decoded to Date at hydrate.
        let periodEnd: String

        var periodEndDate: Date? {
            ISO8601DateFormatter.stirWithoutFractional.date(from: periodEnd)
                ?? ISO8601DateFormatter.stirWithFractional.date(from: periodEnd)
                ?? EntitlementService.datePeriodFormatter.date(from: periodEnd)
        }

        var remaining: Int { max(0, cap - used) }
    }

    enum HydrationState: Sendable, Equatable {
        case loading
        case hydrated(source: Source)
        case failed

        enum Source: String, Codable, Sendable, Equatable {
            case bootstrap
            case cachedSnapshot = "cached_snapshot"
        }
    }

    private(set) var tier: Tier = .free
    private(set) var billingState: BillingState = .none
    private(set) var isTrial: Bool = false
    private(set) var expiresAt: Date? = nil
    private(set) var voiceEnabled: Bool = false
    /// Matches backend `billing_retry_banner` (CLAUDE.md §bootstrap response
    /// shape). iOS surfaces this when Apple is retrying a failed renewal and
    /// the user still has paid access in the grace window.
    private(set) var billingRetryBanner: Bool = false
    /// SCA-100: server-shipped standing-pantry-cap. Required on the
    /// wire post-SCA-207 — `BootstrapResponse.Entitlements.standingPantryCap`
    /// is now non-optional. Default `25` (Free panic value) covers the
    /// pre-first-hydrate window only; a real bootstrap response always
    /// overwrites this.
    private(set) var serverStandingPantryCap: Int = 25
    private(set) var quotas: [FeatureKey: QuotaSnapshot] = [:]
    private(set) var featureFlags: [String: BootstrapResponse.FeatureFlag] = [:]
    private(set) var hydrationState: HydrationState = .loading

    /// Timestamp of the most recent server-confirmed hydrate (`hydrate(...)`).
    /// Cached-snapshot restores do NOT update this — only fresh bootstrap /
    /// configBootstrap responses do. Drives the launch-path skip in
    /// `RootCoordinator.refreshEntitlementsIfStale` so the scenePhase .active
    /// observer doesn't re-hit `/v1/config/bootstrap` immediately after the
    /// launch `/v1/session/bootstrap` already hydrated the same data.
    private(set) var lastHydratedAt: Date?

    /// Convenience for bool-valued feature flags like `disable_scan_parse`.
    /// Respects is_enabled: a disabled flag always returns nil so callers
    /// fall back to default behavior.
    func flagBool(forKey key: String) -> Bool? {
        guard let flag = featureFlags[key], flag.isEnabled else { return nil }
        return flag.value.boolValue
    }

    private let keychain: any KeychainStoring

    // MARK: - Init

    init(keychain: any KeychainStoring = KeychainStorage.shared) {
        self.keychain = keychain
        // Attempt to re-hydrate from the last-known-good cached snapshot.
        // If bootstrap succeeds soon, it'll overwrite this.
        restoreFromCachedSnapshotIfFresh()
    }

    // MARK: - Hydrate

    func hydrate(
        from entitlements: BootstrapResponse.Entitlements,
        flags: [BootstrapResponse.FeatureFlag] = [],
    ) {
        self.tier = entitlements.tier
        self.billingState = entitlements.billingState
        self.isTrial = entitlements.isTrial
        self.expiresAt = entitlements.expiresAt
        self.voiceEnabled = entitlements.voiceEnabled
        self.billingRetryBanner = entitlements.billingRetryBanner
        self.serverStandingPantryCap = entitlements.standingPantryCap
        // Mirror the tier into the App Group so StirWidgets can gate
        // Premium content without a Supabase round-trip from the widget
        // process. Written on every hydrate so webhook/tier-change
        // refreshes propagate to the widget surface within one bootstrap.
        SharedStorage().writeTier(entitlements.tier.rawValue)

        var map: [FeatureKey: QuotaSnapshot] = [:]
        for quota in entitlements.quotas {
            map[quota.featureKey] = QuotaSnapshot(
                used: quota.used, cap: quota.cap, periodEnd: quota.periodEnd,
            )
        }
        self.quotas = map
        self.featureFlags = Dictionary(uniqueKeysWithValues: flags.map { ($0.key, $0) })
        self.hydrationState = .hydrated(source: .bootstrap)
        self.lastHydratedAt = Date()

        persistSnapshot()
        Logger.entitlement.info(
            "hydrated tier=\(self.tier.rawValue, privacy: .public) billing=\(self.billingState.rawValue, privacy: .public) voice=\(self.voiceEnabled, privacy: .public) flags=\(flags.count, privacy: .public)",
        )
    }

    /// Mark hydration as failed when bootstrap itself errors out (NET-01).
    /// Views that care render the degraded-mode banner; feature gates use
    /// whatever snapshot we had (free-tier defaults if nothing cached).
    func markHydrationFailed() {
        self.hydrationState = .failed
        Logger.entitlement.warning("entitlement hydration failed — using cached snapshot or Free defaults")
    }

    // MARK: - canAccess

    /// Demote to free for `expired` AND `none`. Server's effectiveTier()
    /// (entitlements.ts) does the same — iOS must match so a stale
    /// Keychain snapshot with (tier=.premium, billingState=.none) can't
    /// silently hand out paid features. This is a defensive guard: in
    /// normal flow RC would never leave tier=.premium while
    /// billing_state=.none, but keychain snapshots from earlier builds
    /// or hand-edited test states could produce it. Hoisted to a
    /// computed property so every entitlement decision (`canAccess`,
    /// `rememberedPantryCap`, future tier-gated extensions) consumes
    /// one definition — divergence here is the exact bug class the
    /// stale-snapshot defense exists to prevent.
    var effectiveTier: Tier {
        switch billingState {
        case .expired, .none: return .free
        default:              return tier
        }
    }

    func canAccess(_ gate: FeatureGate) -> EntitlementDecision {
        switch gate {
        // Premium-tier gates
        case .voiceCookMode:
            // Honor the server-computed `voiceEnabled` flag per CLAUDE.md
            // rule "Don't derive `voice_enabled` on iOS." Prior code tier-
            // checked directly here, which diverged from the server and
            // broke ADR-0008 (voice temporarily free for testing).
            if !voiceEnabled { return .blockedByTier(required: .premium) }
            // Defensive guard: require cap > 0 before quota-blocking. A
            // stale cached snapshot with cap=0 (e.g. from a pre-ADR-0008
            // bootstrap) would otherwise make `0 >= 0` trip the quota
            // paywall even though no sessions have been used. Server-side
            // comment in readQuotasForWire flags this exact footgun.
            if let quota = quotas[.voiceCookSession], quota.cap > 0, quota.used >= quota.cap {
                return .blockedByQuota(
                    feature: .voiceCookSession,
                    used: quota.used, cap: quota.cap,
                    resetDate: quota.periodEndDate,
                )
            }
            return .allowed

        case .savedFavorites, .widgets, .shortcutsAppIntents, .leftoversMode:
            if effectiveTier == .free { return .blockedByTier(required: .premium) }
            return .allowed

        // Pro-tier gates
        case .multiImageScan, .priorityInferenceQueue:
            if effectiveTier != .pro { return .blockedByTier(required: .pro) }
            return .allowed

        // Metered (no tier gate — Free users get a small monthly allotment).
        // Same `cap > 0` guard as voiceCookMode: stale cached snapshots
        // with cap=0 would otherwise block with `0 >= 0`.
        case .dinnerSolve:
            if let quota = quotas[.dinnerSolve], quota.cap > 0, quota.used >= quota.cap {
                return .blockedByQuota(
                    feature: .dinnerSolve,
                    used: quota.used, cap: quota.cap,
                    resetDate: quota.periodEndDate,
                )
            }
            return .allowed

        case .recipeImport:
            if let quota = quotas[.recipeImport], quota.cap > 0, quota.used >= quota.cap {
                return .blockedByQuota(
                    feature: .recipeImport,
                    used: quota.used, cap: quota.cap,
                    resetDate: quota.periodEndDate,
                )
            }
            return .allowed
        }
    }

    // MARK: - Cached snapshot (24h grace)

    /// JSON-encodable snapshot kept in Keychain for the 24h offline fallback.
    /// v3 shape — flipped `serverStandingPantryCap: Int? → Int` in step
    /// SCA-207 to match the server-required wire field. Keychain account
    /// name was bumped in lockstep (see `.entitlementSnapshotV3` in
    /// `KeychainStorage`) so stale v2 snapshots are ignored rather than
    /// decode-failing and corrupting the 24h grace window.
    private struct PersistedSnapshot: Codable, Sendable {
        let tier: Tier
        let billingState: BillingState
        let isTrial: Bool
        let expiresAt: Date?
        let voiceEnabled: Bool
        let billingRetryBanner: Bool
        /// SCA-100: cached so a Keychain-restore path (24h offline
        /// fallback) carries the server-resolved cap. Non-optional
        /// post-SCA-207 — the wire field is required, so a snapshot
        /// without it is malformed by definition.
        let serverStandingPantryCap: Int
        let quotas: [FeatureKey: QuotaSnapshot]
        let cachedAt: Date
    }

    fileprivate static let cacheValidity: TimeInterval = 24 * 60 * 60

    private func persistSnapshot() {
        let snapshot = PersistedSnapshot(
            tier: tier,
            billingState: billingState,
            isTrial: isTrial,
            expiresAt: expiresAt,
            voiceEnabled: voiceEnabled,
            billingRetryBanner: billingRetryBanner,
            serverStandingPantryCap: serverStandingPantryCap,
            quotas: quotas,
            cachedAt: Date(),
        )
        do {
            let data = try JSONEncoder.stir.encode(snapshot)
            guard let string = String(data: data, encoding: .utf8) else { return }
            try keychain.write(string, key: .entitlementSnapshotV3)
        } catch {
            Logger.entitlement.warning(
                "failed to persist entitlement snapshot: \(error.localizedDescription, privacy: .public)",
            )
        }
    }

    private func restoreFromCachedSnapshotIfFresh() {
        // Best-effort cleanup of the v1/v2 snapshot keys. Pre-launch, nothing
        // depends on legacy data surviving — but leaving stale bytes around is
        // sloppy and makes future key audits harder. Delete-on-startup is
        // idempotent (errSecItemNotFound is treated as success in
        // `KeychainStorage.delete`).
        try? keychain.delete(key: .entitlementSnapshotLegacyV1)
        try? keychain.delete(key: .entitlementSnapshotV2)

        do {
            guard let raw = try keychain.read(key: .entitlementSnapshotV3),
                  let data = raw.data(using: .utf8) else {
                return
            }
            let snapshot = try JSONDecoder.stir.decode(PersistedSnapshot.self, from: data)
            let age = Date().timeIntervalSince(snapshot.cachedAt)
            guard age < Self.cacheValidity else {
                Logger.entitlement.info("cached snapshot stale (\(Int(age), privacy: .public)s) — discarding")
                try? keychain.delete(key: .entitlementSnapshotV3)
                return
            }
            self.tier = snapshot.tier
            self.billingState = snapshot.billingState
            self.isTrial = snapshot.isTrial
            self.expiresAt = snapshot.expiresAt
            self.voiceEnabled = snapshot.voiceEnabled
            self.billingRetryBanner = snapshot.billingRetryBanner
            self.serverStandingPantryCap = snapshot.serverStandingPantryCap
            self.quotas = snapshot.quotas
            self.hydrationState = .hydrated(source: .cachedSnapshot)
            Logger.entitlement.info("restored entitlement snapshot from cache (age \(Int(age), privacy: .public)s)")
        } catch {
            Logger.entitlement.warning(
                "cached snapshot restore failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }

    // MARK: - Period-end date parsing

    /// Fallback for `YYYY-MM-DD` bare-date strings (our Postgres `period_start`
    /// + `period_end` are `DATE` not `TIMESTAMPTZ`).
    static let datePeriodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    // MARK: - Gate helper (CR2-W2)

    /// Run `work` if `gate` is `.allowed`; otherwise present the paywall via
    /// `paywallTrigger`. Centralises the 4-arm `EntitlementDecision` switch
    /// so a partial-switch regression at any single call site can't silently
    /// fail closed without the others (the 3 favorites sites + 2 voice sites
    /// shared the same shape verbatim before this).
    ///
    /// `paywallTrigger` is a closure rather than a `PaywallTrigger?` so call
    /// sites that DON'T present a paywall (Settings toggles that are read-
    /// only when blocked) can pass `nil`-equivalent `{}`.
    @discardableResult
    func gate(
        _ feature: FeatureGate,
        paywall paywallTrigger: () -> Void,
        allow work: () -> Void,
    ) -> EntitlementDecision {
        let decision = canAccess(feature)
        switch decision {
        case .allowed:
            work()
        case .blockedByTier, .blockedByQuota, .blockedByBilling:
            paywallTrigger()
        }
        return decision
    }
}

extension EntitlementService {
    /// Standing-pantry-item cap. Server-shipped via the bootstrap
    /// response's `entitlements.standing_pantry_cap` (SCA-100), so a
    /// future cap override (marketing A/B, per-user experiment) ships
    /// without an iOS release. The Edge Function resolves the cap
    /// against `effectiveTier(entitlement)` before shipping the number,
    /// so a stale RevenueCat row `(tier=.premium, billing_state=.expired)`
    /// already arrives demoted to the Free cap — iOS does NOT
    /// re-resolve.
    ///
    /// SCA-207 sunset: prior to this change, the iOS side carried a
    /// `Tier.rememberedPantryCap` constant table as a fallback for
    /// in-flight rolling deploy + pre-SCA-100 server responses. Both
    /// risks are gone post-rollout, so the fallback is dropped — the
    /// wire field is now required.
    ///
    /// SCA-265 floor (preserved): a server-side bug or A/B that ships
    /// `0` (or negative) would lock every pantry add out with no UI
    /// signal, since the cap-enforcement path treats `count >= cap` as
    /// the lockout gate. Treat any non-positive value as a bug and
    /// floor at the Free panic value 25 — the minimum cap under the
    /// SCA-100 contract.
    ///
    /// Used by `PantryListViewModel` and `ScanViewModel` for client-
    /// side quota gating on manual adds and scan upserts (the cap is
    /// not enforced server-side because user content lives in
    /// CloudKit per north-star #3).
    var rememberedPantryCap: Int {
        max(serverStandingPantryCap, 25)
    }
}
