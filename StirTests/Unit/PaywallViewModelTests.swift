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

    func test_purchase_userCancelledReturnsToDisplayingWithCachedOfferings() async {
        // Regression guard (step-5 review bug: userCancelled dropped to
        // .idle, which left the paywall blank until the view's one-shot
        // `.task` modifier re-fired — it doesn't re-fire while already
        // presented). VM must restore `.displaying(cachedOfferings)`.
        let offerings = PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)])
        let service = MockRevenueCatService()
        service.offeringsResult = .success(offerings)
        service.purchaseResult = .userCancelled
        let vm = Self.makeVM(service: service)
        await vm.load()

        await vm.purchase(productID: "stir.premium.annual.trial7")

        // The state after a user cancel MUST be .displaying — not .idle
        // (the previous behavior). If it's .idle, the paywall goes blank.
        guard case .displaying(let shown) = vm.state else {
            return XCTFail("expected .displaying, got \(vm.state)")
        }
        XCTAssertEqual(shown.packages.first?.productID, "stir.premium.annual.trial7")
    }

    func test_purchase_canRetryFromPurchaseFailed() async {
        // Regression guard for DB1's "Try Again" silent no-op: previous
        // `purchase()` guarded only on `.displaying`, so tapping Try Again
        // from `.purchaseFailed` did nothing. Must allow entry from
        // `.purchaseFailed` and transition the state machine correctly.
        let offerings = PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)])
        let service = MockRevenueCatService()
        service.offeringsResult = .success(offerings)
        service.purchaseResult = .failed(.storeProblem(description: "once"))
        let vm = Self.makeVM(service: service)
        await vm.load()
        await vm.purchase(productID: "stir.premium.annual.trial7")
        guard case .purchaseFailed = vm.state else {
            return XCTFail("precondition: expected .purchaseFailed")
        }

        // Second attempt (e.g. network recovered) succeeds.
        service.purchaseResult = .succeeded(
            productID: "stir.premium.annual.trial7",
            trial: true,
            introOffer: true,
            priceDisplay: "$69.99",
        )
        await vm.purchase(productID: "stir.premium.annual.trial7")

        guard case .succeeded(let productID) = vm.state else {
            return XCTFail("expected .succeeded after retry, got \(vm.state)")
        }
        XCTAssertEqual(productID, "stir.premium.annual.trial7")
    }

    func test_dismissError_restoresDisplayingWithCachedOfferings() async {
        // Regression guard for DB1: dismissError previously fell to .idle,
        // leaving paywall dead-loading.
        let offerings = PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)])
        let service = MockRevenueCatService()
        service.offeringsResult = .success(offerings)
        service.purchaseResult = .failed(.generic(description: "test"))
        let vm = Self.makeVM(service: service)
        await vm.load()
        await vm.purchase(productID: "stir.premium.annual.trial7")
        guard case .purchaseFailed = vm.state else {
            return XCTFail("precondition: expected .purchaseFailed")
        }

        vm.dismissError()

        guard case .displaying(let shown) = vm.state else {
            return XCTFail("expected .displaying after dismissError, got \(vm.state)")
        }
        XCTAssertEqual(shown.packages.first?.productID, "stir.premium.annual.trial7")
    }

    func test_didSucceed_flipsTrueOnSucceeded_falseOtherwise() async {
        // Verify the success flag read by RootView.onDisappear is set
        // from the VM's own state transition, not from entitlements
        // (which lag by a webhook hop).
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)]))
        let vm = Self.makeVM(service: service)
        await vm.load()
        XCTAssertFalse(vm.didSucceed, "initial state should not claim success")

        service.purchaseResult = .userCancelled
        await vm.purchase(productID: "stir.premium.annual.trial7")
        XCTAssertFalse(vm.didSucceed, "userCancelled should not flip didSucceed")

        service.purchaseResult = .succeeded(
            productID: "stir.premium.annual.trial7",
            trial: true, introOffer: true, priceDisplay: "$69.99",
        )
        await vm.purchase(productID: "stir.premium.annual.trial7")
        XCTAssertTrue(vm.didSucceed, "succeeded outcome flips didSucceed")
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

    func test_restore_failedDoesNotTriggerRefresh() async {
        // Regression guard for CR3 suggestion: failed restore must not
        // trigger a spurious entitlement refresh (the entitlement didn't
        // change; refresh-on-fail was an oversight in the original code).
        let service = MockRevenueCatService()
        service.restoreResult = .failed(.networkUnreachable)
        var refreshCount = 0
        let vm = Self.makeVM(service: service, onRefresh: { refreshCount += 1 })

        let outcome = await vm.restore(origin: .paywall)

        if case .failed = outcome {} else {
            return XCTFail("expected .failed, got \(outcome)")
        }
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
    var startObservingCallCount = 0

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

    /// No-op for tests; the real observer is backed by RC's SDK stream.
    /// We only record the call count so tests can verify the coordinator
    /// wires the observer on post-bootstrap.
    func startObserving(onChange: @escaping @Sendable () async -> Void) async {
        startObservingCallCount += 1
    }
}
