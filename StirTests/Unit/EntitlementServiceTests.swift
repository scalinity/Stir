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
        quotas: [BootstrapResponse.Quota]? = nil,
    ) -> BootstrapResponse.Entitlements {
        BootstrapResponse.Entitlements(
            tier: tier,
            billingState: billingState,
            isTrial: false,
            expiresAt: nil,
            voiceEnabled: voiceEnabled,
            billingRetryBanner: false,
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
