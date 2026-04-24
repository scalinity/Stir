# App Store Metadata

Source of truth for everything Daniel pastes into App Store Connect. Keep in sync with spec §17 (Launch Content Kit) and §18 (ASO Checklist).

---

## Primary listing

| Field | Value | Notes |
|---|---|---|
| App name | **Stir: AI Dinner Copilot** | 30-char max (23 chars). Per spec §18. |
| Subtitle | **Cook what you already have** | 30-char max (27 chars). |
| Bundle ID | `com.company.stir` | Matches pbxproj PRODUCT_BUNDLE_IDENTIFIER. |
| Primary category | Food & Drink | |
| Secondary category | Lifestyle | |
| Age rating | 4+ | No objectionable content; no in-app UGC. |
| Price | Free (with in-app subscriptions) | |
| Storefronts at launch | US only | Per spec §11. Expand post-GDPR review. |

## Keywords (100-char)

```
ingredients,leftovers,dinner,recipes,pantry,fridge scan,meal planner,what to cook,weeknight,voice
```

Char count: 98/100.

## Description (4000-char)

**Hook (above-the-fold):**
```
Stop scrolling recipe sites when you already have food at home. Stir scans your kitchen and gives you 3 real dinners in 60 seconds — then guides you step-by-step, hands-free.
```

**Body:**
```
Stop scrolling recipe sites when you already have food at home.

Stir scans your kitchen and gives you 3 real dinners in 60 seconds — then guides you step-by-step, hands-free.

**How it works**
- Point your phone at your fridge, pantry, or counter
- Add a constraint like "20 minutes" or "high protein"
- Get 3 dinner ideas based on what you actually have
- Pick one and cook with step cards, timers, and quick answers
- Go hands-free with voice Cook Mode (Premium — 7-day free trial)
- Fix missing ingredients mid-cook without starting over
- Turn leftovers and missing items into next-day meals

**Built for the exact weeknight moment**
That 10-15 minutes of "what the heck do I cook" — opening the fridge, checking what's still good, scrolling recipe sites, and giving up to make the same thing again. Stir starts there. Three dinners you can actually cook, no decision fatigue.

**Cook hands-free (Premium)**
Flour on your hands? Ask "what's next?" and Stir answers out loud. Out of sour cream? Ask "can I use Greek yogurt?" and keep cooking. Timers start with a word. No touching the phone.

**Waste less food**
Use the spinach before it goes. Turn yesterday's chicken into tonight's dinner. Missing items write straight to Reminders.

**Subscriptions & trial**
- Premium Monthly: $9.99/mo — 40 Dinner Solves + 13 voice Cook Sessions/mo, widgets, shortcuts, leftovers, saved favorites
- Premium Annual: $69.99/yr (7 days free) — save ~42% vs monthly
- Pro Monthly: $14.99/mo — 120 Dinner Solves + 27 voice Cook Sessions/mo, multi-image kitchen scans, priority inference queue
- Pro Annual: $139.99/yr — save ~23% vs monthly

Subscriptions auto-renew unless cancelled 24h before renewal. Cancel anytime in Settings > Apple ID > Subscriptions.

**Free tier**
- 6 Dinner Solves/month + unlimited tap-based Cook Mode
- 25 remembered pantry items
- 2 recipe imports/month
- Text-based substitution suggestions

Terms of Service: https://getstir.app/terms
Privacy Policy: https://getstir.app/privacy

Made for weeknights. Your ingredients, your time, your constraints — three realistic dinners, then out of your way.
```

## Promotional text (170-char, updatable without review)

```
Now with hands-free voice Cook Mode. Scan your kitchen, get 3 dinners, cook step-by-step without touching your phone. 7 days free on Premium.
```

Char count: 149/170.

## What's New (v1.0 launch notes, 4000-char)

```
Welcome to Stir.

**Core loop**
- Scan your fridge, pantry, or counter
- Get 3 dinner ideas in about a minute
- Cook step-by-step with timers and substitutions

**Premium**
- Cook hands-free with voice — ask "what's next?" or "can I use oat milk?"
- Save weeknight winners and cook them again in one tap
- Turn leftovers into tomorrow's dinner
- Home Screen widgets + Shortcuts for faster dinner starts

**Free forever**
- 6 Dinner Solves a month
- Unlimited tap-based Cook Mode
- Text-based substitution suggestions
- Recipe import from URL or screenshot (2/mo)

Made for the exact weeknight moment when you're staring at ingredients with no plan.

Feedback? support@getstir.app
```

---

## App Store Connect configuration

### Subscription group + SKUs

- Group: `stir.subscriptions`
- Family Sharing: OFF on all four SKUs
- Products:
  - `stir.premium.monthly` — $9.99/mo, no trial
  - `stir.premium.annual.trial7` — $69.99/yr, **7-day free trial** (PRIMARY paywall CTA)
  - `stir.pro.monthly` — $14.99/mo, no trial
  - `stir.pro.annual` — $139.99/yr, no trial

### Phased release

Enabled: 10% → 50% → 100% per spec §13. Halt if crash rate > 0.5% in phase 10%.

### Custom product pages (3 at launch)

| Page | Focus | Shots leading |
|---|---|---|
| Default | Fridge scan / dinner ideas | 1-2-5-6 |
| `hands-free-voice` | Voice Cook Mode Premium | 3-7-4-5 |
| `leftovers` | Turn leftovers into meals | 6-1-2-5 |

---

## Pre-submission checks

- [ ] All 4 SKUs configured in App Store Connect; Family Sharing OFF on all
- [ ] Subscription group `stir.subscriptions` created
- [ ] ToS URL (https://getstir.app/terms) returns 200 with legit content
- [ ] Privacy Policy URL (https://getstir.app/privacy) returns 200
- [ ] Privacy nutrition label entered (copy from `app-privacy-details.md`)
- [ ] Keywords entered exactly (no trailing spaces around commas)
- [ ] Age rating questionnaire completed (expected: 4+)
- [ ] Primary + secondary category set
- [ ] Review notes filled with demo account + scenarios (see `review-notes.md`)
- [ ] Build uploaded; encrypted export compliance answered
- [ ] Screenshots uploaded at 1290×2796 (6.7") + 1170×2532 (6.1")
- [ ] Preview video uploaded (portrait, 30s, captioned)
- [ ] Phased release toggled on
