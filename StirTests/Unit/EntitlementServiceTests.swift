// EntitlementServiceTests
//
// FeatureGate matrix + hydration + 24h snapshot fallback.

import XCTest
@testable import Stir

@MainActor
final class EntitlementServiceTests: XCTestCase {
    func test_freeUser_blocksVoiceCookMode() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .free, billingState: .none))

        let decision = service.canAccess(.voiceCookMode)
        XCTAssertEqual(decision, .blockedByTier(required: .premium))
    }

    func test_premiumActive_allowsVoiceCookMode() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, voiceEnabled: true,
            quotas: [
                Self.quota(.voiceCookSession, used: 0, cap: 20),
                Self.quota(.dinnerSolve, used: 0, cap: 40),
                Self.quota(.recipeImport, used: 0, cap: 100_000),
            ],
        ))

        XCTAssertEqual(service.canAccess(.voiceCookMode), .allowed)
    }

    func test_premium_blocksVoiceCookMode_whenQuotaExhausted() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium,
            billingState: .active,
            voiceEnabled: true,
            quotas: [
                Self.quota(.voiceCookSession, used: 20, cap: 20),
                Self.quota(.dinnerSolve, used: 0, cap: 40),
                Self.quota(.recipeImport, used: 0, cap: 100_000),
            ],
        ))

        guard case .blockedByQuota(let feature, let used, let cap, _) = service.canAccess(.voiceCookMode) else {
            return XCTFail("expected .blockedByQuota")
        }
        XCTAssertEqual(feature, .voiceCookSession)
        XCTAssertEqual(used, 20)
        XCTAssertEqual(cap, 20)
    }

    // MARK: - Server voice_enabled flag honor (ADR-0008 + review fix)

    func test_voiceCookMode_honorsServerVoiceEnabledFlag_whenTrueOnFree() async throws {
        // ADR-0008: backend may flip voice_enabled=true regardless of
        // tier for dev/testing. iOS must honor the server's decision,
        // not re-derive from `tier` — the prior hardcoded tier check
        // would have blocked a server-authorized Free user from voice.
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .free,
            billingState: .none,
            voiceEnabled: true,
            quotas: [
                Self.quota(.voiceCookSession, used: 0, cap: 20),
                Self.quota(.dinnerSolve, used: 0, cap: 6),
                Self.quota(.recipeImport, used: 0, cap: 2),
            ],
        ))

        XCTAssertEqual(service.canAccess(.voiceCookMode), .allowed)
    }

    func test_voiceCookMode_blockedWhenServerDisablesEvenIfPaidTier() async throws {
        // Inverse: if the server computes voice_enabled=false (e.g.,
        // feature-flag kill switch, tier downgrade mid-session), the
        // client must respect that even when `tier` looks paid.
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium,
            billingState: .active,
            voiceEnabled: false,
            quotas: [
                Self.quota(.voiceCookSession, used: 0, cap: 20),
                Self.quota(.dinnerSolve, used: 0, cap: 40),
                Self.quota(.recipeImport, used: 0, cap: 100_000),
            ],
        ))

        XCTAssertEqual(service.canAccess(.voiceCookMode),
                       .blockedByTier(required: .premium))
    }

    // MARK: - Stale snapshot defensive: cap=0 must not falsely block

    func test_voiceCookMode_capZero_doesNotBlock_whenVoiceEnabled() async throws {
        // Regression: a stale cached snapshot from before the ADR-0008
        // DB backfill carried `voiceCookSession` cap=0. Old check was
        // `used >= cap` → `0 >= 0` → `.blockedByQuota` → "upgrade to
        // Pro" paywall even though nothing had been consumed. Defensive
        // guard now requires cap > 0 before quota-blocking.
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium,
            billingState: .active,
            voiceEnabled: true,
            quotas: [
                Self.quota(.voiceCookSession, used: 0, cap: 0),
                Self.quota(.dinnerSolve, used: 0, cap: 40),
                Self.quota(.recipeImport, used: 0, cap: 100_000),
            ],
        ))

        XCTAssertEqual(service.canAccess(.voiceCookMode), .allowed)
    }

    func test_dinnerSolve_capZero_doesNotBlock() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .free,
            billingState: .none,
            quotas: [
                Self.quota(.voiceCookSession, used: 0, cap: 0),
                Self.quota(.dinnerSolve, used: 0, cap: 0),
                Self.quota(.recipeImport, used: 0, cap: 0),
            ],
        ))

        XCTAssertEqual(service.canAccess(.dinnerSolve), .allowed)
    }

    func test_recipeImport_capZero_doesNotBlock() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .free,
            billingState: .none,
            quotas: [
                Self.quota(.voiceCookSession, used: 0, cap: 0),
                Self.quota(.dinnerSolve, used: 0, cap: 0),
                Self.quota(.recipeImport, used: 0, cap: 0),
            ],
        ))

        XCTAssertEqual(service.canAccess(.recipeImport), .allowed)
    }

    func test_expiredBillingState_treatsUserAsFree() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .premium, billingState: .expired))

        // Even though `tier` is premium, expired billing demotes to Free.
        XCTAssertEqual(service.canAccess(.voiceCookMode), .blockedByTier(required: .premium))
        XCTAssertEqual(service.canAccess(.savedFavorites), .blockedByTier(required: .premium))
    }

    func test_proTier_allowsMultiImageScanAndPriorityQueue() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .pro, billingState: .active))

        XCTAssertEqual(service.canAccess(.multiImageScan), .allowed)
        XCTAssertEqual(service.canAccess(.priorityInferenceQueue), .allowed)
    }

    func test_premiumTier_blocksMultiImageScan() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .premium, billingState: .active))

        XCTAssertEqual(service.canAccess(.multiImageScan), .blockedByTier(required: .pro))
    }

    func test_dinnerSolveQuota_blocksWhenExhausted() async throws {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .free,
            billingState: .none,
            quotas: [
                Self.quota(.dinnerSolve, used: 6, cap: 6),
                Self.quota(.voiceCookSession, used: 0, cap: 0),
                Self.quota(.recipeImport, used: 0, cap: 2),
            ],
        ))

        guard case .blockedByQuota(let feature, _, _, _) = service.canAccess(.dinnerSolve) else {
            return XCTFail("expected .blockedByQuota")
        }
        XCTAssertEqual(feature, .dinnerSolve)
    }

    func test_cachedSnapshot_restoredOnInit_withinValidityWindow() async throws {
        let keychain = MockKeychain()
        let first = EntitlementService(keychain: keychain)
        first.hydrate(from: Self.entitlements(tier: .premium, billingState: .active, voiceEnabled: true))
        XCTAssertEqual(first.tier, .premium)

        // New instance, same Keychain — should restore.
        let second = EntitlementService(keychain: keychain)
        XCTAssertEqual(second.tier, .premium)
        XCTAssertEqual(second.billingState, .active)
        if case .hydrated(source: let source) = second.hydrationState {
            XCTAssertEqual(source, .cachedSnapshot)
        } else {
            XCTFail("expected hydrated(source: .cachedSnapshot)")
        }
    }

    // MARK: - Step 5 additions

    func test_billingRetryBanner_reflectsBootstrapFlag() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .grace, voiceEnabled: true, billingRetryBanner: true,
        ))
        XCTAssertTrue(service.billingRetryBanner)
        XCTAssertEqual(service.billingState, .grace)
    }

    func test_billingRetryBanner_falseOutsideOfGrace() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, voiceEnabled: true, billingRetryBanner: false,
        ))
        XCTAssertFalse(service.billingRetryBanner)
    }

    func test_graceBillingState_keepsPremiumAccess() {
        // Regression guard: grace must NOT demote the user to Free. Apple
        // is retrying payment — we keep the features unlocked while that
        // happens.
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .grace, voiceEnabled: true, billingRetryBanner: true,
        ))
        XCTAssertEqual(service.canAccess(.savedFavorites), .allowed)
        XCTAssertEqual(service.canAccess(.widgets), .allowed)
        XCTAssertEqual(service.canAccess(.shortcutsAppIntents), .allowed)
        XCTAssertEqual(service.canAccess(.leftoversMode), .allowed)
    }

    func test_cancelledActive_keepsPremiumAccess_untilPeriodEnd() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .cancelledActive, voiceEnabled: true,
        ))
        XCTAssertEqual(service.canAccess(.savedFavorites), .allowed)
    }

    func test_decisionMatrix_allTierAndBillingStateCombinations() {
        // Spec §10 + CLAUDE.md table. Each (tier, billing_state) pair
        // should produce the documented gating behavior for every gate.
        // Condensed table: test one marquee gate (savedFavorites) across
        // the full matrix.
        struct Case {
            let tier: Tier
            let billingState: BillingState
            let expected: EntitlementDecision
            var label: String { "\(tier.rawValue)+\(billingState.rawValue)" }
        }
        let cases: [Case] = [
            // Free, any billing_state → blocked by tier (savedFavorites is Premium+)
            .init(tier: .free, billingState: .none, expected: .blockedByTier(required: .premium)),
            .init(tier: .free, billingState: .expired, expected: .blockedByTier(required: .premium)),
            // Premium, paid billing_states → allowed
            .init(tier: .premium, billingState: .active, expected: .allowed),
            .init(tier: .premium, billingState: .trial, expected: .allowed),
            .init(tier: .premium, billingState: .grace, expected: .allowed),
            .init(tier: .premium, billingState: .cancelledActive, expected: .allowed),
            // Premium, expired/none → demoted to free equivalent
            .init(tier: .premium, billingState: .expired, expected: .blockedByTier(required: .premium)),
            // Pro also has access to savedFavorites
            .init(tier: .pro, billingState: .active, expected: .allowed),
            .init(tier: .pro, billingState: .expired, expected: .blockedByTier(required: .premium)),
        ]
        for c in cases {
            let service = EntitlementService(keychain: MockKeychain())
            service.hydrate(from: Self.entitlements(
                tier: c.tier,
                billingState: c.billingState,
                voiceEnabled: true,
            ))
            XCTAssertEqual(
                service.canAccess(.savedFavorites),
                c.expected,
                "savedFavorites gate wrong for \(c.label)",
            )
        }
    }

    // MARK: - Feature flags

    func test_flagBool_returnsNil_whenFlagDisabled() {
        // Regression guard for the EntitlementService.flagBool contract:
        // a flag with is_enabled=false must return nil so callers fall back
        // to default behavior, even if `value` holds a valid bool.
        let service = EntitlementService(keychain: MockKeychain())
        let disabledFlag = BootstrapResponse.FeatureFlag(
            key: "disable_scan_parse", value: .bool(true), isEnabled: false, rolloutPct: 100,
        )
        service.hydrate(
            from: Self.entitlements(tier: .free, billingState: .none),
            flags: [disabledFlag],
        )
        XCTAssertNil(service.flagBool(forKey: "disable_scan_parse"))
    }

    func test_flagBool_returnsValue_whenFlagEnabled() {
        let service = EntitlementService(keychain: MockKeychain())
        let enabledFlag = BootstrapResponse.FeatureFlag(
            key: "disable_scan_parse", value: .bool(true), isEnabled: true, rolloutPct: 100,
        )
        service.hydrate(
            from: Self.entitlements(tier: .free, billingState: .none),
            flags: [enabledFlag],
        )
        XCTAssertEqual(service.flagBool(forKey: "disable_scan_parse"), true)
    }

    func test_flagBool_returnsNil_whenFlagMissing() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .free, billingState: .none))
        XCTAssertNil(service.flagBool(forKey: "nonexistent_flag"))
    }

    // MARK: - rememberedPantryCap

    func test_rememberedPantryCap_freeTierReturns25() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .free, billingState: .none, standingPantryCap: 25))
        XCTAssertEqual(service.rememberedPantryCap, 25)
    }

    func test_rememberedPantryCap_premiumActiveReturns250() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .premium, billingState: .active, standingPantryCap: 250))
        XCTAssertEqual(service.rememberedPantryCap, 250)
    }

    func test_rememberedPantryCap_proActiveReturns1000() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(tier: .pro, billingState: .active, standingPantryCap: 1_000))
        XCTAssertEqual(service.rememberedPantryCap, 1_000)
    }

    /// Server-side `effectiveTier()` resolution: a stale RevenueCat row
    /// `(tier=.premium, billing_state=.expired)` arrives demoted to the
    /// Free cap (25) on the wire. iOS takes that at face value — no
    /// double-resolution.
    func test_rememberedPantryCap_serverDeliversDemotedCapForExpiredPremium() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .expired, standingPantryCap: 25,
        ))
        XCTAssertEqual(service.rememberedPantryCap, 25,
                       "server resolves to Free cap before the wire — iOS takes it as-is")
    }

    // MARK: - SCA-100 — server-shipped standing_pantry_cap

    /// Sanity-check the migration's primary contract:
    /// `entitlements.standing_pantry_cap` from the wire is what
    /// `rememberedPantryCap` returns when present.
    func test_rememberedPantryCap_returnsServerValue() {
        let service = EntitlementService(keychain: MockKeychain())
        // Tier=.free; server says 75 (a future marketing A/B). The
        // service must return the server value as-is.
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: 75,
        ))
        XCTAssertEqual(service.rememberedPantryCap, 75,
                       "server-shipped cap is the source of truth post-SCA-207")
    }

    /// SCA-265 (W17 from /review-5): defensive floor against a future
    /// server-side bug shipping `0` (or negative). Returning 0 here
    /// would lock every pantry add out with no UI signal, since the
    /// cap-enforcement path treats `count >= cap` as the lockout gate.
    /// SCA-207 reframes the floor: with the Tier-table fallback gone,
    /// the floor is the Free panic value 25 inline.
    func test_rememberedPantryCap_serverZeroFloorsAt25() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, standingPantryCap: 0,
        ))
        XCTAssertEqual(service.rememberedPantryCap, 25,
                       "server cap=0 must floor at the Free panic value (25)")
    }

    func test_rememberedPantryCap_serverNegativeFloorsAt25() {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: -1,
        ))
        XCTAssertEqual(service.rememberedPantryCap, 25,
                       "server cap=-1 must floor at the Free panic value (25)")
    }

    // MARK: - Helpers

    private static let defaultQuotas: [BootstrapResponse.Quota] = [
        EntitlementServiceTests.quota(.dinnerSolve, used: 0, cap: 6),
        EntitlementServiceTests.quota(.voiceCookSession, used: 0, cap: 0),
        EntitlementServiceTests.quota(.recipeImport, used: 0, cap: 2),
    ]

    private static func entitlements(
        tier: Tier,
        billingState: BillingState,
        voiceEnabled: Bool = false,
        billingRetryBanner: Bool = false,
        standingPantryCap: Int = 25,
        quotas: [BootstrapResponse.Quota]? = nil,
    ) -> BootstrapResponse.Entitlements {
        BootstrapResponse.Entitlements(
            tier: tier,
            billingState: billingState,
            isTrial: false,
            expiresAt: nil,
            voiceEnabled: voiceEnabled,
            billingRetryBanner: billingRetryBanner,
            standingPantryCap: standingPantryCap,
            quotas: quotas ?? Self.defaultQuotas,
        )
    }

    private static func quota(_ key: FeatureKey, used: Int, cap: Int) -> BootstrapResponse.Quota {
        BootstrapResponse.Quota(
            featureKey: key,
            used: used,
            cap: cap,
            periodEnd: "2026-05-17",
        )
    }
}
