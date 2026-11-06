# Privacy Policy — DRAFT

**Status:** DRAFT — pending lawyer review.
**Effective date:** TBD (set on launch)
**Last updated:** 2026-11-06

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

- **Kitchen scan images:** When you scan your kitchen, the photo is sent through our backend to Anthropic's Claude API for ingredient identification. Stir processes scan images per request and does not durably store those image bytes.

### 2.3 Audio

- **Voice Cook Mode audio:** When you use Premium voice Cook Mode, audio is streamed directly from the app to OpenAI's Realtime API, with relevant recipe, pantry and dietary context. Stir does not durably store the audio waveform. Operational voice metadata (duration, token counts) is retained in Stir's backend for 30 days. OpenAI's separate retention is described in §4.

### 2.4 Free-text input

- **Constraints you type:** When you type a constraint like "20 minutes" or "use spinach first," the text is sent to our AI processing pipeline. Text and derived responses may pass through the short-lived processing and retry stores described in §6; this is separate from saved content in your iCloud.
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

Text and image features use Anthropic's Claude API. Premium voice sends audio and relevant recipe, pantry and dietary context to OpenAI's Realtime API. An operator-controlled fallback can route text and image requests to Google's paid Gemini API; it does not switch providers within a request. We send the context needed to answer the request, including dietary preferences when relevant.

Anthropic's published commercial policy excludes API inputs and outputs from model training by default. Its standard API retention policy provides deletion within 30 days, subject to agreed settings and safety/legal exceptions. See [Anthropic's training policy](https://privacy.claude.com/en/articles/7996868-is-my-data-used-for-model-training) and [commercial retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data).

OpenAI's API policy excludes API data from model training unless the customer opts in. Its Realtime endpoint has no application-state retention; default abuse-monitoring logs may retain content for up to 30 days, with policy/legal exceptions. See [OpenAI's API data controls](https://developers.openai.com/api/docs/guides/your-data).

These published policies do not establish Stir's entitlement to zero-retention settings. We do not promise immediate provider deletion or assert an unverified special retention agreement. Google's paid API terms govern the optional Gemini route; see [Gemini API terms](https://ai.google.dev/gemini-api/terms).

## 5. Third-party subprocessors

The following companies process data on our behalf:

| Subprocessor | Service | Data they receive |
|---|---|---|
| **Anthropic, PBC** | Claude API (text and image features) | Scan photos, recipe text, constraints, dietary preferences and pantry/recipe context |
| **OpenAI** | Realtime API (Premium voice) | Voice audio, recipe, pantry and dietary context, tool requests/results |
| **Google LLC** | Paid Gemini API (operator-selected text/image fallback) | Text/image inputs and the context needed for those requests |
| **Supabase Inc.** | Postgres + Edge Functions backend | canonical_user_key, quota counters, subscription state, AI request metadata, transient queued import text and parsed-response replay caches (§6) |
| **RevenueCat Inc.** | Subscription management | App Store receipts, subscription lifecycle events |
| **PostHog Inc.** | Product analytics | Pseudonymous interaction events keyed on a hashed identifier |
| **Functional Software, Inc. (Sentry)** | Crash and error reporting | Scrubbed stack traces, performance metrics |
| **Apple Inc.** | CloudKit private DB, APNs push, StoreKit | User content (your private CloudKit container), push tokens, subscription state |

We have data processing agreements with each subprocessor. We do not allow subprocessors to use your data for their own purposes beyond the contracted service.

## 6. Data retention

We retain different categories of data for different periods, balancing service functionality with privacy. Two storage layers govern these retentions:

- **Your iCloud private database** (CloudKit) holds your user content (preferences, pantry items, saved recipes, cooking sessions). This data lives in your own iCloud account and is governed by Apple's iCloud terms — you control it directly via your Apple ID. Stir does not maintain a second permanent content library on its backend. The transient processing exceptions below can contain user content.
- **Stir's operational backend** (Supabase) holds quotas, subscription state, operational metadata and the bounded processing/retry copies listed below, keyed on a pseudonymous user identifier. Data here is subject to Stir's retention policies below.

| Data class | Storage layer | Retention |
|---|---|---|
| Household profile, dietary preferences | CloudKit (your iCloud) | Until you delete via the App or iCloud |
| Pantry remembered items | CloudKit | Until you delete; expired ephemeral items leave the active pantry on foreground. Deleted rows are purged after 90 days when maintenance next runs. |
| Saved recipes / favorites | CloudKit | Until you delete |
| Cooking sessions | CloudKit | App-managed rolling 24-month window |
| Substitution events | CloudKit | Until you delete (lives alongside the cooking session) |
| Outcome feedback (post-meal ratings) | CloudKit | Until you delete |
| Voice turn metadata | Stir backend | Automatic; deleted hourly after 30 days |
| AI request logs (operational, all features) | Stir backend | Automatic; deleted hourly after 30 days |
| Raw kitchen scan images | Stir backend (transient) | Processed and discarded per request; not durably stored |
| Imported recipe images | Stir backend (transient) | Processed and discarded per request; not durably stored |
| Completed recipe-import source URL/hash records | Core Data / CloudKit | Removed after 30 days when Stir next selects the household or enters the foreground |
| Queued recipe-import text | Stir backend (transient) | Removed immediately on completion/failure; unfinished work expires after 10 minutes and the next minute cleanup removes its text. Cleanup can be delayed by a database outage. Source URLs are omitted from the queue. |
| Parsed AI responses for retry/result retrieval | Stir backend (transient) | Readable for 10 minutes. Expired rows are cleaned every 5 minutes in batches; backlog or database outages can delay physical removal. Expired imports require an explicit new attempt. |
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

**In-app (primary):** open **Stir > Settings > Delete my data**. The screen asks for a confirmation phrase and submits an authenticated backend request. After acceptance, it removes the selected household locally and queues normal iCloud synchronization. Deleting data does not cancel an App Store subscription; manage renewal and refunds in the App Store.

**Email (fallback):** if you can't access the app — for example, you've been locked out, or you're submitting a request on behalf of a deceased user — email **privacy@getstir.app** with the subject line "Privacy request: \<know | delete | correct\>". Include the Apple ID email associated with your subscription so we can verify your identity. We may need to verify your identity before fulfilling certain requests.

We respond within 30 days for any path.

For deletion requests:
- Operational data (Stir backend): purged within 30 days of request
- User content (Core Data / CloudKit): the confirmed in-app flow removes the selected household's content locally. iCloud removal depends on successful synchronization; local removal alone does not confirm cloud deletion. Minimal identity/deletion anchors remain to remove old content that arrives later. Other households on the device are kept separate.
- Third-party processors (PostHog, Sentry, RevenueCat): we forward deletion requests to each subprocessor and they process per their own SLA

The app reports local removal and a later successful iCloud export separately. Backend/provider steps remain pending until verified; contact privacy@getstir.app for their status. Start over creates a fresh local household without canceling the pending backend request. Stir does not collect an email address through this flow, so it does not promise an automatic confirmation email.

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

Stir is currently available only in the United States App Store. Stir's backend uses a U.S. Supabase region. Anthropic, OpenAI and the optional Google route process data under their respective service terms; no unverified U.S.-only processing or special data-residency agreement is promised. If you use Stir outside the U.S., your data may be transferred internationally.

## 11. Changes to this Privacy Policy

We may update this Privacy Policy from time to time. Material changes will be communicated via in-app notification or push notification at least 30 days before they take effect, where reasonably possible. Your continued use of Stir after the effective date of a revised Privacy Policy constitutes acceptance.

## 12. Contact

- General privacy questions: privacy@getstir.app
- Subject access requests, deletion requests, CCPA rights: privacy@getstir.app
- Support: support@getstir.app

---

## Lawyer review checklist (DRAFT signal — remove before publish)

- [ ] Verify the published privacy page and in-app disclosures name Anthropic for text/images and OpenAI for voice before release; source updates do not publish the website.
- [ ] Verify actual provider-account training/retention settings and any special agreements; published defaults alone do not establish them.
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
- `docs/runbooks/deletion-request-fulfillment.md` (the fulfillment-worker runbook covering subsystem ordering, partial-failure replay, and cron schedule)
- `docs/legal/ccpa-deletion-runbook.md` (the legal-compliance companion — 30-day SLA tracking, audit-trail verification, user communication templates)
- `docs/appstore/app-privacy-details.md` (App Store Connect nutrition label — must align with this PP §2 and §5)
