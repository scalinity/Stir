# Privacy Policy — DRAFT

**Status:** DRAFT — pending lawyer review.
**Effective date:** TBD (set on launch)
**Last updated:** 2026-04-24

This is the initial Stir Privacy Policy draft, structured per spec §11 and §19. Daniel sends to lawyer; lawyer revises subprocessor and CCPA workflow language; Daniel publishes the finalized version at https://getstir.app/privacy.

Items flagged **[LEGAL REVIEW REQUIRED]** are spec §19 items where the lawyer's finalized wording is mandatory.

---

# Stir — Privacy Policy

**Last updated:** [DATE]
**Effective:** [DATE]

This Privacy Policy describes how the Stir mobile application ("Stir," "we," "us," "our") collects, uses, and discloses information when you use our service.

By using Stir, you consent to the data practices described in this policy.

---

## 1. Overview

Stir is built privacy-conscious by design:

- **No mandatory account.** You can use Stir anonymously without signing up.
- **User content lives in your private iCloud.** Your dietary preferences, pantry items, saved recipes, and cooking history are stored in your CloudKit private database, accessible only by you.
- **No cross-app tracking.** Stir does not use IDFA or participate in any advertising networks.
- **No selling of personal information.** We do not sell your data, ever.

## 2. Data we collect

### 2.1 Identifiers

- **Device identifier (canonical_user_key):** A pseudonymous identifier we generate. If you have an iCloud account signed in, this derives from your CloudKit user record name; otherwise, from a Keychain-stored installation UUID. This identifier is sent with every authenticated request to our servers but is not linked to your name, email, or other identifying information from our perspective.
- **Apple receipt data:** Apple sends purchase confirmations to RevenueCat, our subscription processor. We use this data only for subscription state tracking.

### 2.2 Photos

- **Kitchen scan images:** When you scan your kitchen, the photo is sent to our server-side AI processing pipeline (powered by Google Gemini) for ingredient identification. Raw scan images are deleted within 7 days.

### 2.3 Audio

- **Voice Cook Mode audio:** When you use Premium voice Cook Mode, audio is streamed in real-time to Google's Gemini Live API for transcription and response generation. Audio waveforms are not stored long-term; voice turn metadata (duration, token counts) is retained for 30 days for cost accounting and debugging.

### 2.4 Free-text input

- **Constraints you type:** When you type a constraint like "20 minutes" or "use spinach first," the text is sent to our AI processing pipeline. Free-text input is not retained beyond the request.
- **In-app feedback:** When you tap the "flag" button on an AI result and submit feedback, your text is retained for 12 months for AI quality improvement.

### 2.5 Usage data

- **Product interaction events:** Pseudonymous events tracked via PostHog (e.g., "scan_started," "dinner_solve_completed"). These are linked to your canonical_user_key but contain no free-text content beyond constants we define. Retained 13 months.

### 2.6 Diagnostic data

- **Crash and error reports:** Sent to Sentry. Stack traces have user identifiers scrubbed. Retained 90 days.
- **Performance metrics:** Latency probes for cold launch, API round-trip, voice TTFA. Not linked to identity. Retained 90 days.

### 2.7 What we do NOT collect

- Your name, email address, or phone number (Apple receipt email is handled by Apple, not visible to us)
- Your physical or coarse location
- Health or fitness data
- Contacts or address book
- Browsing or search history outside of Stir
- IDFA or tracking identifiers across apps/websites
- Sensitive personal information beyond what's listed above

## 3. How we use data

We use the data described above to:

- **Provide the App's core functionality** (scan parsing, dinner solving, Cook Mode guidance, substitution suggestions, recipe import, grocery export)
- **Personalize your experience** (preference history drives future dinner suggestions; saved favorites and use-soon nudges work locally)
- **Operate our infrastructure** (rate limiting, quota enforcement, entitlement checks, fraud prevention)
- **Improve the App** (fix bugs via crash reports; tune AI prompts via flagged outputs; measure feature funnels via PostHog events)
- **Process subscription transactions** (via Apple StoreKit and RevenueCat)

We do NOT use your data for:

- Advertising (we don't run ads, in-app or elsewhere)
- Sharing with third parties beyond the subprocessors listed in §5
- Profile-building for sale or external use
- Manipulation of any kind

## 4. AI processing — special note

When you use Stir's AI features, your input data (photos, audio, free-text) is sent to Google LLC's Gemini API. Google's paid-tier API policy explicitly states that:

> Content submitted to Gemini paid-tier APIs is not used to improve Google's products.

This applies to Stir's usage. Your scan photos, voice audio, and free-text input are processed for the immediate request and then discarded by Google per their published policy.

We send only what's required for the AI request (your photo, audio, or text plus relevant context like your dietary preferences and pantry). We do not send your name, email, location, or any other personal information that Google could use to identify you.

## 5. Third-party subprocessors

The following companies process data on our behalf:

| Subprocessor | Service | Data they receive |
|---|---|---|
| **Google LLC** | Gemini API (all AI features) | Scan photos, voice audio, free-text constraints, recipe context |
| **Supabase Inc.** | Postgres + Edge Functions backend | canonical_user_key, quota counters, subscription state, AI request logs (no user content beyond what's specified above) |
| **RevenueCat Inc.** | Subscription management | App Store receipts, subscription lifecycle events |
| **PostHog Inc.** | Product analytics | Pseudonymous interaction events keyed on canonical_user_key |
| **Functional Software, Inc. (Sentry)** | Crash and error reporting | Scrubbed stack traces, performance metrics |
| **Apple Inc.** | CloudKit private DB, APNs push, StoreKit | User content (your private CloudKit container), push tokens, subscription state |

We have data processing agreements with each subprocessor. We do not allow subprocessors to use your data for their own purposes beyond the contracted service.

## 6. Data retention

We retain different categories of data for different periods, balancing service functionality with privacy. Two storage layers govern these retentions:

- **Your iCloud private database** (CloudKit) holds your user content (preferences, pantry items, saved recipes, cooking sessions). This data lives in your own iCloud account and is governed by Apple's iCloud terms — you control it directly via your Apple ID. Stir does not have server-side copies of these records.
- **Stir's operational backend** (Supabase) holds quotas, subscription state, and operational metadata keyed on a pseudonymous user identifier. Data here is subject to Stir's retention policies below.

| Data class | Storage layer | Retention |
|---|---|---|
| Household profile, dietary preferences | CloudKit (your iCloud) | Until you delete via the App or iCloud |
| Pantry remembered items | CloudKit | Until you delete; expired items auto-purge after 30 days |
| Saved recipes / favorites | CloudKit | Until you delete |
| Cooking sessions | CloudKit | App-managed rolling 24-month window |
| Substitution events | CloudKit | Until you delete (lives alongside the cooking session) |
| Outcome feedback (post-meal ratings) | CloudKit | Until you delete |
| Voice turn metadata | Stir backend | Automatic; deleted hourly after 30 days |
| AI request logs (operational, all features) | Stir backend | Automatic; deleted hourly after 30 days |
| Raw kitchen scan images | Stir backend (transient) | Processed and discarded per request; not durably stored |
| Imported recipe images | Stir backend (transient) | Processed and discarded per request; not durably stored |
| Grocery export metadata | CloudKit | Until you delete |
| Crash logs | Sentry (third-party processor) | Per Sentry's standard retention (~90 days) |
| Analytics events | PostHog (third-party processor) | Per PostHog's standard retention (~13 months) |

App-managed retentions (CloudKit) execute when you take an action in the App or directly in iCloud. Backend retention for AI request logs (including voice turn metadata) runs automatically via a scheduled job that deletes rows older than 30 days. If you require confirmation that a specific backend record has been deleted, submit a deletion request as described in §7.7.

## 7. Your rights (CCPA, CPRA)

If you are a California resident, you have the right to:

### 7.1 Know

You can request information about:
- Categories of personal information we collect about you
- Specific personal information we have about you
- Categories of sources from which we collect data
- Purposes for which we collect data
- Categories of third parties with whom we share data
- Specific personal information that has been sold or shared (we do not sell or share personal information)

### 7.2 Delete

You can request deletion of your personal information. Stir will delete your data within 30 days, subject to operational and legal exceptions (e.g., we may retain transaction records for tax purposes per applicable law).

### 7.3 Correct

You can request correction of inaccurate personal information.

### 7.4 Opt out of sale

We do not sell your personal information; this right is automatically respected.

### 7.5 Limit use of sensitive personal information

We do not use sensitive personal information for purposes beyond the App's core functionality.

### 7.6 Non-discrimination

We do not discriminate against users who exercise their CCPA rights.

### 7.7 How to exercise these rights

Email **privacy@getstir.app** with the subject line "Privacy request: \<know | delete | correct\>". Include the canonical user identifier shown in **Stir > Settings > About** so we can locate your data, or include the Apple ID email associated with your subscription.

We respond within 30 days. We may need to verify your identity before fulfilling certain requests.

For deletion requests:
- Operational data (Stir backend): purged within 30 days of request
- User content (CloudKit): you delete this directly via Stir > Settings > Delete Local Data, or by signing out of iCloud / removing Stir from iCloud
- Third-party processors (PostHog, Sentry, RevenueCat): we forward deletion requests to each subprocessor and they process per their own SLA

You will receive an email confirmation when each step completes.

We are working on a single-tap in-app deletion flow that consolidates these steps for v1.1; until then, the email path is the primary mechanism.

## 8. Children

Stir is not directed at children under the age of 13. We do not knowingly collect personal information from children under 13. If you are a parent or guardian and believe your child has used Stir, contact us at privacy@getstir.app and we will delete any associated data.

## 9. Security

We employ industry-standard security measures to protect your data:

- HTTPS encryption for all server communication
- Authenticated session JWTs with short TTLs
- Rate limiting and abuse detection
- Server-side secrets managed in Supabase secrets store, never present in the iOS bundle
- Webhook signature verification for subscription events
- Sentry stack traces sanitized of user identifiers

Despite these safeguards, no system is 100% secure. We will notify affected users of any data breach within 72 hours of confirming the breach, in compliance with applicable law.

## 10. International transfers

Stir is currently available only in the United States App Store. Data is processed in U.S.-based infrastructure (Supabase U.S. region, Google Gemini U.S.-hosted endpoints). If you use Stir from outside the U.S., your data is transferred to and processed in the U.S.

## 11. Changes to this Privacy Policy

We may update this Privacy Policy from time to time. Material changes will be communicated via in-app notification or push notification at least 30 days before they take effect, where reasonably possible. Your continued use of Stir after the effective date of a revised Privacy Policy constitutes acceptance.

## 12. Contact

- General privacy questions: privacy@getstir.app
- Subject access requests, deletion requests, CCPA rights: privacy@getstir.app
- Support: support@getstir.app

---

## Lawyer review checklist (DRAFT signal — remove before publish)

- [ ] §5 subprocessor list — finalize legal entity names; verify each subprocessor has executed a DPA aligned to CCPA
- [ ] §6 retention table — verify against each subprocessor's actual retention, especially RevenueCat's
- [ ] §7 CCPA workflow — confirm 30-day SLA matches required law and our internal capability (`docs/runbooks/ccpa-deletion-workflow.md`)
- [ ] §8 children — verify rating doesn't trigger COPPA-specific disclosures (4+ rating likely fine, but confirm)
- [ ] §9 breach notification SLA — verify 72h matches strictest applicable law
- [ ] §10 international transfers — if EU expansion is on near-term roadmap, this section needs significant work (GDPR + UK-GDPR addenda)
- [ ] §11 update notification mechanism — confirm in-app notification + push is sufficient (some jurisdictions require email)
- [ ] §12 contact email — verify privacy@getstir.app and support@getstir.app are operational with 24-48h response SLA at submission time

## Internal cross-references

- Spec §11 — Data Lifecycle (the source-of-truth for retention table and export bundle format)
- Spec §19 — Legal & Regulatory Checklist (parent doc for legal items)
- `docs/legal/terms-of-service.md` (companion doc)
- `docs/runbooks/ccpa-deletion-workflow.md` (the operational runbook for §7.7)
- `docs/appstore/app-privacy-details.md` (App Store Connect nutrition label — must align with this PP §2 and §5)
