# Paywall Disclosure Compliance Audit

Apple rejects paywall UIs that don't disclose subscription terms clearly BEFORE the Subscribe CTA. This audit verifies Stir's paywall screens meet the current Apple requirements as of step 9 / submission prep.

Apple's current subscription-disclosure requirements (abbreviated):
- Subscription length (7 days free, monthly, annually)
- Price per period
- Auto-renewal statement
- Cancellation path
- Links to ToS and Privacy Policy
- All the above visible BEFORE the Subscribe CTA (not behind a disclosure accordion, not in fine print only)

Reference: Apple Developer documentation on auto-renewable subscription offerings. Daniel re-verifies the exact current wording requirements against the live Apple Developer docs immediately before submission (wording occasionally shifts quarterly).

---

## Paywall screens in scope

Per mockup `16_paywall.html` and `Stir/Features/Billing/PaywallView.swift`, Stir has 3 paywall surfaces:

1. **Soft paywall** — inline Premium CTA in non-blocking places (Home ambient nudges, Solve results showing locked features)
2. **Feature paywall** — full-sheet triggered by hitting a gated feature (voice affordance tap on Free, "Save favorite" on Free, "Leftovers mode" on Free)
3. **Settings upgrade** — from Plan & Billing screen; tier-comparison view

Plus 2 adjacent surfaces that touch subscription disclosure:
4. **Paywall cancellation flow** — Settings > Manage Subscription → iOS Subscription Management sheet (Apple-owned, compliant by construction)
5. **Paywall restore flow** — "Restore Purchases" button, no disclosure obligation since no purchase occurs

---

## Required elements — source-of-truth verification

For each required element, verify it appears PROMINENTLY (not fine-print) on every Stir-owned paywall (surfaces 1, 2, 3).

### 1. Subscription length

**Required copy:** the specific duration ("7 days free", "monthly", "annual") must be explicit.

**Stir's implementation (from spec §9 + mockup 16_paywall.html):**
- Soft paywall: "Premium — try free for 7 days" (in CTA button) + "then $69.99/yr" (under button)
- Feature paywall: Hero text "Cook hands-free. Try Premium free for 7 days." + primary button "Start 7-day free trial" + subtitle "$69.99/yr, 7 days free, auto-renews"
- Settings upgrade: Tier comparison table with period columns ("Monthly", "Annual 7-day trial")

**Verify in-app (Daniel's device QA pass):** grep the strings in `PaywallView.swift` match the spec wording; open each surface and confirm the length is visible above-the-fold.

### 2. Price per period

**Required copy:** price explicit with period.

**Stir's:**
- Soft paywall: "$69.99/yr" visible
- Feature paywall: "$69.99/yr" visible in primary CTA subtitle + "Premium Monthly, $9.99/mo" secondary CTA
- Settings upgrade: all 4 SKU prices visible in tier comparison

### 3. Auto-renewal statement

**Required copy:** explicit statement that the subscription auto-renews.

**Stir's:**
- Soft paywall: "Auto-renews — cancel anytime" microcopy under CTA
- Feature paywall: "7 days free, then $69.99/yr. Cancel anytime in Settings." as mandatory paragraph below CTA
- Settings upgrade: same as feature paywall

### 4. Cancellation path

**Required copy:** location where user can cancel (Settings > Apple ID > Subscriptions).

**Stir's:**
- Soft paywall: "Cancel anytime" (abbreviated but explicit)
- Feature paywall: "Cancel anytime in Settings > Apple ID > Subscriptions" (full path in fine-print block)
- Settings upgrade: "Manage Subscription" button that deep-links to iOS-native subscription management; disclosure copy matches feature paywall

### 5. Terms of Service link

**Required:** clickable link visible before Subscribe CTA.

**Stir's:** All 3 surfaces show "Terms of Service" link in the disclosure block below CTA. Links to https://getstir.app/terms.

**Gap check:** Daniel verifies the URL resolves (HTTP 200 with legitimate ToS content) at submission time. If the domain isn't set up yet, this BLOCKS submission — see Phase 6.

### 6. Privacy Policy link

**Required:** clickable link visible before Subscribe CTA.

**Stir's:** Same as ToS link; visible on all 3 surfaces. Links to https://getstir.app/privacy.

---

## Disclosure-block wording (canonical)

This is the EXACT wording used across all 3 paywall surfaces. Keep this as a single source of truth — don't let surface-specific variants drift.

```
Premium Annual: $69.99/yr after 7-day free trial.
Premium Monthly: $9.99/mo, no trial, billed immediately.
Pro Annual: $139.99/yr. Pro Monthly: $14.99/mo.

Subscriptions auto-renew unless cancelled 24 hours before the
renewal date. You can cancel anytime in Settings > Apple ID >
Subscriptions.

Apple ID is charged at purchase confirmation. Any unused portion
of a trial period will be forfeited if the user purchases a
subscription during a trial.

Terms of Service: https://getstir.app/terms
Privacy Policy: https://getstir.app/privacy
```

**Stir's implementation gate:** this block must be visible on every paywall surface, above-the-fold, before any Subscribe / Start-Trial CTA. Covered by `Stir/Features/Billing/PaywallView.swift` (primary paywall) and `Stir/Features/Billing/PaywallInlineCTA.swift` (soft inline). Settings upgrade screen inherits via shared `PaywallDisclosure` view component.

**Verify before submission:** check that `PaywallDisclosure` view renders this exact text block on every paywall screen. If surface-specific variants exist, reconcile.

---

## Trial eligibility disclosure

Apple requires disclosure that intro offer is one-per-Apple-ID-per-subscription-group.

**Stir's:** Covered by Apple's own trial UI (StoreKit 2 renders trial eligibility in the iOS-native purchase sheet). Stir's paywall doesn't need to re-state this because it's Apple-enforced.

Documented here for audit completeness; no code change.

---

## Rejection-risk matrix

| Risk | Mitigation |
|---|---|
| Auto-renew copy missing or too subtle | `PaywallDisclosure` renders the full paragraph in body copy, NOT in a `@footnote`-style size reduction. |
| Price visible only in small type | All 4 SKU prices at body-copy size ≥16pt in the tier-comparison section. |
| ToS/PP link buttons inaccessible to screen readers | Phase 2 a11y fixes include `.accessibilityLabel` on link buttons. |
| "Cancel anytime" feels buried | Copy is in the mandatory paragraph BEFORE the Subscribe CTA, not a trailing footer. |
| Trial terms state wrong duration | The number "7" appears in 3 places on the feature paywall; all 3 must say "7" (verify via grep). |
| Disclosure hidden behind a "Show Details" accordion | Never use an accordion on a Stir paywall; Apple has rejected apps for this. |
| Trial confirmation screen (after Subscribe but before purchase) skips the disclosure | Apple's native purchase sheet renders this; nothing for Stir to do. |

---

## Pre-submission checklist

- [ ] `PaywallView.swift` disclosure block renders all 6 elements (length / price / auto-renew / cancellation / ToS / PP)
- [ ] Soft paywall (`PaywallInlineCTA.swift` or equivalent) renders compact disclosure + links
- [ ] Settings upgrade (`SettingsBillingView.swift`) renders the full disclosure block
- [ ] https://getstir.app/terms returns HTTP 200 with legitimate ToS content
- [ ] https://getstir.app/privacy returns HTTP 200 with legitimate Privacy Policy content
- [ ] No accordion/"Learn more" hiding disclosure elements
- [ ] Disclosure appears above-the-fold on every paywall (not requiring scroll to see before Subscribe CTA)
- [ ] Apple's current wording requirements checked via https://developer.apple.com/design/human-interface-guidelines/in-app-purchase/offering-subscriptions (at submission time, since wording shifts quarterly)

---

## Rejection-precedent log

Maintain as rejections happen:

| Date | Rejection reason | Fix applied | Resubmission build |
|---|---|---|---|
| — | (no rejections yet — pre-submission) | — | — |

Pull feature-specific notes from this log for the next audit cycle.

---

## Sign-off

Audit complete against Apple subscription guidelines as of 2026-04-24. Daniel re-verifies wording at submission time (expected late-May 2026 after 2-week beta cycle).
