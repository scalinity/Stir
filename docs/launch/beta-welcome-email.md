# Beta welcome email

Drop-in copy Daniel sends to each external TestFlight tester at invite time. Two cold-open variants below — pick the one that matches the tester's recruitment channel. Everything else (what-Stir-is, beta scope, first-run, feedback, NDA, close-out) is shared.

> **Status:** scaffold. Voice/copy needs Daniel's pass before the first send. Placeholders marked `[…]`. Replace before sending.

---

## Subject line + preheader

**Subject (personal network):** `You're in — Stir TestFlight invite`
**Subject (cold recruit):** `Stir TestFlight beta — your invite is here`

**Preheader** (renders under subject in most clients, ~90 chars):
`First-time look at Stir, an iPhone app for "what's for dinner" when you don't have a plan.`

---

## Cold-open A — personal network

Hey [FIRST NAME],

You probably know I've been heads-down on Stir for the last few months. The TestFlight is finally ready and I'd love your eyes on it before the App Store launch.

Honest ask: open it once or twice this week, scan whatever's in your fridge, see if it figures out something dinner-shaped. Tell me what felt right and what felt off. That's it — no scripted test plan, no formal feedback form. Real-fridge usage is what I need.

[CONTINUE TO "What Stir is" SECTION]

---

## Cold-open B — Reddit / Discord recruit

Hey,

Thanks for raising your hand for the Stir beta — appreciate you giving an unknown app a shot.

Quick context: Stir is a one-person project (I'm Daniel) and you're one of about 10–15 external testers in this round. Your TestFlight invite should be in your inbox alongside this email. The beta runs for [BETA WINDOW — e.g. 2 weeks starting YYYY-MM-DD]; after that we either ship to the App Store or pull back for another round, depending on what you all find.

The point of this email is to set expectations on what to do, what to ignore, and how to tell me when something breaks. Read the rest of this once, then forget it and just use the app.

[CONTINUE TO "What Stir is" SECTION]

---

## What Stir is (shared)

Stir is an iPhone app for the weeknight moment: you're in the kitchen with whatever's in the fridge, no plan, low energy. Take a photo of your ingredients → get three dinner options that actually use what you have → tap into Cook Mode and follow step-by-step with timers. Premium adds hands-free voice cooking ("hey, I'm out of cumin — what should I use?") and a few other extras.

It's iPhone-only, US English-only, iOS 17+, and there's no web/desktop companion in v1. If you're missing any of those, the beta isn't going to work for you and that's on me — let me know and I'll pull your slot.

---

## Beta scope (shared)

**You have full Premium access during the beta.** That includes voice Cook Mode, multi-image scan, leftovers mode, and saved favorites — even though most of those are paid in production. Use them, push them, find the rough edges. Subscription billing is disabled for beta builds; you won't see a paywall and you won't get charged.

After the beta, your access reverts to whatever subscription state you choose at App Store launch (or Free, which is generous on the core scan-and-cook flow). The beta build will stop working once we ship to the App Store; you reinstall the production app from there.

---

## First-run instructions (shared)

Five things, in order, the first time you open the app:

1. **Sign in to iCloud on the device first.** Stir keeps your pantry, saved meals, and cook history in your private CloudKit container. Without iCloud signed in, nothing syncs and the experience is degraded. (Settings → tap your name at the top — make sure you're signed in.)
2. **Allow camera + microphone when the app asks.** Camera is for scanning your pantry; microphone is for voice Cook Mode. You can deny either and still use most of the app, but the aha-moment depends on the camera prompt.
3. **Scan a real fridge, not a tidy staged shelf.** The model is trained for messy real-life — partially used ingredients, weird angles, half-empty jars. The first scan is the make-or-break moment; please use a fridge you actually own.
4. **Pick one of the three dinner options and tap into Cook Mode.** Don't skim — actually go through the steps with timers. The whole product is the kitchen-floor experience.
5. **Rate the meal at the end (1–5 stars).** That signal is how Stir learns your preferences. The rating screen takes 5 seconds; please don't skip it.

If anything in steps 1–5 breaks, that's the most valuable thing you can report.

---

## Feedback channel (shared)

[FEEDBACK CHANNEL — fill in one of: Linear-portal URL / dedicated email like beta@getstir.app / Discord channel invite. PICK ONE before first send and stick with it for the whole beta.]

I read every message. There's no "wrong" feedback during a beta — micro-irritations matter as much as crashes.

---

## What to do when something breaks (shared)

If the app crashes or shows an error screen:

1. **Screenshot the screen** (Power + Volume Up).
2. **If there's a Sentry event ID visible, copy it.** It looks like 8–10 hex characters; appears at the bottom of error screens.
3. **Send both** to [FEEDBACK CHANNEL] with one line of context — what you were doing right before.

That's it. You don't need to reproduce the bug. You don't need to investigate. Screenshot + event ID + one line is enough; I can pull up the full crash report on my end from there.

---

## What NOT to share publicly (shared)

You're under a soft NDA — not legally binding, but please:

- **Don't post screenshots, screen recordings, or App Store-style mockups publicly.** That includes Twitter, Reddit, Discord servers outside the beta channel, TikTok, etc. The pre-launch product is in flux and out-of-context screenshots stick around.
- **Don't share the TestFlight invite link.** Apple caps external testers at a fixed number; an unauthorized invite burns a slot a real tester needs.
- **Don't forward this email** without checking with me first.

If a friend asks "what are you using?" tell them about it generally — I'm not asking you to be cagey — but please don't ship them the install link or screenshots. We launch publicly soon and I'd rather lead with the polished version.

---

## Beta close-out + what comes after (shared)

The beta runs through [CLOSE DATE — usually invite date + 14 days]. On the close date:

- **Your TestFlight build expires.** Apple cuts off external builds 90 days after the upload date by default; this beta will likely run shorter than that. You'll see a "build expired" message in the app.
- **The App Store version goes live within ~1 week of beta close** (assuming Apple approves on the first review pass — they usually do, but I can't promise).
- **Reinstall the production app from the App Store** when it's available. Your iCloud data carries over — pantry, saved meals, cook history all show up on the production build because it's the same CloudKit container.
- **You revert to whatever subscription state you choose.** Free is fine for most use; Premium unlocks voice + a few other things; Pro is mostly a "I want unlimited" tier.

After launch, if you stay engaged, I'll occasionally invite you to subsequent betas (v1.1, v1.2). Opt-in, no obligation. If you want off the list at any point, one-line email and I'll remove you.

---

## Sign-off

Thanks again for spending real time on this. Beta testers are the difference between "the app I built" and "the app people actually use," and I'm in your debt.

Daniel
[CONTACT EMAIL]

---

## Pre-send checklist (for Daniel)

- [ ] Voice/copy pass — sound like a real human, not a structured doc
- [ ] Pick ONE feedback channel and replace `[FEEDBACK CHANNEL]` everywhere
- [ ] Fill `[BETA WINDOW]` and `[CLOSE DATE]` with real dates
- [ ] Replace `[FIRST NAME]` per recipient (or strip the line for the cold variant)
- [ ] Replace `[CONTACT EMAIL]` with the address you want replies on
- [ ] Decide: send via Apple's TestFlight invite email body, or send separately and let TestFlight's email be transactional? (Recommend separately — Apple's email is short on context.)
- [ ] First send goes to a personal-network tester to sanity-check the email render on iOS Mail / Gmail / Outlook before the cold batch

---

## Provenance

- Step-9 plan Phase 7 Task 7.2 — `docs/superpowers/plans/2026-04-24-step-9-beta-launch.md`
- Release gate item — `docs/launch/release-gate.md:85`
- Linear: SCA-215 (parent SCA-58)
