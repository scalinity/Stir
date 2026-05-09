# Runbook: RevenueCat + App Store Connect production launch checklist

End-to-end go-live checklist for Stir's monetization stack. Walk this once before the first App Store submission. The code paths are already in production; this runbook covers everything OUTSIDE the codebase — App Store Connect IAP setup, RevenueCat dashboard configuration, secret handoff, and the smoke test that proves the whole loop works against real Apple infra.

**When to follow this runbook:**

- First-time setup before App Store submission.
- After an Apple Developer account migration (the IAPs travel with the bundle ID; the RC↔ASC credential handoff does not).
- After a RevenueCat project re-creation (rare; supports a clean slate if RC state drifts past hand-debuggable).

**When NOT to follow this runbook:**

- Day-to-day deploys. Code, secrets, and webhook delivery are already wired. See `revenuecat-webhook-secret-rotation.md` for the secret-only path.
- Pricing / SKU / entitlement changes. Those go through ADR + Apple price-tier change, not this runbook.

---

## What "ready" means

When you finish this runbook:

- [ ] Apple has approved 4 IAP products in subscription group `stir.subscriptions`.
- [ ] RevenueCat dashboard has the project, products, entitlements, and a **current** Offering with all 4 packages.
- [ ] RevenueCat is authenticated to App Store Connect (App-Specific Shared Secret + In-App Purchase Key).
- [ ] RevenueCat webhook delivers to `https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/revenuecat-webhook` with the matching Authorization header value.
- [ ] `Config.xcconfig` carries the production iOS public SDK key (`appl_…`), not a `test_…` key.
- [ ] A sandbox tester has completed an end-to-end purchase + cancellation + expiration cycle, and the results show up correctly in `entitlement_snapshots` + `webhook_log` + PostHog.

---

## Prerequisites

- [ ] Apple Developer Program membership active for team `25H5DDPKAC` (Daniel).
- [ ] App Store Connect access with App Manager or Admin role for the Stir app record.
- [ ] RevenueCat account; project for Stir created (or you'll create it in step 4).
- [ ] `supabase` CLI linked to prod (`supabase link --project-ref ktqajarcomzplnpbczfo`).
- [ ] Read `Specs/Stir-Full-Spec.md` §9 (Monetization) and `docs/decisions/0015-pricing-and-cohort-economics.md` for the SKU + pricing rationale.
- [ ] Read `docs/decisions/0003-revenuecat-shared-secret-auth.md` for the auth model.

---

## Step 1 — App Store Connect: create the subscription group

App Store Connect → Apps → **Stir** → Monetization → Subscriptions.

1. Click **+** next to Subscription Groups.
2. Reference name: `stir.subscriptions` (mandatory — the iOS bundle ships this string in `Stir.storekit`).
3. Localizations:
   - Display name: `Stir Subscriptions`
   - Description: `Stir subscription tiers`
   - Locale: English (U.S.)
4. **Family Sharing: OFF.** This is invariant per `Specs/Stir-Full-Spec.md` §9.
5. Save.

## Step 2 — App Store Connect: create the 4 IAP products

For each product, App Store Connect → Subscriptions → `stir.subscriptions` → **+** Add Subscription. Match the SKUs, prices, and copy from `Stir.storekit` exactly:

| Product ID                       | Reference name                | Price tier | Period | Display name              | Description (≤ 45 chars) |
| -------------------------------- | ----------------------------- | ---------- | ------ | ------------------------- | ------------------------ |
| `stir.premium.monthly`           | Premium Monthly               | $9.99      | 1 month  | Stir Premium Monthly       | 40 Solves, 13 voice sessions, widgets |
| `stir.premium.annual.trial7`     | Premium Annual (7-day trial)  | $69.99     | 1 year   | Stir Premium Annual        | 40 Solves, 13 voice sessions. 7-day trial |
| `stir.pro.monthly`               | Pro Monthly                   | $14.99     | 1 month  | Stir Pro Monthly           | 120 Solves, 27 voice sessions, multi-image |
| `stir.pro.annual`                | Pro Annual                    | $139.99    | 1 year   | Stir Pro Annual            | 120 Solves, 27 voice sessions, multi-image |

For each product:

- [ ] Localization: English (U.S.) — display name + description (full text from `Stir.storekit` `localizations[].description`).
- [ ] Subscription duration matches the table.
- [ ] Price matches the table (use Apple's price tier picker; verify the tier maps to the dollar amount above).
- [ ] Family Sharing: **off** (inherited from the group, but verify per-product).
- [ ] Review screenshot: 1024×1024+ PNG of the paywall surface where this SKU is sold.
- [ ] Review notes: short paragraph describing what the user gets and how the price is presented.

### Step 2b — Configure the 7-day free trial intro offer (only on `stir.premium.annual.trial7`)

App Store Connect → `stir.premium.annual.trial7` → **+** Subscription Offers → Introductory Offer.

- [ ] Offer type: **Free**
- [ ] Duration: 1 week (7 days)
- [ ] Eligibility: New Subscribers (default)
- [ ] Storefront: All
- [ ] Available start date: today
- [ ] Available end date: leave blank (open-ended)

This MUST exist for the paywall's primary CTA to honor SCA-287's eligibility branching. The other three SKUs have no intro offer.

### Step 2c — Submit IAPs for review

- [ ] Click **Submit for Review** on each product.
- [ ] Apple's review window is typically 24–48h. Plan accordingly.
- [ ] An IAP must be in **Approved** state (or **Ready to Submit** + bundled in a TestFlight build) before sandbox testers can purchase it.

## Step 3 — App Store Connect: generate credentials for RevenueCat

### App-Specific Shared Secret

1. App Store Connect → Apps → Stir → App Information.
2. Scroll to **App-Specific Shared Secret** → **Manage** → **Generate**.
3. Copy the 32-char hex string. Store securely. Apple shows it ONCE.

### In-App Purchase Key

1. App Store Connect → Users and Access → Integrations → **In-App Purchase** (NOT App Store Server API; subtly different page).
2. Click **+** Generate In-App Purchase Key.
3. Name it `RevenueCat — Stir prod`. Download the `.p8` file. Apple shows it ONCE.
4. Note the **Key ID** (10-char alphanumeric) and the **Issuer ID** (UUID, on the page header).

### Sandbox testers

1. App Store Connect → Users and Access → **Sandbox** → Testers.
2. Click **+** Add Tester. Use a fresh email never used as an Apple ID. Pick a strong password.
3. Verify the tester via the email Apple sends.
4. Repeat for at least 2 testers — one to validate the trial-eligible flow, a second to validate the trial-ineligible flow (after the first tester consumes their trial).

---

## Step 4 — RevenueCat dashboard: project + iOS app + products

RevenueCat dashboard → Projects.

1. **Create project** named `Stir` (or verify the existing one). Note the project ID.
2. Within the project: Apps → **+ New** → iOS.
   - App name: `Stir iOS`
   - Bundle ID: paste the production bundle ID from `Stir.xcodeproj`
   - App Store Connect Shared Secret: paste from step 3
   - App Store Connect In-App Purchase Key: upload the `.p8`, paste Key ID + Issuer ID
3. Save. RC validates the credentials by hitting Apple's StoreKit verifyReceipt endpoint behind the scenes.

### Products

RevenueCat → Products → **+ New** for each of the 4 SKUs:

- [ ] `stir.premium.monthly` (App Store: linked to the matching IAP)
- [ ] `stir.premium.annual.trial7`
- [ ] `stir.pro.monthly`
- [ ] `stir.pro.annual`

Each product MUST link 1:1 to the matching App Store Connect IAP — RC fetches metadata (price, period, intro offer) directly from Apple. If Apple's IAP isn't approved yet, RC shows the product as "Pending" — that's fine for setup; verify it flips to "Active" once Apple approves.

### Entitlements

RevenueCat → Entitlements → **+ New**:

- [ ] `premium` — attached products: `stir.premium.monthly`, `stir.premium.annual.trial7`
- [ ] `pro` — attached products: `stir.pro.monthly`, `stir.pro.annual`

iOS reads entitlement state through `entitlement_snapshots` (server-truth), not directly from RC's `customerInfo.entitlements`. The entitlement names above are RC's internal labels; the server's tier mapping is independent (see `_shared/revenuecat.ts` resolver).

### Offering (CRITICAL)

RevenueCat → Offerings → **+ New**:

- [ ] Identifier: `default`
- [ ] Description: `Stir paywall — Premium primary, Pro upsell`
- [ ] Add 4 packages, one per product. Use RC's standard package types where they fit:
  - `$rc_annual` → `stir.premium.annual.trial7` (this is what `PaywallOfferings.primaryTrialPackage` resolves)
  - `$rc_monthly` → `stir.premium.monthly`
  - Custom `pro_monthly` → `stir.pro.monthly`
  - Custom `pro_annual` → `stir.pro.annual`
- [ ] **Mark this Offering as Current.** Without "Current", `Purchases.shared.offerings()` returns `nil` and the iOS paywall renders empty packages with no error.

### iOS Public SDK Key

RevenueCat → Project Settings → API Keys → iOS public SDK key.

- [ ] Production key starts with `appl_…` (NOT `test_…`).
- [ ] Copy the value. You'll paste it into `Config.xcconfig` in step 6.

## Step 5 — RevenueCat: webhook delivery

RevenueCat → Project Settings → Integrations → Webhooks → **+ Webhook**.

- [ ] URL: `https://ktqajarcomzplnpbczfo.supabase.co/functions/v1/revenuecat-webhook`
- [ ] Authorization header value: paste the value of `REVENUECAT_WEBHOOK_SECRET` on prod Supabase. Get it via:
  - First time: generate via `openssl rand -hex 32`, then `supabase secrets set REVENUECAT_WEBHOOK_SECRET='<value>' --project-ref ktqajarcomzplnpbczfo`. Paste the same value into the RC dashboard.
  - If already set: rotate per `revenuecat-webhook-secret-rotation.md` and use the rotated value here.
- [ ] Event types to deliver: leave at default (all). The handler explicitly ignores types it doesn't act on (logged as `unknown_event`).
- [ ] Save.

### Test the webhook

RevenueCat dashboard → Webhooks → click the webhook → **Send Test Event**.

- [ ] RC dashboard shows `200 OK` response.
- [ ] Verify in Supabase: `SELECT * FROM webhook_log ORDER BY created_at DESC LIMIT 5;` — newest row should have `status='accepted'` (or `unknown_event` for the test event type, which is also fine; only `signature_invalid` indicates the secret mismatch).
- [ ] If `status='signature_invalid`: the secret on RC dashboard does NOT match what's in Supabase. Re-check both sides. The handler does a constant-time compare against `REVENUECAT_WEBHOOK_SECRET`; values must match byte-for-byte (including no trailing whitespace).

## Step 6 — iOS: Config.xcconfig wiring

```
# Stir/Config.xcconfig (gitignored — repo holds Config.xcconfig.example)
REVENUECAT_PUBLIC_API_KEY = appl_…   # production key from step 4
```

- [ ] Replace any `test_…` value (the repo currently ships `test_RYLCWrRtpWKrmbbFvwTyaBHEldz` for sandbox testing).
- [ ] xcodebuild build -scheme Stir → green (config flows through `Info.plist` → `AppConfig.RevenueCat.publicAPIKey`).
- [ ] Verify on device: launch the app, watch Console.app for `revenuecat: configured (storekit2)` log line. If absent, `AppConfig.load()` returned `revenueCat == nil`, meaning the key didn't substitute.

## Step 7 — TestFlight smoke test

Build a TestFlight release with the production RC key. Distribute to a sandbox tester from step 3.

### Trial-eligible flow

- [ ] Sign out of any production Apple ID on the test device.
- [ ] Settings → App Store → Sandbox Account → sign in with the new sandbox tester.
- [ ] Open Stir → trigger a paywall (e.g. tap voice affordance on Tonight Home from a Free user).
- [ ] Verify CTA reads **Start 7-day free trial** with `then $69.99/year`.
- [ ] Tap CTA → complete the purchase via Apple's sandbox sheet. Sandbox renews subscriptions accelerated (1 day = 5 min).
- [ ] Verify in Supabase: `SELECT * FROM entitlement_snapshots WHERE canonical_user_key = '<tester_key>';` → `tier='premium'`, `is_trial=true`, `expires_at` ~7 days out.
- [ ] Verify webhook fired: `SELECT * FROM webhook_log WHERE canonical_user_key = '<tester_key>' ORDER BY created_at DESC;` → `status='accepted'` for `INITIAL_PURCHASE`.
- [ ] Verify PostHog: `entitlement_state_changed` event with `source='server_webhook'`, `tier='premium'`, `is_trial=true`.

### Cancellation + expiration flow

- [ ] iOS Settings → Apple ID → Subscriptions → Stir Premium Annual → Cancel Subscription.
- [ ] Verify webhook fires CANCELLATION → `webhook_log.status='accepted'`, `entitlement_snapshots.billing_state='cancelled_active'` (user keeps access until period end).
- [ ] Wait for sandbox expiration (5 min for annual). Verify EXPIRATION webhook → `billing_state='expired'`. Effective tier reverts to `free` via the `effectiveTier()` mapping (server-side).

### Trial-ineligible flow (SCA-287 verification)

- [ ] Same sandbox tester (already consumed the trial above).
- [ ] Re-open paywall.
- [ ] Verify CTA reads **Subscribe annually** with `$69.99/year` (NO "then" qualifier, NO "7 days free" disclosure).
- [ ] Cancel without purchasing — no need to spend a second time.

If trial-ineligible copy still says "Start 7-day free trial", check:

- `Purchases.shared.checkTrialOrIntroDiscountEligibility` is reachable (RC SDK ≥ 5.x; check Package.resolved).
- The cached eligibility hasn't gone stale — kill the app, relaunch, retry.

## Step 8 — Pre-launch invariants

Before flipping the App Store record from "Ready for Review" → "Submit for Review":

- [ ] `Config.xcconfig` carries production `appl_…` key (NOT `test_…`).
- [ ] `REVENUECAT_WEBHOOK_SECRET` ≥ 32 chars: `supabase secrets list --project-ref ktqajarcomzplnpbczfo | grep REVENUECAT`.
- [ ] `[functions.revenuecat-webhook]` block in `Backend/supabase/config.toml` has `verify_jwt = false`.
- [ ] `revenuecat-webhook` function deployed to prod: `supabase functions list --project-ref ktqajarcomzplnpbczfo | grep revenuecat-webhook` shows `ACTIVE`.
- [ ] `entitlement_snapshots` migration applied: `supabase migration list --project-ref ktqajarcomzplnpbczfo` includes `20260418000003_init_entitlement_snapshots`.
- [ ] All 4 IAPs in App Store Connect are **Approved** (or **Ready to Submit** for the matching app build).
- [ ] RC Offering is marked **Current**.
- [ ] Sandbox smoke test passed (step 7) within the last 7 days.

---

## Rollback / emergency

**Symptom: paywall renders empty (`unavailable — check back later`).**

- Cause: RC Offering not marked Current OR products not linked to App Store IAPs OR App Store IAPs not approved.
- Fix: re-verify step 4. The iOS code already handles this gracefully — no app rollback needed.

**Symptom: `webhook_log.status='signature_invalid'` rows accumulating.**

- Cause: Authorization header on RC dashboard doesn't match `REVENUECAT_WEBHOOK_SECRET` on Supabase.
- Fix: re-paste the secret on RC dashboard. If concerned about leak, follow `revenuecat-webhook-secret-rotation.md`.

**Symptom: paywall shows wrong price after price-tier change in App Store Connect.**

- Cause: RC's price cache lags Apple by ~1h. `Purchases.shared.invalidateCustomerInfoCache()` doesn't clear product cache; force a relaunch with `Purchases.proxyURL` cleared.
- Fix: kill the app, relaunch — RC re-fetches on cold start. If still stale, RC dashboard → Products → click the product → **Refresh from store**.

**Symptom: need to kill the paywall urgently (e.g. App Review reject, broken offer).**

- Pause the Offering in RC dashboard → mark a different Offering as Current (or unset Current entirely). The iOS code handles empty/missing offerings with `unavailable — check back later` copy. No app submission needed.

**Symptom: `INITIAL_PURCHASE` webhooks accepted but `entitlement_snapshots` rows not appearing.**

- Cause: `stir_process_webhook_event` RPC failure (likely a malformed canonical_user_key from RC).
- Fix: tail Edge Function logs: `supabase functions logs revenuecat-webhook --project-ref ktqajarcomzplnpbczfo`. Look for `webhook_processing_error`. The handler returns 500 in this case so RC retries; the failure should self-heal once the upstream issue is fixed.

---

## Cross-references

- `docs/runbooks/revenuecat-webhook-secret-rotation.md` — secret rotation procedure
- `docs/decisions/0003-revenuecat-shared-secret-auth.md` — auth model rationale
- `docs/decisions/0015-pricing-and-cohort-economics.md` — SKU + price tier rationale
- `docs/decisions/0035-tier-downgrade-pantry-reconciliation.md` — downgrade behavior
- `Specs/Stir-Full-Spec.md` §9 — monetization spec
- `CLAUDE.md` §Pre-filled-constants → StoreKit SKUs row — current price + period table
- `Stir.storekit` — local StoreKit testing config (Debug scheme only)
- `Backend/supabase/functions/revenuecat-webhook/index.ts` — webhook handler
- `Backend/supabase/functions/_shared/revenuecat.ts` — pure event resolver
- `Stir/Integrations/RevenueCat/RevenueCatService.swift` — iOS SDK facade

---

_Last updated: 2026-05-09 (SCA-288)._
