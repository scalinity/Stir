// PaywallViewModelTests
//
// State-machine tests for PaywallViewModel. Uses a mock
// `RevenueCatPurchasing` so tests never touch StoreKit or the real RC
// SDK. Focus is on transitions, not on RC-adaptation correctness.

import XCTest
@testable import Stir

@MainActor
final class PaywallViewModelTests: XCTestCase {
    // MARK: - Load

    func test_load_setsStateToDisplayingOnOfferingsSuccess() async {
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [
            Self.samplePackage(.premiumAnnualTrial7),
            Self.samplePackage(.premiumMonthly),
        ]))
        let vm = Self.makeVM(service: service)

        await vm.load()

        guard case .displaying(let offerings) = vm.state else {
            return XCTFail("expected .displaying, got \(vm.state)")
        }
        XCTAssertEqual(offerings.packages.count, 2)
    }

    func test_load_setsStateToFailedOnOfferingsError() async {
        let service = MockRevenueCatService()
        service.offeringsResult = .failure(PayError.networkUnreachable)
        let vm = Self.makeVM(service: service)

        await vm.load()

        guard case .failedToLoad(let error) = vm.state else {
            return XCTFail("expected .failedToLoad, got \(vm.state)")
        }
        XCTAssertEqual(error, .networkUnreachable)
    }

    // MARK: - Purchase

    func test_purchase_successTransitionsToSucceeded_andTriggersRefresh() async {
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)]))
        service.purchaseResult = .succeeded(
            productID: "stir.premium.annual.trial7",
            trial: true,
            introOffer: true,
            priceDisplay: "$69.99",
        )
        var refreshCount = 0
        let vm = Self.makeVM(service: service, onRefresh: { refreshCount += 1 })
        await vm.load()

        await vm.purchase(productID: "stir.premium.annual.trial7")

        guard case .succeeded(let id) = vm.state else {
            return XCTFail("expected .succeeded, got \(vm.state)")
        }
        XCTAssertEqual(id, "stir.premium.annual.trial7")
        XCTAssertEqual(refreshCount, 1, "succeeded should request an entitlement refresh")
    }

    func test_purchase_userCancelledReturnsToDisplaying() async {
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)]))
        service.purchaseResult = .userCancelled
        let vm = Self.makeVM(service: service)
        await vm.load()

        await vm.purchase(productID: "stir.premium.annual.trial7")

        // State machine returns to displaying OR idle when cancelled. We
        // accept either; the important invariant is no success/failure
        // surfacing.
        switch vm.state {
        case .displaying, .idle:
            break
        default:
            XCTFail("expected .displaying or .idle, got \(vm.state)")
        }
    }

    func test_purchase_failedEntersPurchaseFailedWithError() async {
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)]))
        service.purchaseResult = .failed(.storeProblem(description: "test"))
        let vm = Self.makeVM(service: service)
        await vm.load()

        await vm.purchase(productID: "stir.premium.annual.trial7")

        guard case .purchaseFailed(let id, let err) = vm.state else {
            return XCTFail("expected .purchaseFailed, got \(vm.state)")
        }
        XCTAssertEqual(id, "stir.premium.annual.trial7")
        if case .storeProblem = err {} else {
            XCTFail("expected .storeProblem error, got \(err)")
        }
    }

    func test_purchase_pendingEntersPurchasePending() async {
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)]))
        service.purchaseResult = .pending
        let vm = Self.makeVM(service: service)
        await vm.load()

        await vm.purchase(productID: "stir.premium.annual.trial7")

        guard case .purchasePending(let id) = vm.state else {
            return XCTFail("expected .purchasePending, got \(vm.state)")
        }
        XCTAssertEqual(id, "stir.premium.annual.trial7")
    }

    // MARK: - Restore

    func test_restore_success_triggersRefresh() async {
        let service = MockRevenueCatService()
        service.restoreResult = .restored
        var refreshCount = 0
        let vm = Self.makeVM(service: service, onRefresh: { refreshCount += 1 })

        let outcome = await vm.restore(origin: .settings)

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(refreshCount, 1)
    }

    func test_restore_nothingToRestore_doesNotTriggerRefresh() async {
        let service = MockRevenueCatService()
        service.restoreResult = .nothingToRestore
        var refreshCount = 0
        let vm = Self.makeVM(service: service, onRefresh: { refreshCount += 1 })

        let outcome = await vm.restore(origin: .paywall)

        XCTAssertEqual(outcome, .nothingToRestore)
        XCTAssertEqual(refreshCount, 0)
    }

    // MARK: - Helpers

    private static func makeVM(
        service: any RevenueCatPurchasing,
        onRefresh: @escaping @Sendable () -> Void = {},
    ) -> PaywallViewModel {
        let entitlements = EntitlementService(keychain: MockKeychain())
        entitlements.hydrate(from: BootstrapResponse.Entitlements(
            tier: .free,
            billingState: .none,
            isTrial: false,
            expiresAt: nil,
            voiceEnabled: false,
            billingRetryBanner: false,
            quotas: [],
        ))
        return PaywallViewModel(
            trigger: .settingsUpgrade,
            service: service,
            entitlements: entitlements,
            onEntitlementRefreshRequested: onRefresh,
        )
    }

    private static func samplePackage(_ product: StirProduct) -> PaywallPackage {
        PaywallPackage(
            productID: product.rawValue,
            displayPrice: product == .premiumAnnualTrial7 ? "$69.99" : "$9.99",
            periodDescription: product.rawValue.contains("annual") ? "year" : "month",
            introOfferDescription: product == .premiumAnnualTrial7
                ? "7-day free trial, then $69.99/year" : nil,
            tier: product.tier,
        )
    }
}

// MARK: - Mock RevenueCatPurchasing

final class MockRevenueCatService: RevenueCatPurchasing, @unchecked Sendable {
    var offeringsResult: Result<PaywallOfferings, Error> = .success(.init(packages: []))
    var purchaseResult: PurchaseOutcome = .userCancelled
    var restoreResult: RestoreOutcome = .nothingToRestore
    var logInCalled: [String] = []

    func offerings() async throws -> PaywallOfferings {
        switch offeringsResult {
        case .success(let off): return off
        case .failure(let err): throw err
        }
    }

    func purchase(productID: String) async throws -> PurchaseOutcome {
        purchaseResult
    }

    func restorePurchases() async throws -> RestoreOutcome {
        restoreResult
    }

    func logIn(canonicalUserKey: String) async throws {
        logInCalled.append(canonicalUserKey)
    }
}
