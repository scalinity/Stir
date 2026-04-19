// PaywallViewModel
//
// State machine driving PaywallView. Decoupled from RevenueCat via the
// `RevenueCatPurchasing` protocol so unit tests can stub the commerce path.
// Emits spec §15 telemetry at every meaningful transition; property shapes
// go through `BillingTelemetryProperties` so the snapshot test catches
// drift.
//
// State transitions (post step-5 review fixes):
//
//   idle
//     ↓ (load)
//   loading
//     ↓ (offerings OK)         ↓ (offerings fail)
//   displaying(offerings)      failedToLoad(PayError)
//     ↓ (user taps Subscribe from displaying OR purchaseFailed "Try Again")
//   purchasing(productID)
//     ↓ (succeeded)    ↓ (cancelled)            ↓ (pending)         ↓ (failed)
//   succeeded          displaying(cached)       purchasePending     purchaseFailed
//                      (via cached offerings,
//                       NOT .idle)
//
// succeeded → view dismisses itself + `onEntitlementRefreshRequested` fires
// so the coordinator pulls the new entitlement from Supabase.
//
// NOTE on `cachedOfferings`: the state enum can't carry offerings into
// `purchasing` / `purchaseFailed` / `purchasePending` while also remaining
// a flat state machine. A separate cached-offerings field outlives state
// transitions so cancel / Try Again / dismissError can all route back to
// `.displaying(cached)` without a re-fetch. This was the source of a
// paywall regression where cancel landed the user in `.idle` and the view
// never recovered (no `.task` re-fire while still presented).

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

    /// The most-recently-fetched offerings. Survives state transitions so
    /// cancel / Try Again / dismissError can restore `.displaying(cached)`
    /// without a re-fetch. Nil only before the first successful `load()`.
    private var cachedOfferings: PaywallOfferings?

    /// Whether a purchase reached `.succeeded` in this VM's lifetime.
    /// RootView's onDisappear reads this (via `didSucceed`) instead of
    /// re-deriving success from entitlements, which lag behind the
    /// webhook→Supabase hop.
    private(set) var didSucceed: Bool = false

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
            cachedOfferings = offerings
            state = .displaying(offerings)
        } catch let error as PayError {
            Logger.paywall.warning(
                "offerings load failed: \(String(describing: error), privacy: .public)",
            )
            state = .failedToLoad(error)
        } catch {
            Logger.paywall.warning(
                "offerings load failed (generic): \(error.localizedDescription, privacy: .public)",
            )
            state = .failedToLoad(.generic(description: error.localizedDescription))
        }
    }

    // MARK: - Purchase

    /// Initiate a purchase. Allowed entry points:
    ///   - `.displaying(_)` — normal path
    ///   - `.purchaseFailed(_, _)` — "Try Again" button on the failure screen.
    ///     Earlier version guarded to only `.displaying` here, which silently
    ///     no-op'd the Try Again tap.
    func purchase(productID: String) async {
        switch state {
        case .displaying, .purchaseFailed:
            break
        default:
            return
        }
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
            didSucceed = true
            state = .succeeded(productID: product)
            onEntitlementRefreshRequested()

        case .userCancelled:
            // Silent return to the paywall with cached offerings — no PAY-01,
            // no event. (Drop-off metric is paywall_viewed without
            // purchase_started.) Falling back to `.idle` would blank the
            // paywall and force a second `load()` that the view's one-shot
            // `.task` modifier never re-fires.
            state = .displaying(cachedOfferings ?? PaywallOfferings(packages: []))

        case .pending:
            state = .purchasePending(productID: productID)
            // The user won't be charged until Apple approves (Ask-to-Buy).
            // Webhook will fire when that happens.

        case .failed(let error):
            // Observability: failed purchases are rare but high-signal.
            // Emit at error severity so Sentry picks them up for
            // alerting on store-layer regressions (iOS updates, RC
            // outages, merchant-id changes).
            Logger.paywall.error(
                "purchase failed sku=\(productID, privacy: .public) error=\(String(describing: error), privacy: .public)",
            )
            state = .purchaseFailed(productID: productID, error: error)
        }
    }

    /// Return to the offerings after dismissing a transient error state.
    /// Uses the cached offerings so we don't force a round-trip just to
    /// re-render the same buttons.
    func dismissError() {
        guard case .purchaseFailed = state else { return }
        state = .displaying(cachedOfferings ?? PaywallOfferings(packages: []))
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
        switch outcome {
        case .restored:
            didSucceed = true
            onEntitlementRefreshRequested()
        case .failed(let error):
            Logger.paywall.warning(
                "restore failed: \(String(describing: error), privacy: .public)",
            )
        case .nothingToRestore:
            break
        }
        return outcome
    }

    // MARK: - Helpers

    /// Currently-rendered offerings. Reads `cachedOfferings` so the paywall
    /// can show real prices during `.purchasing`, `.purchaseFailed`, etc.
    /// (previous version collapsed to empty during these states, which
    /// visually looked like every button became "unavailable").
    func currentOfferings() -> PaywallOfferings? {
        if case .displaying(let off) = state { return off }
        return cachedOfferings
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
