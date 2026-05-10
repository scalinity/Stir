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

    // MARK: - SCA-99 / ADR 0035 — tier-downgrade reconciliation

    func test_isDowngrade_matrix() {
        XCTAssertTrue(EntitlementService.isDowngrade(from: .pro,     to: .premium))
        XCTAssertTrue(EntitlementService.isDowngrade(from: .pro,     to: .free))
        XCTAssertTrue(EntitlementService.isDowngrade(from: .premium, to: .free))
        XCTAssertFalse(EntitlementService.isDowngrade(from: .free,    to: .free))
        XCTAssertFalse(EntitlementService.isDowngrade(from: .premium, to: .premium))
        XCTAssertFalse(EntitlementService.isDowngrade(from: .free,    to: .premium))
        XCTAssertFalse(EntitlementService.isDowngrade(from: .premium, to: .pro))
        XCTAssertFalse(EntitlementService.isDowngrade(from: .free,    to: .pro))
    }

    func test_publishReconciliationOutcome_archivedRows_emitsTelemetryAndBanner() {
        let service = makeServiceWithIsolatedDefaults()
        var captured: [[String: Any]] = []
        service.reconciliationTelemetry = { properties in captured.append(properties) }

        let outcome = PantryItemRepository.ReconcileOutcome(
            totalRememberedPre: 200,
            totalRememberedPost: 25,
            archivedCount: 175,
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        service.publishReconciliationOutcome(
            previousLiteral: .premium,
            newLiteral: .free,
            previousEffective: .premium,
            newEffective: .free,
            outcome: outcome,
            now: now,
        )

        // Telemetry payload
        XCTAssertEqual(captured.count, 1)
        let payload = captured[0]
        XCTAssertEqual(payload["previous_tier"] as? String, "premium")
        XCTAssertEqual(payload["new_tier"] as? String, "free")
        XCTAssertEqual(payload["previous_effective_tier"] as? String, "premium")
        XCTAssertEqual(payload["new_effective_tier"] as? String, "free")
        XCTAssertEqual(payload["archived_count"] as? Int, 175)
        XCTAssertEqual(payload["total_remembered_pre"] as? Int, 200)
        XCTAssertEqual(payload["total_remembered_post"] as? Int, 25)

        // Banner state
        let banner = service.pantryReconciliationBanner
        XCTAssertNotNil(banner)
        XCTAssertEqual(banner?.previousTier, .premium)
        XCTAssertEqual(banner?.newTier, .free)
        XCTAssertEqual(banner?.archivedCount, 175)
        XCTAssertEqual(banner?.shownAt, now)
    }

    func test_publishReconciliationOutcome_zeroArchive_emitsTelemetryButNoBanner() {
        let service = makeServiceWithIsolatedDefaults()
        var captured: [[String: Any]] = []
        service.reconciliationTelemetry = { properties in captured.append(properties) }

        let outcome = PantryItemRepository.ReconcileOutcome(
            totalRememberedPre: 10,
            totalRememberedPost: 10,
            archivedCount: 0,
        )
        service.publishReconciliationOutcome(
            previousLiteral: .premium,
            newLiteral: .free,
            previousEffective: .premium,
            newEffective: .free,
            outcome: outcome,
        )

        XCTAssertEqual(captured.count, 1, "telemetry fires unconditionally")
        XCTAssertEqual(captured[0]["archived_count"] as? Int, 0)
        XCTAssertNil(service.pantryReconciliationBanner,
                     "banner only surfaces when archivedCount > 0")
    }

    /// SCA-298 W21: when `outcome.handlerRan == false` (the coordinator's
    /// short-circuit paths for dealloc / no-household), the service must
    /// suppress telemetry — the dashboard signal is "downgrade reached
    /// reconciliation" and the handler never actually executed.
    func test_publishReconciliationOutcome_handlerRanFalse_suppressesTelemetryAndBanner() {
        let service = makeServiceWithIsolatedDefaults()
        var captured: [[String: Any]] = []
        service.reconciliationTelemetry = { properties in captured.append(properties) }

        let skipped = PantryItemRepository.ReconcileOutcome(
            totalRememberedPre: 0,
            totalRememberedPost: 0,
            archivedCount: 0,
            handlerRan: false,
        )
        service.publishReconciliationOutcome(
            previousLiteral: .premium,
            newLiteral: .free,
            previousEffective: .premium,
            newEffective: .free,
            outcome: skipped,
        )
        XCTAssertEqual(captured.count, 0, "handlerRan=false must skip telemetry")
        XCTAssertNil(service.pantryReconciliationBanner,
                     "handlerRan=false must skip the banner too")
    }

    func test_acknowledgeReconciliationBanner_clearsObservableAndPersistedSlots() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let service = EntitlementService(keychain: MockKeychain(), userDefaults: defaults)
        service.publishReconciliationOutcome(
            previousLiteral: .premium,
            newLiteral: .free,
            previousEffective: .premium,
            newEffective: .free,
            outcome: PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 200, totalRememberedPost: 25, archivedCount: 175,
            ),
        )
        XCTAssertNotNil(service.pantryReconciliationBanner)

        service.acknowledgeReconciliationBanner()

        XCTAssertNil(service.pantryReconciliationBanner)
        XCTAssertNil(
            defaults.data(forKey: "com.scalinity.stir.entitlement.pantryReconciliationBanner"),
            "persisted UserDefaults backing must clear so the same downgrade event doesn't re-fire on next launch",
        )
    }

    func test_dismissExpiredReconciliationBanner_removesBannerAfterTTL() {
        let service = makeServiceWithIsolatedDefaults()
        let shownAt = Date(timeIntervalSince1970: 1_700_000_000)
        service.publishReconciliationOutcome(
            previousLiteral: .premium,
            newLiteral: .free,
            previousEffective: .premium,
            newEffective: .free,
            outcome: PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 200, totalRememberedPost: 25, archivedCount: 175,
            ),
            now: shownAt,
        )
        XCTAssertNotNil(service.pantryReconciliationBanner)

        // Just under the TTL — banner stays.
        let nearlyExpired = shownAt.addingTimeInterval(7 * 24 * 3600 - 60)
        service.dismissExpiredReconciliationBanner(now: nearlyExpired)
        XCTAssertNotNil(service.pantryReconciliationBanner,
                        "banner must persist within the 7-day TTL")

        // Past the TTL — banner clears.
        let expired = shownAt.addingTimeInterval(7 * 24 * 3600 + 1)
        service.dismissExpiredReconciliationBanner(now: expired)
        XCTAssertNil(service.pantryReconciliationBanner,
                     "banner must auto-dismiss past the 7-day TTL")
    }

    func test_bannerPersistence_restoresOnNewServiceInstance() throws {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let writer = EntitlementService(keychain: MockKeychain(), userDefaults: defaults)
        let shownAt = Date()  // banner is fresh — well within TTL
        writer.publishReconciliationOutcome(
            previousLiteral: .pro,
            newLiteral: .free,
            previousEffective: .pro,
            newEffective: .free,
            outcome: PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 1_000, totalRememberedPost: 25, archivedCount: 975,
            ),
            now: shownAt,
        )

        // Fresh service against the same UserDefaults — banner must restore.
        let reader = EntitlementService(keychain: MockKeychain(), userDefaults: defaults)
        let banner = reader.pantryReconciliationBanner
        XCTAssertNotNil(banner)
        XCTAssertEqual(banner?.previousTier, .pro)
        XCTAssertEqual(banner?.newTier, .free)
        XCTAssertEqual(banner?.archivedCount, 975)
    }

    func test_bannerPersistence_dropsStaleBannerOnRestore() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Hand-write an aged banner directly into UserDefaults.
        let staleBanner = EntitlementService.ReconciliationBanner(
            previousTier: .premium, newTier: .free, archivedCount: 50,
            shownAt: Date().addingTimeInterval(-30 * 24 * 3600),  // 30 days ago
        )
        let data = try! JSONEncoder.stir.encode(staleBanner)
        defaults.set(data, forKey: "com.scalinity.stir.entitlement.pantryReconciliationBanner")

        let reader = EntitlementService(keychain: MockKeychain(), userDefaults: defaults)
        XCTAssertNil(reader.pantryReconciliationBanner,
                     "a banner aged past 7 days must NOT restore on init")
    }

    func test_hydrate_firstHydrate_doesNotFireReconciliation() async {
        // First hydrate after launch goes from `.loading` → `.hydrated`.
        // Even if `effectiveTier` looks like a downgrade against the
        // (free/none) init defaults, `applyTierChange` must skip — the
        // service had no prior state to "downgrade from".
        let service = makeServiceWithIsolatedDefaults()
        var dispatched = false
        service.tierDowngradeHandler = { _, _, _ in
            dispatched = true
            return PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 0, totalRememberedPost: 0, archivedCount: 0,
            )
        }

        service.hydrate(from: Self.entitlements(tier: .free, billingState: .none))
        // Yield once so any spawned Task would run if the guard failed.
        await Task.yield()
        XCTAssertFalse(dispatched, "first hydrate must skip the downgrade hook")
    }

    func test_hydrate_premiumToFree_dispatchesReconciliationHandler() async throws {
        let service = makeServiceWithIsolatedDefaults()

        // Prime to Premium.
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, standingPantryCap: 250,
        ))

        let expectation = XCTestExpectation(description: "downgrade handler invoked")
        let captureBox = HandlerCaptureBox()
        service.tierDowngradeHandler = { previous, new, newCap in
            await captureBox.record(previous: previous, new: new, newCap: newCap)
            expectation.fulfill()
            return PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 200, totalRememberedPost: 25, archivedCount: 175,
            )
        }
        var captured: [[String: Any]] = []
        service.reconciliationTelemetry = { properties in captured.append(properties) }

        // Downgrade: Premium → Free.
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: 25,
        ))

        await fulfillment(of: [expectation], timeout: 1.0)

        let snapshot = await captureBox.snapshot
        XCTAssertEqual(snapshot.previous, .premium)
        XCTAssertEqual(snapshot.new, .free)
        XCTAssertEqual(snapshot.newCap, 25)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0]["archived_count"] as? Int, 175)
        XCTAssertEqual(captured[0]["previous_effective_tier"] as? String, "premium")
        XCTAssertEqual(captured[0]["new_effective_tier"] as? String, "free")

        // Banner publishes after the async hop — give it a tick to settle.
        await Task.yield()
        XCTAssertEqual(service.pantryReconciliationBanner?.archivedCount, 175)
    }

    /// SCA-298 W1: Premium-trial-expiry hydrate — the LITERAL RC tier
    /// stays `.premium` across the transition, but `billingState`
    /// flipping `active → expired` (RC's `EXPIRATION` event) demotes
    /// the EFFECTIVE tier `premium → free`. The downgrade hook must
    /// still fire, and telemetry must carry the effective pair so
    /// a dashboard filter on `WHERE previous_tier != new_tier` doesn't
    /// drop the cohort that ADR 0035 was sized against.
    func test_hydrate_premiumTrialExpiry_dispatchesReconciliationWithEffectiveTiers() async throws {
        let service = makeServiceWithIsolatedDefaults()

        // Prime to Premium (trial active).
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, standingPantryCap: 250,
        ))

        let expectation = XCTestExpectation(description: "downgrade handler invoked on trial expiry")
        let captureBox = HandlerCaptureBox()
        service.tierDowngradeHandler = { previous, new, newCap in
            await captureBox.record(previous: previous, new: new, newCap: newCap)
            expectation.fulfill()
            return PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 60, totalRememberedPost: 25, archivedCount: 35,
            )
        }
        var captured: [[String: Any]] = []
        service.reconciliationTelemetry = { properties in captured.append(properties) }

        // Trial expiry: tier still .premium, billingState flips to .expired.
        // EffectiveTier demotes premium → free; the downgrade gate must fire.
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .expired, standingPantryCap: 25,
        ))

        await fulfillment(of: [expectation], timeout: 1.0)

        // Handler still receives literal tiers — that's the RC source of
        // truth for the closure's job (Core Data reconciliation against
        // the new cap doesn't care about effective demotion).
        let snapshot = await captureBox.snapshot
        XCTAssertEqual(snapshot.previous, .premium, "handler receives literal tier")
        XCTAssertEqual(snapshot.new, .premium, "literal tier unchanged on trial expiry")

        // Telemetry carries BOTH pairs so the dashboard sees the real
        // demotion. previous_tier and new_tier match the literal pair
        // (both premium); previous_effective_tier / new_effective_tier
        // reveal the premium → free demotion.
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0]["previous_tier"] as? String, "premium")
        XCTAssertEqual(captured[0]["new_tier"] as? String, "premium")
        XCTAssertEqual(captured[0]["previous_effective_tier"] as? String, "premium")
        XCTAssertEqual(captured[0]["new_effective_tier"] as? String, "free")
        XCTAssertEqual(captured[0]["archived_count"] as? Int, 35)
    }

    func test_hydrate_upgrade_doesNotDispatchReconciliation() async {
        let service = makeServiceWithIsolatedDefaults()
        // Prime to Free.
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: 25,
        ))
        var dispatched = false
        service.tierDowngradeHandler = { _, _, _ in
            dispatched = true
            return PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 0, totalRememberedPost: 0, archivedCount: 0,
            )
        }

        // Upgrade: Free → Premium.
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, standingPantryCap: 250,
        ))
        await Task.yield()
        XCTAssertFalse(dispatched, "upgrade path must not fire downgrade reconciliation")
    }

    // MARK: - SCA-299: detached Task hardening

    /// SCA-299: between `applyTierChange` dispatch and the Task's
    /// @MainActor execution, a second hydrate lands. The Task captured
    /// `newCap` from the FIRST hydrate but the service now reflects the
    /// SECOND. The Task must re-fetch `rememberedPantryCap` against
    /// current state before calling the handler, so the repo reconciles
    /// against the post-flap cap.
    func test_applyTierChange_staleNewCap_refetchesAgainstCurrentState() async throws {
        let service = makeServiceWithIsolatedDefaults()

        // Prime to Pro (cap 1000).
        service.hydrate(from: Self.entitlements(
            tier: .pro, billingState: .active, standingPantryCap: 1000,
        ))

        // Handler that records the cap it's invoked with.
        let captureBox = HandlerCaptureBox()
        let expectation = XCTestExpectation(description: "handler invoked after flap")
        service.tierDowngradeHandler = { previous, new, newCap in
            await captureBox.record(previous: previous, new: new, newCap: newCap)
            expectation.fulfill()
            return PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 0, totalRememberedPost: 0, archivedCount: 0,
            )
        }

        // First downgrade: Pro → Premium (cap should be 250 by the time
        // the Task runs). Then immediately a SECOND hydrate to Free
        // (cap 25) before the Task gets the @MainActor — both hydrates
        // run synchronously on this @MainActor test, but the Task body
        // runs LATER. The Task must observe `tier=.free` and re-fetch
        // newCap=25 rather than carrying the dispatched cap=250.
        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, standingPantryCap: 250,
        ))
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: 25,
        ))

        await fulfillment(of: [expectation], timeout: 1.0)
        let snapshot = await captureBox.snapshot
        XCTAssertEqual(snapshot.newCap, 25,
                       "Task must re-fetch newCap against post-flap state — pre-flap dispatched 250, post-flap is 25")
    }

    /// SCA-299: a thrown reconciliation error persists a
    /// pending-reconciliation flag so the next foreground hydrate
    /// can retry. Flag carries the EFFECTIVE pair so a billing-state
    /// flap between failure and retry doesn't switch cohorts.
    func test_applyTierChange_handlerThrows_persistsPendingReconciliationFlag() async throws {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = EntitlementService(keychain: MockKeychain(), userDefaults: defaults)

        service.hydrate(from: Self.entitlements(
            tier: .premium, billingState: .active, standingPantryCap: 250,
        ))

        let expectation = XCTestExpectation(description: "handler invoked then threw")
        service.tierDowngradeHandler = { _, _, _ in
            expectation.fulfill()
            throw EntitlementTestError.coreDataFault
        }

        // Premium → Free (effective downgrade).
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: 25,
        ))

        await fulfillment(of: [expectation], timeout: 1.0)
        // Give the catch block a tick to persist.
        await Task.yield()

        let pending = service.loadPendingReconciliation()
        XCTAssertNotNil(pending, "thrown handler must persist a pending-reconciliation flag")
        XCTAssertEqual(pending?.previousEffective, .premium)
        XCTAssertEqual(pending?.newEffective, .free)
    }

    /// SCA-299: retryPendingReconciliationIfNeeded re-dispatches the
    /// handler and clears the flag on success. Called from
    /// RootCoordinator's foreground refresh hook after every hydrate.
    func test_retryPendingReconciliation_redispatches_andClearsFlag_onSuccess() async throws {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = EntitlementService(keychain: MockKeychain(), userDefaults: defaults)

        // Hand-plant a pending-reconciliation flag, as if a prior
        // Task had thrown.
        let pending = EntitlementService.PendingReconciliation(
            previousEffective: .premium,
            newEffective: .free,
            failedAt: Date().addingTimeInterval(-3600),
        )
        let data = try JSONEncoder.stir.encode(pending)
        defaults.set(data, forKey: EntitlementService.pendingReconciliationDefaultsKey)
        XCTAssertNotNil(service.loadPendingReconciliation(), "test setup precondition")

        // Hydrate to Free so the retry's `applyTierChange(previousLiteral:
        // tier, newLiteral: tier, ...)` doesn't trip the no-handler guard
        // with a stale state. Also prime the handler to succeed.
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: 25,
        ))

        let expectation = XCTestExpectation(description: "retry handler invoked")
        service.tierDowngradeHandler = { _, _, _ in
            expectation.fulfill()
            return PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 30, totalRememberedPost: 25, archivedCount: 5,
            )
        }

        service.retryPendingReconciliationIfNeeded()
        await fulfillment(of: [expectation], timeout: 1.0)
        // Give the success path a tick to clear the flag.
        await Task.yield()
        XCTAssertNil(service.loadPendingReconciliation(),
                     "successful retry must clear the pending-reconciliation flag")
    }

    /// SCA-299: retry no-ops when no flag is set. Important — the
    /// foreground hook runs after every hydrate, so a path with no
    /// pending failure mustn't accidentally fire a fresh reconciliation.
    func test_retryPendingReconciliation_noFlag_isNoOp() async {
        let service = makeServiceWithIsolatedDefaults()
        service.hydrate(from: Self.entitlements(
            tier: .free, billingState: .none, standingPantryCap: 25,
        ))

        var dispatched = false
        service.tierDowngradeHandler = { _, _, _ in
            dispatched = true
            return PantryItemRepository.ReconcileOutcome(
                totalRememberedPre: 0, totalRememberedPost: 0, archivedCount: 0,
            )
        }
        service.retryPendingReconciliationIfNeeded()
        await Task.yield()
        XCTAssertFalse(dispatched, "no flag → no retry dispatch")
    }

    /// Build an EntitlementService against an isolated UserDefaults
    /// suite so the SCA-99 banner persistence path doesn't bleed
    /// across tests. The suite is intentionally not removed in
    /// teardown — `UserDefaults(suiteName:)` instances are
    /// process-scoped and short-lived; XCTest reset between cases
    /// is sufficient for the SCA-99 banner key.
    private func makeServiceWithIsolatedDefaults() -> EntitlementService {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return EntitlementService(keychain: MockKeychain(), userDefaults: defaults)
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

/// SCA-299 helper: synthetic error class for the handler-throws path.
enum EntitlementTestError: Error {
    case coreDataFault
}

/// SCA-99 helper: thread-safe capture box for the async tier-
/// downgrade handler invocation. Records the (previous, new, newCap)
/// triple the service forwarded so the test can assert against it
/// after the Task hop resolves.
actor HandlerCaptureBox {
    struct Snapshot {
        let previous: Tier
        let new: Tier
        let newCap: Int
    }
    private var captured: Snapshot?

    func record(previous: Tier, new: Tier, newCap: Int) {
        captured = Snapshot(previous: previous, new: new, newCap: newCap)
    }

    var snapshot: Snapshot {
        captured ?? Snapshot(previous: .free, new: .free, newCap: 0)
    }
}
