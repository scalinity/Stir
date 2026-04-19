// PaywallViewModel
//
// State machine driving PaywallView. Decoupled from RevenueCat via the
// `RevenueCatPurchasing` protocol so unit tests can stub the commerce path.
// Emits spec §15 telemetry at every meaningful transition; property shapes
// go through `BillingTelemetryProperties` so the snapshot test catches
// drift.
//
// State transitions:
//
//   idle
//     ↓ (load)
//   loading
//     ↓ (offerings OK)         ↓ (offerings fail)
//   displaying(offerings)      failedToLoad(PayError)
//     ↓ (user taps Subscribe)
//   purchasing(productID)
//     ↓ (succeeded)     ↓ (cancelled)    ↓ (pending)        ↓ (failed)
//   succeeded           displaying       displayingPending  purchaseFailed
//
// succeeded → view dismisses itself + posts EntitlementRefreshNotification
// so the coordinator pulls the new entitlement from Supabase.

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class PaywallViewModel {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case displaying(PaywallOfferings)
        case purchasing(productID: String)
        case succeeded(productID: String)
        case purchasePending(productID: String)
        case purchaseFailed(productID: String, error: PayError)
        case failedToLoad(PayError)
    }

    private(set) var state: State = .idle
    let trigger: PaywallTrigger
    private let service: any RevenueCatPurchasing
    private let entitlements: EntitlementService
    private let telemetry: PostHogClient
    private let onEntitlementRefreshRequested: @Sendable () -> Void

    /// Whether the user has already seen `paywall_viewed` this session for
    /// this trigger. Prevents double-emission if the VM reloads (e.g. the
    /// Retry path on failedToLoad).
    private var didEmitViewed = false

    init(
        trigger: PaywallTrigger,
        service: any RevenueCatPurchasing,
        entitlements: EntitlementService,
        telemetry: PostHogClient = .shared,
        onEntitlementRefreshRequested: @escaping @Sendable () -> Void,
    ) {
        self.trigger = trigger
        self.service = service
        self.entitlements = entitlements
        self.telemetry = telemetry
        self.onEntitlementRefreshRequested = onEntitlementRefreshRequested
    }

    // MARK: - Load

    func load() async {
        if case .loading = state { return }  // guard concurrent retaps
        state = .loading
        emitPaywallViewedIfNeeded()

        do {
            let offerings = try await service.offerings()
            state = .displaying(offerings)
        } catch let error as PayError {
            Logger.paywall.warning(
                "offerings load failed: \(String(describing: error), privacy: .public)",
            )
            state = .failedToLoad(error)
        } catch {
            state = .failedToLoad(.generic(description: error.localizedDescription))
        }
    }

    // MARK: - Purchase

    func purchase(productID: String) async {
        guard case .displaying = state else { return }
        state = .purchasing(productID: productID)

        telemetry.capture(.purchaseStarted, properties: BillingTelemetryProperties.purchaseStarted(
            sku: productID, origin: trigger,
        ))

        let outcome: PurchaseOutcome
        do {
            outcome = try await service.purchase(productID: productID)
        } catch let error as PayError {
            outcome = .failed(error)
        } catch {
            outcome = .failed(.generic(description: error.localizedDescription))
        }

        switch outcome {
        case .succeeded(let product, let trial, let introOffer, let priceDisplay):
            telemetry.capture(.purchaseCompleted, properties: BillingTelemetryProperties.purchaseCompleted(
                sku: product,
                priceDisplay: priceDisplay,
                trial: trial,
                introOffer: introOffer,
            ))
            if trial {
                telemetry.capture(.trialStarted, properties: BillingTelemetryProperties.trialStarted(
                    sku: product, trigger: trigger,
                ))
            }
            state = .succeeded(productID: product)
            onEntitlementRefreshRequested()

        case .userCancelled:
            // Silent return to the paywall — no PAY-01, no event.
            // (Drop-off metric is paywall_viewed without purchase_started.)
            if let offerings = currentOfferings() {
                state = .displaying(offerings)
            } else {
                state = .idle
            }

        case .pending:
            state = .purchasePending(productID: productID)
            // The user won't be charged until Apple approves (Ask-to-Buy).
            // Webhook will fire when that happens.

        case .failed(let error):
            state = .purchaseFailed(productID: productID, error: error)
        }
    }

    /// Return to the offerings after dismissing a transient error state.
    func dismissError() {
        guard case .purchaseFailed = state else { return }
        if let offerings = currentOfferings() {
            state = .displaying(offerings)
        } else {
            state = .idle
        }
    }

    // MARK: - Restore

    /// Fire a restore from the paywall's Restore Purchases button. Called
    /// from Settings Restore too (via `onRestoreTapped` in
    /// SettingsRootView) — origin parameterized.
    @discardableResult
    func restore(origin: RestoreOrigin) async -> RestoreOutcome {
        telemetry.capture(.restorePurchasesTapped, properties: BillingTelemetryProperties.restorePurchasesTapped(
            origin: origin,
        ))
        let outcome: RestoreOutcome
        do {
            outcome = try await service.restorePurchases()
        } catch let error as PayError {
            outcome = .failed(error)
        } catch {
            outcome = .failed(.generic(description: error.localizedDescription))
        }
        if case .restored = outcome {
            onEntitlementRefreshRequested()
        }
        return outcome
    }

    // MARK: - Helpers

    private func currentOfferings() -> PaywallOfferings? {
        switch state {
        case .displaying(let off): return off
        case .purchasing, .purchaseFailed, .purchasePending, .succeeded:
            // VM tracks the last-seen offerings via state; re-derive from a
            // cached snapshot.
            return nil
        default: return nil
        }
    }

    private func emitPaywallViewedIfNeeded() {
        guard !didEmitViewed else { return }
        didEmitViewed = true
        telemetry.capture(.paywallViewed, properties: BillingTelemetryProperties.paywallViewed(
            trigger: trigger,
            variant: entitlements.flagBool(forKey: "paywall_variant").map { $0 ? "variant_b" : "variant_a" },
            currentTier: entitlements.tier,
        ))
    }
}

extension Logger {
    static let paywall = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "paywall",
    )
}
