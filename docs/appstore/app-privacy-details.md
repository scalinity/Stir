# App Privacy Details (App Store Connect nutrition label)

Source of truth for the App Store Connect "App Privacy" section. DISTINCT from `Stir/App/PrivacyInfo.xcprivacy` (build-layer required-reason API declarations); this governs the user-facing nutrition label.

Sync rule: any data collection / subprocessor change updates BOTH this doc AND `PrivacyInfo.xcprivacy`.

---

## Data types collected

### Identifiers

**Device ID**
- Collected: YES — canonical_user_key sent on every /v1/* request
- Linked to identity: YES
- Used for tracking: NO
- Purposes: App Functionality, Analytics

### Purchases

**Purchase History**
- Collected: YES — RevenueCat + `entitlement_snapshots` rows
- Linked to identity: YES
- Used for tracking: NO
- Purposes: App Functionality

### Usage Data

**Product Interaction**
- Collected: YES — PostHog events per spec §15
- Linked to identity: YES (canonical_user_key pseudonymous but linked)
- Used for tracking: NO
- Purposes: App Functionality, Analytics, Product Personalization

### Diagnostics

**Crash Data**
- Collected: YES — Sentry SDK
- Linked to identity: NO (identifiers scrubbed per §12.3)
- Used for tracking: NO
- Purposes: App Functionality

**Performance Data**
- Collected: YES — PostHog + Sentry perf breadcrumbs
- Linked to identity: NO
- Used for tracking: NO
- Purposes: App Functionality

**Other Diagnostic Data**
- Collected: YES — Sentry breadcrumbs (no free-text user input)
- Linked to identity: NO
- Used for tracking: NO
- Purposes: App Functionality

### User Content

**Photos or Videos**
- Collected: YES — scan images base64-encoded to `pantry-parse` → Gemini
- Linked to identity: YES (canonical_user_key in request)
- Used for tracking: NO
- Purposes: App Functionality
- Retention: raw scan images purge within 7 days (spec §11)

**Audio Data**
- Collected: YES — voice Cook Mode PCM16 16kHz to Gemini Live
- Linked to identity: YES (session-scoped, ephemeral-token-bound)
- Used for tracking: NO
- Purposes: App Functionality
- Retention: voice turns 30 days (spec §11); audio waveforms not stored long-term

**Other User Content**
- Collected: YES — free-text constraints ("use spinach first"); flag-output free-text feedback
- Linked to identity: YES
- Used for tracking: NO
- Purposes: App Functionality

---

## Data types NOT collected

- Contact Info (no email/phone/name collection — Apple receipt email is Apple's)
- Health & Fitness (no HealthKit)
- Financial Info (beyond Apple's subscription state)
- Location (no CoreLocation)
- Sensitive Info (dietary prefs stored in user's private CloudKit — not developer-collected)
- Contacts
- User Content — Customer Support (flag-output is "Other User Content" above)
- Browsing History / Search History
- Identifiers — Advertising (no IDFA, no ATT, no ad networks)
- Purchases — Other Financial Info
- Usage Data — Advertising Data

---

## Third-party subprocessors

Disclosed in Privacy Policy. Must match `docs/legal/privacy-policy.md` §5.

| Vendor | Service | Data | Purpose | Retention |
|---|---|---|---|---|
| Google LLC | Gemini API (all AI features) | Scan images, voice audio, free-text constraints | AI inference | Paid-tier: not retained for training; processed + discarded per request |
| Supabase Inc. | Postgres + Edge Functions | canonical_user_key, quotas, entitlements, AI request logs (no user content) | Operational compute | 30d raw / 13mo aggregate (spec §11) |
| RevenueCat Inc. | Subscription management | App Store receipts, subscription events | Entitlement state | RevenueCat standard retention |
| PostHog Inc. | Product analytics | Pseudonymous event stream keyed on canonical_user_key | Analytics + flags | 13 months (spec §11) |
| Functional Software, Inc. (Sentry) | Crash reporting | Scrubbed stack traces, performance breadcrumbs | Crash triage | 90 days (spec §11) |
| Apple Inc. | CloudKit private DB, APNs, StoreKit | User content (private DB), push tokens, subscription state | Storage, delivery, verification | Apple standard retention |

---

## Privacy contact

**Email:** privacy@getstir.app — mailbox provisioned before beta. 48h SLA auto-responder.

---

## Privacy manifest vs nutrition label

| Governs | Lives in | When updated |
|---|---|---|
| Build-layer (required-reason APIs, SDKs) | `Stir/App/PrivacyInfo.xcprivacy` | New required-reason API call or new SDK bundled |
| App Store consumer disclosure | This doc + App Store Connect | New data type collected or scope changed |

Both must stay consistent. Pre-submission drill: grep-audit the other when updating either.

---

## Re-review triggers

- Adding a new subprocessor
- New data type collection
- Moving scope of existing collection (e.g., if scan images ever become "linked to tracking")
- CCPA workflow changes
