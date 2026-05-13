// RevenueCatService
//
// Actor-isolated facade over RevenueCat's `Purchases` SDK.
//
// Responsibilities:
//   - configure() called once at launch with the public SDK API key.
//   - logIn(canonicalUserKey:) called whenever identity resolves (bootstrap
//     + CloudKit account flip). RC aliases server-side; iOS does NOT do
//     identity merging — that's Supabase's job.
//   - offerings() returns simplified `PaywallOfferings` DTOs so view models
//     can stay ignorant of RC types and be unit-testable.
//   - purchase(...) / restorePurchases() return typed outcomes.
//   - observeCustomerInfo() surfaces changes WITHOUT reading entitlements
//     directly — the observer's only job is to trigger a `configBootstrap`
//     on the coordinator so Supabase (the source of truth) catches up.
//
// CLAUDE.md §Billing: "Supabase entitlement_snapshots is the source of truth.
// RC customerInfoStream only triggers a refresh of that source — never read
// from RC state directly in feature-gate code." Respected by design here:
// no `isProActive`-style getter that views could read.

import Foundation
import OSLog
import RevenueCat

// ---------------------------------------------------------------------------
// Protocol — makes PaywallViewModel testable without a live RC SDK.
// ---------------------------------------------------------------------------

protocol RevenueCatPurchasing: Sendable {
    /// Fetch the current offering from RC dashboard config.
    func offerings() async throws -> PaywallOfferings

    /// Initiate a purchase. The VM maps the outcome onto its state machine.
    func purchase(productID: String) async throws -> PurchaseOutcome

    /// Restore prior purchases for this Apple ID. Returns whether anything
    /// active was found — useful for toast copy.
    func restorePurchases() async throws -> RestoreOutcome

    /// Re-alias the RC user to the new canonical key. No-op if already that key.
    func logIn(canonicalUserKey: String) async throws

    /// Start observing `customerInfoStream`. The callback runs whenever RC
    /// reports an update. The coordinator uses this to trigger a Supabase
    /// configBootstrap refresh — iOS never reads entitlement state out of
    /// RC directly.
    ///
    /// Calling twice cancels the prior observer. Protocol-level declaration
    /// (rather than a concrete-type cast in the coordinator) so test doubles
    /// can participate — previously a `revenueCat as? RevenueCatService`
    /// downcast silently skipped observation in any non-production wiring.
    func startObserving(onChange: @escaping @Sendable () async -> Void) async
}

// ---------------------------------------------------------------------------
// DTOs — RC-agnostic shapes the UI + tests consume.
// ---------------------------------------------------------------------------

/// Simplified offerings: just the packages the paywall needs to render.
struct PaywallOfferings: Sendable, Equatable {
    var packages: [PaywallPackage]

    /// Helper for the primary CTA — the 7-day trial annual.
    ///
    /// SCA-294 (2026-05-09): trial migrated from `stir.premium.annual.trial7`
    /// to `stir.pro.annual` for higher per-converted-user ROI ($139.99 vs
    /// $69.99 AOV). The `.trial7` suffix on the Premium SKU's productID is
    /// now historical — Apple doesn't allow productID renames, so we live
    /// with the misnomer until a future IAP cleanup. The `StirProduct` enum
    /// case name `premiumAnnualTrial7` is similarly historical; what carries
    /// the trial is whichever SKU `primaryTrialPackage` resolves.
    var primaryTrialPackage: PaywallPackage? {
        packages.first { $0.productID == StirProduct.proAnnual.rawValue }
    }

    /// Helper for the monthly Premium secondary CTA.
    var premiumMonthlyPackage: PaywallPackage? {
        packages.first { $0.productID == StirProduct.premiumMonthly.rawValue }
    }

    /// Premium annual lookup. The `.trial7` raw-value suffix is historical
    /// (SCA-294 migrated the trial off this SKU) — Apple doesn't allow
    /// productID renames. PaywallView renders this as a flat-priced annual
    /// option alongside the Pro trial.
    var premiumAnnualPackage: PaywallPackage? {
        packages.first { $0.productID == StirProduct.premiumAnnualTrial7.rawValue }
    }

    var proMonthlyPackage: PaywallPackage? {
        packages.first { $0.productID == StirProduct.proMonthly.rawValue }
    }

    /// Pro annual lookup by tier + period. **Currently aliases
    /// `primaryTrialPackage`** (see above) because SCA-294 put the trial
    /// on the Pro annual SKU. Kept as a distinct helper for callers that
    /// want "the Pro annual package" semantically (e.g. ProComparisonSheet's
    /// Pro column) without coupling to "the trial-bearing one" — if a future
    /// SCA migrates the trial elsewhere, `primaryTrialPackage` updates
    /// alone and this helper stays correct.
    ///
    /// SCA-342 — load-bearing alias: this comment is the only signal that
    /// `proAnnualPackage` and `primaryTrialPackage` resolve to the same
    /// SKU today. If the comment is lost in a future reformatting pass,
    /// the alias relationship becomes invisible and the next SCA migrating
    /// the trial may "fix" one helper and leave the other diverged. Keep
    /// the cross-reference to `primaryTrialPackage` intact.
    var proAnnualPackage: PaywallPackage? {
        packages.first { $0.productID == StirProduct.proAnnual.rawValue }
    }
}

struct PaywallPackage: Sendable, Equatable, Identifiable {
    var id: String { productID }
    let productID: String
    /// Localized price string from the store (e.g. "$69.99").
    let displayPrice: String
    /// Subscription period — "month" | "year" | custom.
    let periodDescription: String
    /// e.g. "7-day free trial, then $69.99/year" or nil when no intro.
    let introOfferDescription: String?
    /// Tier this product maps to. Derived, not from RC.
    let tier: Tier
    /// Whether THIS Apple ID is eligible for the product's intro offer (per
    /// Apple's "one trial per Apple ID per subscription group" rule). The
    /// existence of `introOfferDescription` only reflects the offer's
    /// definition in App Store Connect — it does NOT reflect per-user
    /// eligibility. View layer must branch CTA + disclosure copy on this
    /// field so an ineligible user isn't shown "7-day free trial" copy
    /// before being charged the full price.
    ///
    /// Default `.unknown` keeps existing call sites + tests source-compatible
    /// (per RC convention, treat unknown as if eligible — show the trial copy).
    var introEligibility: IntroEligibility = .unknown
}

/// Per-Apple-ID intro-offer eligibility, sourced from
/// `Purchases.checkTrialOrIntroDiscountEligibility(productIdentifiers:)`.
/// Apple enforces "one trial per Apple ID per subscription group"; ineligible
/// users still see RC's offer DEFINITION on `StoreProduct.introductoryDiscount`,
/// so we MUST query this separately to render correct paywall copy.
enum IntroEligibility: Sendable, Equatable {
    /// User can claim the intro offer (free trial, intro price, etc.).
    case eligible
    /// User has already consumed the intro offer; Apple charges full price.
    case ineligible
    /// RC SDK couldn't determine eligibility (cold cache, sign-in flap, etc.).
    /// Treat as eligible per RC convention — Apple is the final arbiter.
    case unknown
    /// Product has no intro offer defined. Distinct from `.eligible` so
    /// the View can elide "free trial" framing entirely.
    case noOffer
}

enum PurchaseOutcome: Sendable, Equatable {
    case succeeded(productID: String, trial: Bool, introOffer: Bool, priceDisplay: String)
    /// User tapped Cancel in the sheet; no error surfaced.
    case userCancelled
    /// Pending parental approval or Ask-to-Buy. Do NOT unlock.
    case pending
    case failed(PayError)
}

enum RestoreOutcome: Sendable, Equatable {
    /// At least one active entitlement found and restored.
    case restored
    /// No active purchase tied to this Apple ID.
    case nothingToRestore
    case failed(PayError)
}

/// User-facing purchase error (PAY-01).
enum PayError: Error, Sendable, Equatable {
    case networkUnreachable
    case productNotAvailable(productID: String)
    case paymentInvalid
    case paymentNotAllowed
    case storeProblem(description: String)
    case generic(description: String)
    /// Offerings load exceeded `PaywallViewModel.offeringsLoadTimeoutSec`.
    /// Distinguishes a wedged RC CDN (no error surfaced) from a clean
    /// network failure — the user-facing copy can suggest "try again"
    /// instead of "check your connection."
    case timeout
}

// ---------------------------------------------------------------------------
// StirProduct — canonical enum of the 4 SKUs. Centralizes the ID literals.
// ---------------------------------------------------------------------------

enum StirProduct: String, CaseIterable, Sendable {
    case premiumMonthly       = "stir.premium.monthly"
    case premiumAnnualTrial7  = "stir.premium.annual.trial7"
    case proMonthly           = "stir.pro.monthly"
    case proAnnual            = "stir.pro.annual"

    var tier: Tier {
        switch self {
        case .premiumMonthly, .premiumAnnualTrial7: return .premium
        case .proMonthly, .proAnnual:               return .pro
        }
    }
}

// ---------------------------------------------------------------------------
// Actor implementation
// ---------------------------------------------------------------------------

actor RevenueCatService: RevenueCatPurchasing {
    /// Process-wide singleton. `configure()` is idempotent.
    static let shared = RevenueCatService()

    /// Whether `Purchases.configure` has been called on this process. Kept
    /// here (not via `Purchases.isConfigured`) so init-order bugs surface
    /// as Swift runtime errors instead of RC-internal crashes.
    private var isConfigured = false

    /// Last canonical key we issued `logIn` for. Suppresses redundant RC
    /// network calls when identity resolves twice with the same value.
    private var currentAppUserID: String?

    /// Observation task listening to `Purchases.customerInfoStream`. Started
    /// by `startObserving`. Cancelled on deinit / stop.
    private var observationTask: Task<Void, Never>?

    /// RC `Package` cache keyed by productID. Populated by `offerings()`;
    /// consumed by `purchase(productID:)` so a purchase tap doesn't cost
    /// an extra round-trip into the RC SDK to re-resolve the package.
    /// RC's SDK caches offerings internally, but this keeps the lookup
    /// fully in-process (matters for sandbox + offline fallbacks).
    private var cachedPackages: [String: RevenueCat.Package] = [:]

    init() {}

    // MARK: - Configure

    /// Configure the SDK exactly once. Safe to call multiple times — we
    /// guard internally. Call from StirApp.init (or equivalent earliest
    /// launch hook) before any identity resolution so the initial
    /// `logIn` is a no-op rather than a re-aliasing.
    func configure(apiKey: String) {
        guard !isConfigured else { return }
        isConfigured = true

        #if DEBUG
        Purchases.logLevel = .info
        #endif

        _ = Purchases.configure(
            with: Configuration.Builder(withAPIKey: apiKey)
                .with(storeKitVersion: .storeKit2)
                .build(),
        )
        Logger.revenueCat.info("configured (storekit2)")
    }

    // MARK: - Identity

    func logIn(canonicalUserKey: String) async throws {
        guard isConfigured else {
            Logger.revenueCat.error("logIn called before configure — ignoring")
            return
        }
        if currentAppUserID == canonicalUserKey { return }
        do {
            _ = try await Purchases.shared.logIn(canonicalUserKey)
            currentAppUserID = canonicalUserKey
            Logger.revenueCat.info("logged in appUserID=<redacted>")
        } catch {
            Logger.revenueCat.warning(
                "logIn failed: \(error.localizedDescription, privacy: .public)",
            )
            throw error
        }
    }

    // MARK: - Commerce

    func offerings() async throws -> PaywallOfferings {
        guard isConfigured else {
            throw PayError.generic(description: "RC SDK not configured")
        }
        let raw: Offerings
        do {
            raw = try await Purchases.shared.offerings()
        } catch {
            Logger.revenueCat.warning(
                "offerings failed: \(error.localizedDescription, privacy: .public)",
            )
            throw mapRCError(error)
        }

        // RC's `current` offering is the one marked Current in the dashboard.
        // Everything we display comes from its packages; any other offerings
        // (A/B variants) would be picked via feature flag in a later step.
        guard let current = raw.current else {
            Logger.revenueCat.warning("no current offering in RC dashboard — returning empty")
            return PaywallOfferings(packages: [])
        }

        var mapped: [PaywallPackage] = []
        // Reset the cache on every offerings fetch so stale RC Packages
        // from a prior offering (e.g. after a remote config change) don't
        // linger. RC's own caching lives one layer down.
        cachedPackages.removeAll(keepingCapacity: true)
        for package in current.availablePackages {
            let storeProduct = package.storeProduct
            let productID = storeProduct.productIdentifier
            guard let sku = StirProduct(rawValue: productID) else {
                Logger.revenueCat.warning(
                    "unknown product \(productID, privacy: .public) — skipping",
                )
                continue
            }

            let periodDescription = Self.describePeriod(storeProduct)
            let introOfferDescription = Self.describeIntroOffer(storeProduct)

            cachedPackages[productID] = package
            mapped.append(PaywallPackage(
                productID: productID,
                displayPrice: storeProduct.localizedPriceString,
                periodDescription: periodDescription,
                introOfferDescription: introOfferDescription,
                tier: sku.tier,
                introEligibility: introOfferDescription == nil ? .noOffer : .unknown,
            ))
        }

        // Stamp per-Apple-ID intro-offer eligibility onto the packages that
        // carry an offer definition. RC docs note this can take ~700ms cold;
        // we share the existing `PaywallViewModel.withTimeout` 10s window
        // around `offerings()` rather than carving out a separate timeout.
        // Failures are non-fatal — we keep `.unknown` and the View renders
        // the trial copy (matching prior behavior; eligibility check is a
        // refinement, not a load-bearing gate).
        let trialBearingIDs = mapped
            .filter { $0.introEligibility != .noOffer }
            .map { $0.productID }
        if !trialBearingIDs.isEmpty {
            let eligibility = await fetchIntroEligibility(productIDs: trialBearingIDs)
            mapped = mapped.map { package in
                guard let resolved = eligibility[package.productID] else { return package }
                var copy = package
                copy.introEligibility = resolved
                return copy
            }
        }
        return PaywallOfferings(packages: mapped)
    }

    /// Query RC's intro-offer eligibility cache for the given product IDs.
    /// Returns a map keyed by productID; missing entries indicate the SDK
    /// couldn't resolve eligibility for that ID (caller treats as `.unknown`).
    /// Non-throwing — eligibility is best-effort.
    private func fetchIntroEligibility(productIDs: [String]) async -> [String: IntroEligibility] {
        let raw = await Purchases.shared.checkTrialOrIntroDiscountEligibility(
            productIdentifiers: productIDs,
        )
        var result: [String: IntroEligibility] = [:]
        for (productID, value) in raw {
            switch value.status {
            case .eligible:           result[productID] = .eligible
            case .ineligible:         result[productID] = .ineligible
            case .noIntroOfferExists: result[productID] = .noOffer
            case .unknown:            result[productID] = .unknown
            @unknown default:         result[productID] = .unknown
            }
        }
        return result
    }

    func purchase(productID: String) async throws -> PurchaseOutcome {
        guard isConfigured else {
            return .failed(.generic(description: "RC SDK not configured"))
        }
        // Prefer the package cached during the last `offerings()` call.
        // Avoids an extra network round-trip on the purchase-initiation
        // critical path. Falls back to a fresh offerings fetch for the
        // (rare) case where `purchase` is invoked before a cache populates.
        let package: RevenueCat.Package
        if let cached = cachedPackages[productID] {
            package = cached
        } else {
            let offerings: Offerings
            do { offerings = try await Purchases.shared.offerings() }
            catch { return .failed(mapRCError(error)) }

            guard
                let current = offerings.current,
                let resolved = current.availablePackages.first(where: {
                    $0.storeProduct.productIdentifier == productID
                })
            else {
                return .failed(.productNotAvailable(productID: productID))
            }
            package = resolved
        }

        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled {
                return .userCancelled
            }
            // Pending (Ask to Buy) → transaction exists but entitlement not
            // active. Treat as pending; caller must NOT unlock. The webhook
            // will fire when Apple resolves it.
            let info = result.customerInfo
            let entitlement = info.entitlements.active.values.first(where: { ent in
                ent.productIdentifier == productID
            })
            if entitlement == nil {
                // Even on a completed purchase, RC's customerInfo may lag
                // for a moment. Err on the side of "completed" — the
                // webhook handler is the real gate, not this in-process
                // optimism.
                Logger.revenueCat.info("purchase completed but entitlement not yet reflected")
            }
            let product = result.transaction?.productIdentifier ?? productID
            let price = package.storeProduct.localizedPriceString
            // For all Stir SKUs, "intro offer" and "trial" are the same
            // thing: the 7-day free trial on `stir.premium.annual.trial7`.
            // If a future SKU ever ships a non-trial intro (e.g. "first
            // month $1.99"), split these by deriving introOffer from
            // `storeProduct.introductoryDiscount?.paymentMode` independently.
            let trial = Self.hasIntroOffer(package.storeProduct)
            return .succeeded(productID: product, trial: trial, introOffer: trial, priceDisplay: price)
        } catch let error as RevenueCat.ErrorCode where error == .purchaseCancelledError {
            return .userCancelled
        } catch let error as RevenueCat.ErrorCode where error == .paymentPendingError {
            return .pending
        } catch {
            return .failed(mapRCError(error))
        }
    }

    func restorePurchases() async throws -> RestoreOutcome {
        guard isConfigured else { return .failed(.generic(description: "RC SDK not configured")) }
        do {
            let info = try await Purchases.shared.restorePurchases()
            if info.entitlements.active.isEmpty {
                return .nothingToRestore
            }
            return .restored
        } catch {
            return .failed(mapRCError(error))
        }
    }

    // MARK: - Observation

    /// Start observing `customerInfoStream`. The callback runs on a
    /// background task; forward it to @MainActor in the consumer.
    /// Calling `startObserving` twice cancels the prior observer.
    func startObserving(onChange: @escaping @Sendable () async -> Void) {
        observationTask?.cancel()
        observationTask = Task.detached {
            for await _ in Purchases.shared.customerInfoStream {
                await onChange()
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Helpers

    private static func describePeriod(_ product: StoreProduct) -> String {
        guard let period = product.subscriptionPeriod else {
            return ""
        }
        let unit = period.unit
        let value = period.value
        switch (unit, value) {
        case (.month, 1): return "month"
        case (.month, _): return "\(value) months"
        case (.year, 1):  return "year"
        case (.year, _):  return "\(value) years"
        case (.week, 1):  return "week"
        case (.week, _):  return "\(value) weeks"
        case (.day, _):   return "\(value) days"
        @unknown default: return ""
        }
    }

    private static func describeIntroOffer(_ product: StoreProduct) -> String? {
        guard let intro = product.introductoryDiscount else { return nil }
        guard intro.paymentMode == .freeTrial else {
            // Stir uses free trial only; anything else (pay-as-you-go, pay-up-front)
            // is not part of the intended pricing.
            return nil
        }
        let periodUnit = intro.subscriptionPeriod.unit
        let periodValue = intro.subscriptionPeriod.value
        let periodStr: String
        switch (periodUnit, periodValue) {
        case (.day, 7):   periodStr = "7-day"
        case (.day, _):   periodStr = "\(periodValue)-day"
        case (.week, 1):  periodStr = "1-week"
        case (.week, _):  periodStr = "\(periodValue)-week"
        case (.month, 1): periodStr = "1-month"
        case (.month, _): periodStr = "\(periodValue)-month"
        case (.year, _):  periodStr = "\(periodValue)-year"
        @unknown default: periodStr = ""
        }
        return "\(periodStr) free trial, then \(product.localizedPriceString)/\(describePeriod(product))"
    }

    private static func hasIntroOffer(_ product: StoreProduct) -> Bool {
        product.introductoryDiscount?.paymentMode == .freeTrial
    }

    private func mapRCError(_ error: Error) -> PayError {
        if let code = error as? RevenueCat.ErrorCode {
            switch code {
            case .networkError, .offlineConnectionError:
                return .networkUnreachable
            case .productNotAvailableForPurchaseError:
                return .productNotAvailable(productID: "<unknown>")
            case .paymentPendingError:
                // Caller should preferentially return .pending; this is a fallback.
                return .generic(description: "purchase pending")
            case .invalidAppleSubscriptionKeyError, .purchaseInvalidError:
                return .paymentInvalid
            case .purchaseNotAllowedError:
                return .paymentNotAllowed
            case .storeProblemError:
                return .storeProblem(description: error.localizedDescription)
            default:
                return .generic(description: error.localizedDescription)
            }
        }
        return .generic(description: error.localizedDescription)
    }
}

extension Logger {
    static let revenueCat = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.scalinity.stir",
        category: "revenuecat",
    )
}
