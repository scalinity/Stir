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

    func test_load_emptyOfferings_reachesDisplaying_withAllHelperPackagesNil() async {
        // SCA-720 regression guard for SCA-679 + SCA-683 (Premium tier
        // must stay visible when offerings load fails or returns empty).
        //
        // The VM must transition to `.displaying` even with zero packages
        // — `.failedToLoad` only fires on an actual throw from the
        // service. The paywall view then renders the Premium section
        // unconditionally (PaywallView.premiumPlansSection) and the
        // "Compare plans" sheet's `premiumCTAs` does the same, both
        // falling back to "unavailable" labels in their plan rows when
        // each helper returns nil. If a future refactor flips the VM to
        // treat empty packages as failure, the section never renders
        // and Premium silently disappears — the exact symptom SCA-679
        // shipped to fix. Lock the prerequisite at the VM boundary.
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: []))
        let vm = Self.makeVM(service: service)

        await vm.load()

        guard case .displaying(let offerings) = vm.state else {
            return XCTFail("expected .displaying with empty offerings, got \(vm.state)")
        }
        XCTAssertEqual(offerings.packages.count, 0)
        XCTAssertNil(offerings.premiumAnnualPackage, "Premium annual must be nil with empty packages — view falls back to unavailable label")
        XCTAssertNil(offerings.premiumMonthlyPackage, "Premium monthly must be nil with empty packages — view falls back to unavailable label")
        XCTAssertNil(offerings.proAnnualPackage)
        XCTAssertNil(offerings.proMonthlyPackage)
        XCTAssertNil(offerings.primaryTrialPackage)
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

    // MARK: - Concurrent load guard + currentOfferings

    func test_load_concurrentCalls_areGuarded() async {
        // Regression guard for the `.loading` re-entry guard in load().
        // Two concurrent load() calls must not double-fetch offerings;
        // the second call sees state==.loading and returns silently.
        let service = CountingMockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)]))
        let vm = Self.makeVM(service: service)

        async let a: Void = vm.load()
        async let b: Void = vm.load()
        _ = await (a, b)

        // At least one load completed; at most two offerings fetches reached
        // the service. The guard is state-based, so the second call landing
        // during .loading aborts without incrementing the count. Whichever
        // call wins, we expect exactly 1 fetch.
        XCTAssertEqual(service.offeringsCallCount, 1)
    }

    func test_currentOfferings_returnsCache_duringPurchasing() async {
        // Regression guard for PaywallView.swift: during .purchasing the
        // paywall reads currentOfferings() to render real prices on the
        // non-in-flight packages. Must fall through to cachedOfferings.
        let offerings = PaywallOfferings(packages: [Self.samplePackage(.premiumAnnualTrial7)])
        let service = MockRevenueCatService()
        service.offeringsResult = .success(offerings)
        // Use a purchase result that keeps us in `.purchasing` briefly is
        // tricky without timing control; instead manually advance the VM by
        // triggering a pending purchase, which transitions to .purchasePending
        // and still caches offerings for currentOfferings fall-through.
        service.purchaseResult = .pending
        let vm = Self.makeVM(service: service)
        await vm.load()
        await vm.purchase(productID: "stir.premium.annual.trial7")

        guard case .purchasePending = vm.state else {
            return XCTFail("expected .purchasePending, got \(vm.state)")
        }
        let current = vm.currentOfferings()
        XCTAssertEqual(current?.packages.first?.productID, "stir.premium.annual.trial7")
    }

    // MARK: - Intro-offer eligibility (SCA-287)

    func test_load_propagatesIntroEligibility_throughVMOfferings() async {
        // SCA-287: PaywallView reads `package.introEligibility` to decide
        // CTA + disclosure copy. The VM is a pass-through — it must not
        // strip or coerce the field. Regression guard: any future refactor
        // that re-maps offerings inside the VM must preserve eligibility.
        //
        // SCA-294: trial-bearing SKU is now `stir.pro.annual` ($139.99),
        // not `stir.premium.annual.trial7`. `primaryTrialPackage` resolves
        // by productID match — this test puts a Pro-annual package with
        // .ineligible into the offering and asserts plumbing.
        let ineligiblePackage = PaywallPackage(
            productID: StirProduct.proAnnual.rawValue,
            displayPrice: "$139.99",
            periodDescription: "year",
            introOfferDescription: "7-day free trial, then $139.99/year",
            tier: .pro,
            introEligibility: .ineligible,
        )
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [ineligiblePackage]))
        let vm = Self.makeVM(service: service)

        await vm.load()

        let surfaced = vm.currentOfferings()?.primaryTrialPackage
        XCTAssertEqual(surfaced?.productID, StirProduct.proAnnual.rawValue)
        XCTAssertEqual(surfaced?.introEligibility, .ineligible)
    }

    func test_load_eligibleSurfacedAlongsideTrialBearingPackage() async {
        // Symmetric coverage for the eligible branch — the View treats
        // `.eligible` and `.unknown` identically (both show trial copy per
        // RC convention), so this asserts the field plumbs through for
        // `.eligible` too. Without this, a future regression that coerced
        // .eligible → .unknown would still pass `test_load_propagates...`.
        let eligible = Self.samplePackage(.proAnnual, eligibility: .eligible)
        let service = MockRevenueCatService()
        service.offeringsResult = .success(PaywallOfferings(packages: [eligible]))
        let vm = Self.makeVM(service: service)

        await vm.load()

        XCTAssertEqual(
            vm.currentOfferings()?.primaryTrialPackage?.introEligibility,
            .eligible,
        )
    }

    // MARK: - Trial copy guard (SCA-287 + SCA-294 regression)

    func test_shouldShowTrialCopy_isExhaustiveOnIntroEligibility() {
        // Regression guard: a future change that introduces a new
        // IntroEligibility case without updating PaywallView.shouldShowTrialCopy
        // will fail the switch's exhaustiveness check at compile time.
        // This test pins the per-case behavior. Critical because the View's
        // "Start 7-day free trial" vs "Subscribe annually" copy branches on
        // this single helper — a wrong return value here means a user sees
        // trial copy and gets charged full price (App Review reject + refund
        // request risk).
        XCTAssertTrue(PaywallView.shouldShowTrialCopy(for: .eligible))
        XCTAssertTrue(PaywallView.shouldShowTrialCopy(for: .unknown))
        XCTAssertTrue(PaywallView.shouldShowTrialCopy(for: nil),
                      "nil (missing package) defaults to .unknown per the helper contract")
        XCTAssertFalse(PaywallView.shouldShowTrialCopy(for: .ineligible),
                       "user already consumed the trial — auto-renew copy only")
        // SCA-294 regression: dashboard drift (intro offer not yet registered
        // on the trial-bearing SKU in App Store Connect, or RC cache stale)
        // surfaces as `.noOffer`. The pre-fix code used `!= .ineligible` which
        // treated this as eligible, showing "Start 7-day free trial" while
        // Apple would charge full price immediately. This assertion fails on
        // the un-fixed code path.
        XCTAssertFalse(PaywallView.shouldShowTrialCopy(for: .noOffer),
                       "dashboard drift — no trial offer on the SKU; must not show trial copy")
    }

    // MARK: - Tier-derivation helper (SCA-337 + SCA-340 regression)

    func test_tierForPurchasedProductID_resolvesProSKUs() {
        // SCA-294 routed the trial onto Pro Annual; SCA-332 made all four
        // SKUs purchasable inline. The success / pending welcome copy
        // routes through PaywallView.tier(forPurchasedProductID:). A wrong
        // mapping here means "Welcome to Stir Premium" after a Pro purchase
        // (or vice versa) — billing-bug-class UX.
        XCTAssertEqual(
            PaywallView.tier(forPurchasedProductID: StirProduct.proAnnual.rawValue),
            .pro,
        )
        XCTAssertEqual(
            PaywallView.tier(forPurchasedProductID: StirProduct.proMonthly.rawValue),
            .pro,
        )
    }

    func test_tierForPurchasedProductID_resolvesPremiumSKUs() {
        XCTAssertEqual(
            PaywallView.tier(forPurchasedProductID: StirProduct.premiumMonthly.rawValue),
            .premium,
        )
        XCTAssertEqual(
            PaywallView.tier(forPurchasedProductID: StirProduct.premiumAnnualTrial7.rawValue),
            .premium,
        )
    }

    func test_tierForPurchasedProductID_unknownSKUFallsBackToPro() {
        // SCA-337: an unknown SKU (future promo, sandbox-only, RC-renamed
        // productID) defaults to .pro so the welcome copy still matches
        // the primary CTA. The helper also emits a Logger.paywall warning
        // — verified at the call site, not testable here without log
        // capture, but documented for grep traceability.
        XCTAssertEqual(
            PaywallView.tier(forPurchasedProductID: "stir.unknown.future.sku"),
            .pro,
        )
        XCTAssertEqual(
            PaywallView.tier(forPurchasedProductID: ""),
            .pro,
            "empty string falls through StirProduct(rawValue:) and hits the fallback",
        )
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
            standingPantryCap: 25,
            quotas: [],
        ))
        return PaywallViewModel(
            trigger: .settingsUpgrade,
            service: service,
            entitlements: entitlements,
            onEntitlementRefreshRequested: onRefresh,
        )
    }

    private static func samplePackage(
        _ product: StirProduct,
        eligibility: IntroEligibility? = nil,
    ) -> PaywallPackage {
        // Default eligibility tracks the product's intro-offer shape:
        // trial-bearing → `.unknown` (View renders trial copy per RC
        // convention; eligibility query lands in production), non-trial
        // → `.noOffer`. Tests can override either way for negative cases.
        //
        // SCA-294: trial-bearing SKU is now `.proAnnual` ($139.99), not
        // `.premiumAnnualTrial7`. The `.trial7` suffix on the Premium
        // SKU is historical (Apple doesn't allow productID renames).
        let isTrialBearing = product == .proAnnual
        let resolved = eligibility ?? (isTrialBearing ? .unknown : .noOffer)
        let displayPrice: String
        switch product {
        case .proAnnual:           displayPrice = "$139.99"
        case .premiumAnnualTrial7: displayPrice = "$69.99"
        case .proMonthly:          displayPrice = "$14.99"
        case .premiumMonthly:      displayPrice = "$9.99"
        }
        return PaywallPackage(
            productID: product.rawValue,
            displayPrice: displayPrice,
            periodDescription: product.rawValue.contains("annual") ? "year" : "month",
            introOfferDescription: isTrialBearing
                ? "7-day free trial, then $139.99/year" : nil,
            tier: product.tier,
            introEligibility: resolved,
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

// MARK: - CountingMockRevenueCatService

/// Mock that counts offerings fetches — used to verify the concurrent-load
/// guard in PaywallViewModel.load().
final class CountingMockRevenueCatService: RevenueCatPurchasing, @unchecked Sendable {
    var offeringsResult: Result<PaywallOfferings, Error> = .success(.init(packages: []))
    private(set) var offeringsCallCount = 0

    func offerings() async throws -> PaywallOfferings {
        offeringsCallCount += 1
        switch offeringsResult {
        case .success(let off): return off
        case .failure(let err): throw err
        }
    }

    func purchase(productID: String) async throws -> PurchaseOutcome { .userCancelled }
    func restorePurchases() async throws -> RestoreOutcome { .nothingToRestore }
    func logIn(canonicalUserKey: String) async throws {}
    func startObserving(onChange: @escaping @Sendable () async -> Void) async {}
}
