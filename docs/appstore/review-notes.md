# App Review Notes

Content for App Store Connect > App Information > Review Information. Apple reviewers read this before testing; well-written notes reduce review turnaround and rejection risk.

---

## Demo account

**Apple ID:** stir-review@getstir.app
**Password:** [stored in 1Password under "App Store Review Account — Stir"; rotated per major submission]
**iCloud signed-in:** YES — this is required to demonstrate CloudKit sync and voice Cook Mode

Review notes body text (copy-paste into App Store Connect):

```
Demo account:
Apple ID: stir-review@getstir.app
Password: [password]

Please sign in to iCloud with this Apple ID on the review device before launching the app. CloudKit sync and voice Cook Mode both depend on iCloud being available.

Subscription state: Premium annual trial active (14 days remaining at the time of this review). All Premium features (voice Cook Mode, widgets, saved favorites, leftovers mode) are unlocked.

StoreKit sandbox SKUs are wired for:
- stir.premium.monthly
- stir.premium.annual.trial7 (7-day free trial — primary paywall CTA)
- stir.pro.monthly
- stir.pro.annual

If you need to test purchase flow, the demo account has not consumed its introductory offer eligibility.
```

---

## Feature verification steps

Copy-paste into Review Notes:

```
Core flow verification (5 minutes):

1. Scan flow
   - Allow camera permission
   - Point at any food (refrigerator, pantry shelf, countertop) OR skip with "Use a sample photo" if camera isn't available
   - Stir's AI parses ingredients into chips; you can correct any by tapping

2. Dinner solve
   - Review parsed ingredients
   - Set a constraint like "20 minutes" or "high protein"
   - Stir returns 3 dinner ideas based on what you actually have

3. Cook Mode (tap variant — all tiers)
   - Tap any dinner card
   - Step through the recipe with Next/Previous
   - Start a timer on any step that has one

4. Cook Mode voice variant (Premium — iCloud required)
   - In Cook Mode, tap the microphone affordance
   - Allow microphone permission
   - Ask "what's next?" — Stir responds with spoken audio
   - Ask "can I use oat milk instead of regular milk?" — Stir suggests a safe substitution via voice

5. Substitution (sheet flow, all tiers)
   - In any Cook Mode step, tap the "Something missing?" button
   - Pick an ingredient you don't have
   - Stir suggests a safe swap with a food-safety disclaimer

6. Recipe import (all tiers, 2/mo on Free)
   - Use the Share Extension from Safari on any recipe URL
   - OR paste a URL in the Import tab

7. Grocery export (all tiers)
   - Complete a Cook Session
   - At the end, export missing ingredients to Reminders
   - Items land in a Stir-tagged Reminders list
```

---

## Test scenarios (edge cases)

```
Edge-case scenarios to verify:

- Without camera permission: Stir offers a sample-photo fallback (no dead-end)
- Without iCloud signed in: Stir enters local-only mode and Cook Mode tap variant still works; voice Cook Mode is unavailable (iCloud is required for CloudKit-backed voice session)
- Subscription flow: StoreKit sandbox is wired; purchases are simulated and can be cancelled from Settings > Apple ID > Subscriptions without billing impact

Trial disclosure: Every paywall shows "7 days free, then $69.99/yr. Auto-renews unless cancelled. Cancel anytime in Settings." before the Subscribe button. Renewal date and cancellation path are always visible — not behind a disclosure arrow.

Age rating: 4+. No user-generated content, no in-app chat, no profanity, no external social login.
```

---

## AI disclosure

```
AI content:

Stir uses Google Gemini (Flash, Flash-Lite, and Flash Live Preview) for
all AI features:
- Scan parse → ingredients from photos
- Dinner solve → 3 dinner suggestions
- Substitution → ingredient swap suggestions
- Recipe import → URL/screenshot → structured steps
- Voice Cook Mode → hands-free Q&A during cooking

All AI-generated content is presented as guidance, NOT as medical,
dietary, or food-safety authority. A food-safety disclaimer is visible:
- In Cook Mode footer during active cooking sessions
- In every Substitution result
- In Plan & Billing paywall fine-print
- In Settings > Privacy > AI Disclosure

Privacy Policy (https://getstir.app/privacy) explicitly names Google
Gemini, Supabase, RevenueCat, PostHog, Sentry, and Apple CloudKit/APNs
as data subprocessors. Google paid-tier API policy: content is not
used to improve their products.

No user-generated content is shared publicly. Stir has no social layer,
no in-app feed, no third-party login.
```

---

## Contact for questions

```
Primary contact:
  Daniel [last name]
  Email: review-support@getstir.app
  Response SLA: within 24h during the review window

If rejection requires clarification or a code change, please attach screenshots or reproduction steps to your rejection email; we'll respond with either a fix timeline or additional context within 24h.
```

---

## Pre-submission verification (Daniel)

- [ ] Demo Apple ID works on a fresh device (not just the dev device)
- [ ] Demo Apple ID has Premium annual trial active with ≥ 7 days remaining at submission time
- [ ] Demo Apple ID has iCloud signed in and CloudKit records present
- [ ] All paywall screens pass the trial-disclosure check (auto-renew, billing date, cancellation path visible before Subscribe CTA)
- [ ] Food-safety disclaimer visible in all 4 copy sites (Cook Mode footer, Substitution result, paywall fine-print, Settings > Privacy > AI Disclosure)
- [ ] Review-support@getstir.app forwards to Daniel's primary mailbox with autoresponder
- [ ] Password rotation log updated (note current password hash, rotation date, next-rotation reminder)

---

## Common rejection causes (and mitigations already applied)

| Rejection reason | Mitigation |
|---|---|
| "Subscription terms not clearly disclosed" | Paywall shows "7 days free, then $69.99/yr. Auto-renews unless cancelled. Cancel anytime in Settings" explicitly before the Subscribe CTA. ToS + Privacy Policy URLs are live. |
| "AI-generated content presented as authoritative" | Food-safety disclaimer in 4 copy sites; AI outputs framed as "suggestions" throughout. |
| "Privacy manifest missing" | `Stir/App/PrivacyInfo.xcprivacy` included; declares all data types and UserDefaults reason. |
| "Required-reason API used without declaration" | Only `NSPrivacyAccessedAPICategoryUserDefaults` is used and declared. |
| "Third-party SDK missing privacy manifest" | RevenueCat 5.68.0, PostHog 3.54.0, Sentry 8.58.1 all ship manifests. Supabase-swift 2.43.1 doesn't ship one but is not on Apple's "commonly used" SDK list as of submission. |
| "App extension version mismatch" | MARKETING_VERSION bumped to 1.0.0 across all targets; CFBundleShortVersionString matches. |
| "Camera/Mic/Photos usage description too generic" | All UsageDescription strings are specific and action-oriented per Apple's guidelines. NSSpeechRecognitionUsageDescription added for the fallback voice pipeline. |
| "Test account doesn't work" | See "Pre-submission verification" checklist above. |
