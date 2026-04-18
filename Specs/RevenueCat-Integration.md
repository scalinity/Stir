# RevenueCat SDK Integration Spec — Stir

> **⚠ DIVERGES FROM `Specs/Stir-Full-Spec.md` AND `CLAUDE.md` — NEEDS REFRESH BEFORE STEP 5**
>
> This document still describes a 2-product (`monthly`, `yearly`) / single-`Stir Pro` entitlement model. The authoritative product spec and `CLAUDE.md` were subsequently updated to four SKUs (`stir.premium.monthly`, `stir.premium.annual.trial7`, `stir.pro.monthly`, `stir.pro.annual`) with three tiers (Free / Premium / Pro). When RevenueCat wiring lands in **step 5**, this doc is to be rewritten against the 4-SKU / 3-tier model before any code changes. Step 1 (backend schema) uses `{free, premium, pro}` per the main spec.

**Status:** Draft (stale vs main spec — see warning above)
**Owner:** Stir iOS
**Last updated:** 2026-04-17
**Platforms:** iOS 15+ (iOS 16+ recommended for full Customer Center support)
**SDK:** [`purchases-ios-spm`](https://github.com/RevenueCat/purchases-ios-spm.git) v5+
**Language:** Swift / SwiftUI, StoreKit 2, async/await

---

## 1. Goals

1. Monetize Stir via auto-renewing subscriptions (yearly + monthly).
2. Gate all premium functionality behind a single entitlement: **`Stir Pro`**.
3. Present a dashboard-configured paywall with zero hand-rolled subscription UI.
4. Let users self-serve cancellation, refund requests, and billing recovery via RevenueCat Customer Center.
5. Keep the app's subscription state reactive and declarative — no manual syncing, no `useEffect`-style polling.

## 2. Non-goals

- Custom paywall UI (use RevenueCat's Paywall Editor output).
- Client-side receipt validation (trust `CustomerInfo.entitlements`).
- Promo codes / lifetime / consumable products (subscriptions only).
- Server-to-server webhook integration (future spec).

---

## 3. Configuration

### 3.1 SDK Keys

| Environment | Key |
|---|---|
| Development / TestFlight internal | `test_RYLCWrRtpWKrmbbFvwTyaBHEldz` (public SDK key) |
| Production | `appl_…` (to be added before App Store submission) |

Keys must be **public** SDK keys. Secret keys never ship in the app binary. Store the production key in an `xcconfig` or `Info.plist` build setting keyed on `CONFIGURATION` so TestFlight and App Store builds pick up the right value.

### 3.2 Dashboard Entities

Configure in the RevenueCat dashboard before shipping:

**Products** (IDs must match App Store Connect exactly):
- `yearly` — auto-renewing yearly subscription
- `monthly` — auto-renewing monthly subscription

**Offering:** `default` (marked **Current**)

| Package | RevenueCat ID | Store Product |
|---|---|---|
| Annual | `$rc_annual` | `yearly` |
| Monthly | `$rc_monthly` | `monthly` |

**Entitlement:** `Stir Pro` — attached to both `yearly` and `monthly`.

**Paywall:** built in the Paywall Editor against the `default` offering; includes restore + terms links.

**Customer Center:** enabled and configured (cancellation survey, refund flow, promotional offers).

### 3.3 App Store Connect

- One Subscription Group containing both `yearly` and `monthly`.
- StoreKit configuration file committed to the repo for simulator testing, synced with App Store Connect.

---

## 4. SDK Installation

Install via Swift Package Manager in Xcode:

1. **File → Add Package Dependencies…**
2. URL: `https://github.com/RevenueCat/purchases-ios-spm.git`
3. Dependency Rule: **Up to Next Major Version**, starting at `5.0.0`
4. Add both products to the Stir target:
   - `RevenueCat` — core SDK
   - `RevenueCatUI` — `PaywallView`, `CustomerCenterView`, `.presentPaywallIfNeeded()`

---

## 5. Architecture

```
┌───────────────────────────────────────────────────────┐
│ StirApp                                                │
│   └─ Purchases.configure(…)  // at launch              │
│   └─ SubscriptionManager (StateObject, injected)       │
│        ├─ customerInfoStream → @Published customerInfo │
│        └─ offerings() → @Published offerings           │
└───────────────────────────────────────────────────────┘
             │
             ▼
 ┌─────────────────────────┐    ┌─────────────────────────┐
 │ isProActive gate        │    │ StirPaywallSheet        │
 │  - if true → content    │    │  - PaywallView          │
 │  - else → show paywall  │    │  - onPurchaseCompleted  │
 └─────────────────────────┘    └─────────────────────────┘
                                          │
                                          ▼
                                ┌─────────────────────────┐
                                │ CustomerCenterView      │
                                │  (Settings → Manage)    │
                                └─────────────────────────┘
```

**Principles**
- `SubscriptionManager` is the single source of truth for Pro state.
- Views derive state; they never sync it. `isProActive` is a computed property off `customerInfo`.
- `customerInfoStream` drives all updates (purchases, restores, expirations, cross-device changes).
- No direct StoreKit access in the app — all purchases flow through RevenueCat.

---

## 6. Implementation

### 6.1 App Entry — `StirApp.swift`

```swift
import SwiftUI
import RevenueCat

@main
struct StirApp: App {
    @StateObject private var subscriptions = SubscriptionManager()

    init() {
        #if DEBUG
        Purchases.logLevel = .debug
        #endif

        Purchases.configure(
            with: Configuration.Builder(withAPIKey: "test_RYLCWrRtpWKrmbbFvwTyaBHEldz")
                .with(storeKitVersion: .storeKit2)
                .build()
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(subscriptions)
                .task { await subscriptions.start() }
        }
    }
}
```

### 6.2 Subscription Manager — `SubscriptionManager.swift`

```swift
import Foundation
import RevenueCat

@MainActor
final class SubscriptionManager: ObservableObject {
    static let proEntitlementID = "Stir Pro"

    @Published private(set) var customerInfo: CustomerInfo?
    @Published private(set) var offerings: Offerings?
    @Published private(set) var isLoading = false
    @Published var lastError: String?

    var isProActive: Bool {
        customerInfo?.entitlements[Self.proEntitlementID]?.isActive == true
    }

    var activeProEntitlement: EntitlementInfo? {
        customerInfo?.entitlements[Self.proEntitlementID]
    }

    func start() async {
        await refreshOfferings()
        await refreshCustomerInfo()
        for await info in Purchases.shared.customerInfoStream {
            self.customerInfo = info
        }
    }

    func refreshCustomerInfo() async {
        do { customerInfo = try await Purchases.shared.customerInfo() }
        catch { lastError = error.localizedDescription }
    }

    func refreshOfferings() async {
        do { offerings = try await Purchases.shared.offerings() }
        catch { lastError = error.localizedDescription }
    }

    @discardableResult
    func purchase(_ package: Package) async -> Bool {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            if result.userCancelled { return false }
            customerInfo = result.customerInfo
            return result.customerInfo.entitlements[Self.proEntitlementID]?.isActive == true
        } catch let error as ErrorCode where error == .purchaseCancelledError {
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func restore() async {
        isLoading = true
        defer { isLoading = false }
        do { customerInfo = try await Purchases.shared.restorePurchases() }
        catch { lastError = error.localizedDescription }
    }
}
```

### 6.3 Paywall Sheet — `StirPaywallSheet.swift`

```swift
import SwiftUI
import RevenueCat
import RevenueCatUI

struct StirPaywallSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PaywallView(displayCloseButton: true)
            .onPurchaseCompleted { customerInfo in
                if customerInfo.entitlements[SubscriptionManager.proEntitlementID]?.isActive == true {
                    dismiss()
                }
            }
            .onRestoreCompleted { customerInfo in
                if customerInfo.entitlements[SubscriptionManager.proEntitlementID]?.isActive == true {
                    dismiss()
                }
            }
    }
}
```

Alternative, entitlement-gated one-liner on any Pro-only screen:

```swift
import RevenueCatUI

ContentView()
    .presentPaywallIfNeeded(
        requiredEntitlementIdentifier: SubscriptionManager.proEntitlementID
    )
```

### 6.4 Gating Pro Features

```swift
struct ProFeatureView: View {
    @EnvironmentObject private var subs: SubscriptionManager
    @State private var showPaywall = false

    var body: some View {
        Group {
            if subs.isProActive {
                PremiumContentView()
            } else {
                LockedView { showPaywall = true }
            }
        }
        .sheet(isPresented: $showPaywall) { StirPaywallSheet() }
    }
}
```

### 6.5 Settings + Customer Center — `SettingsView.swift`

```swift
import SwiftUI
import RevenueCatUI

struct SettingsView: View {
    @EnvironmentObject private var subs: SubscriptionManager
    @State private var showCustomerCenter = false
    @State private var showPaywall = false

    var body: some View {
        List {
            Section("Subscription") {
                if subs.isProActive {
                    LabeledContent("Plan", value: "Stir Pro")
                    if let renews = subs.activeProEntitlement?.expirationDate {
                        LabeledContent("Renews", value: renews.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Manage Subscription") { showCustomerCenter = true }
                } else {
                    Button("Upgrade to Stir Pro") { showPaywall = true }
                }
                Button("Restore Purchases") {
                    Task { await subs.restore() }
                }
            }
        }
        .sheet(isPresented: $showPaywall) { StirPaywallSheet() }
        .sheet(isPresented: $showCustomerCenter) { CustomerCenterView() }
    }
}
```

---

## 7. Error Handling

| Condition | Behavior |
|---|---|
| `ErrorCode.purchaseCancelledError` | Silent. User tapped Cancel. |
| `ErrorCode.paymentPendingError` | Do **not** unlock Pro. Show "Purchase pending approval" toast. Wait for `customerInfoStream` to emit an active entitlement. |
| `ErrorCode.networkError` | Show retry. Do not revoke Pro if `customerInfo` was previously cached. |
| `ErrorCode.productNotAvailableForPurchaseError` | Log + show generic "Not available" message. Check ASC / RevenueCat product config. |
| Any other error | Surface `error.localizedDescription` via toast; log full error for diagnostics. |

**Rules**
- No empty `catch {}`.
- No client-side receipt parsing.
- Any server-gated premium API must verify entitlements via RevenueCat's REST API from the backend, not trust the client.

---

## 8. State & Reactivity

- `customerInfoStream` emits on purchase, restore, expiration, subscription changes, and cross-device updates.
- `@Published customerInfo` drives all SwiftUI redraws — views never call `.refreshCustomerInfo()` on appear.
- `isProActive` is **computed**, never stored. Storing it would create drift.

This satisfies Stir's "derive, don't sync" React/SwiftUI architecture rule.

---

## 9. Testing

### 9.1 Local (Simulator)
- Commit a `Configuration.storekit` file with `yearly` and `monthly` matching ASC.
- In the Xcode scheme → Run → Options → **StoreKit Configuration**: select the file.
- Verify purchase → `isProActive` flips true → paywall dismisses → locked screens unlock without reload.

### 9.2 Device
- Sandbox Apple ID, real device.
- Verify: purchase, restore on fresh install, cross-device sync, expiration (use Settings → App Store → Sandbox Account → rewind time).
- Verify Customer Center: cancel flow, refund request, billing recovery.

### 9.3 Acceptance Criteria
- [ ] Fresh install → `isProActive == false`.
- [ ] Successful yearly purchase → `isProActive == true` within 1s, paywall auto-dismisses.
- [ ] Successful monthly purchase → same as above.
- [ ] Restore on reinstall → `isProActive == true` for a prior subscriber.
- [ ] Cancel in Customer Center → Pro remains active until `expirationDate`; flips false on expiration.
- [ ] Network offline after launch → cached entitlement still unlocks Pro.
- [ ] Pending purchase (Ask to Buy) → no unlock until approval.
- [ ] Production build uses `appl_…` key, not `test_…`.

---

## 10. Rollout Checklist

1. [ ] Add SPM package + `RevenueCat`, `RevenueCatUI` to Stir target.
2. [ ] Implement `StirApp`, `SubscriptionManager`, `StirPaywallSheet`, `SettingsView`.
3. [ ] Configure products, offering, entitlement, paywall, Customer Center in dashboard.
4. [ ] Add `yearly` + `monthly` subscriptions in App Store Connect, same Subscription Group.
5. [ ] Commit StoreKit configuration file for simulator testing.
6. [ ] Wire `isProActive` gating into every premium screen.
7. [ ] Test matrix in §9 against sandbox.
8. [ ] Swap `test_RYLCWrRtpWKrmbbFvwTyaBHEldz` → production `appl_…` key via xcconfig before App Store submission.
9. [ ] Ship.

---

## 11. References

- Installation: https://www.revenuecat.com/docs/getting-started/installation/ios
- SwiftUI Paywalls: https://www.revenuecat.com/docs/tools/paywalls
- Customer Center: https://www.revenuecat.com/docs/tools/customer-center
- SDK repo: https://github.com/RevenueCat/purchases-ios-spm
