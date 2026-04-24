# Beta QA Checklist

Run against the TestFlight build on a physical device before external tester invites go out. Result tracker: `docs/qa/beta-qa-results.md` (Daniel populates).

Source: spec §16 manual QA + step-9 brief. Pass/fail/partial per row.

---

## Pre-flight (1×)

- [ ] TestFlight build installs cleanly on iPhone 17 Pro (or whatever device Daniel uses for QA)
- [ ] Cold launch < 2s on iPhone 13 (if available); otherwise note device + measured time
- [ ] All 4 SKUs visible in `xcrun simctl status_bar list` or sandbox StoreKit
- [ ] Demo Apple ID (stir-review@getstir.app) has Premium annual trial active

---

## Cold install — no permissions granted (Free tier)

- [ ] Welcome screen shown
- [ ] Onboarding skip-prefs path works → generic defaults applied
- [ ] Kitchen & servings form completes
- [ ] Tonight Home renders with "Scan Kitchen" CTA
- [ ] Camera permission denied → sample-photo fallback offered (no dead-end)
- [ ] Sample photo flows to Scan Review → Constraints → Solve
- [ ] Photos permission denied path: paste-URL recipe import works
- [ ] Reminders permission denied: in-app grocery list with copy/share works
- [ ] Notifications denied: no reactivation push attempted; in-app banners only

---

## Scan flow

- [ ] Scan Review parses ingredients with confidence states visible
- [ ] User correction (rename / add / remove ingredient) persists into next solve
- [ ] Multi-image scan attempt on Free → ENT-MULTI-IMAGE-01 paywall
- [ ] Multi-image scan on Pro → currently NOT YET IMPLEMENTED per pantry-parse/index.ts step-7 TODO; verify backend returns clean error, not crash

---

## Solve flow

- [ ] Constraints sheet works for: "20 minutes", "high protein", "use spinach first"
- [ ] 3 dinner cards render within 3.5s p95
- [ ] Dish preview shows fit labels, steps, timing
- [ ] Hard-rule violations: 0 in 50 representative solves (LAUNCH BLOCKER per spec §16)

---

## Cook Mode — tap variant (Free + all tiers)

- [ ] Step Next/Prev works
- [ ] Timer starts from a step that has one; announces completion
- [ ] Substitution Sheet opens, returns safe suggestion with food-safety footer
- [ ] Session completes → post-cook feedback prompt
- [ ] Background app mid-cook → resume restores step + timer state
- [ ] Force-quit mid-cook → resume same as above

---

## Cook Mode — voice variant (Premium+ only)

- [ ] Voice affordance HIDDEN on Free tier
- [ ] Free tier: tap voice (if discovered) → ENT-VOICE-01 paywall with proper copy
- [ ] Premium: tap voice → mic permission prompt
- [ ] Mic granted: voice session opens; first turn produces audio response
- [ ] Happy path: "what's next?" → spoken answer + audio playback < 1s p95 (ADR 0012)
- [ ] Tool-call path: "can I use oat milk?" → pre-recorded filler audio fires < 150ms; substitution spoken in < 1.5s p95 (ADR 0012)
- [ ] Barge-in: interrupt mid-answer → model stops, listens
- [ ] Session refresh trigger > 4 turns → silent handoff (no user-perceptible gap)
- [ ] Session close: tap-to-end OR "done" → graceful teardown
- [ ] Forced fallback (`disable_cook_realtime=true` flag): AI-VOICE-01 banner + Speech → Gemini text → AVSpeechSynthesizer pipeline works
- [ ] Voice cap: Premium 13/mo enforced; 14th attempt → RATE-01 (ADR 0015)
- [ ] Pro voice cap: 27/mo enforced
- [ ] `voice_turn_stuck_watchdog_fired` rate < 5% across 50 tool-call turns (CLAUDE.md §Deferred trigger)

---

## Tier matrix

- [ ] Free: 6 solves/mo enforced; 7th solve → RATE-01 + paywall trigger
- [ ] Free: 2 imports/mo enforced
- [ ] Free: voice affordance hidden; if found → paywall
- [ ] Premium trial: 40 solves/mo + 13 voice sessions/mo enforced
- [ ] Premium trial: widgets, shortcuts, leftovers, favorites all unlocked
- [ ] Premium paid: trial → paid in sandbox
- [ ] Pro: 120 solves + 27 voice sessions + multi-image (when shipped) + priority queue
- [ ] Upgrade Premium → Pro mid-month: non-metered features (voice access, widgets) flip immediately; metered caps catch up next period (CLAUDE.md snapshot-at-creation rule)

---

## Billing lifecycle (sandbox)

- [ ] INITIAL_PURCHASE with intro offer → `entitlement_snapshots.billing_state='trial'`
- [ ] RENEWAL → 'active'
- [ ] CANCELLATION → 'cancelled_active' (paid access continues to period end)
- [ ] UNCANCELLATION → 'active'
- [ ] BILLING_ISSUE → 'grace' + iOS BILL-01 banner visible
- [ ] EXPIRATION → 'expired' + downgrade to Free tier
- [ ] PRODUCT_CHANGE (Premium → Pro) → 'active' with tier change
- [ ] Restore purchases works across reinstall
- [ ] All 6 transitions log to PostHog `entitlement_state_changed`

---

## Identity flows

- [ ] install:<id> + purchase Premium + sign into iCloud → ck:<record> alias-forward preserves entitlement
- [ ] Verify quota counters SUMMED (not clamped) on alias merge — attempt sign-out + sign-in to reset quota → blocked
- [ ] reauth_required flow: admin `force_reauth` → SIWA re-flow on iOS (ADR 0023)
- [ ] AUTH-01 with reason='expired' → silent re-bootstrap + retry once
- [ ] AUTH-01 with reason='reauth_required' → SIWA screen, NOT silent retry

---

## Offline / degraded

- [ ] Airplane mode: cached entitlements work for 24h
- [ ] Airplane mode: saved meals readable; Cook Mode tap-variant works
- [ ] Cellular + Gemini Live down: AI-VOICE-01 banner + Speech fallback engages within 200ms (pre-warm verified)
- [ ] CloudKit unavailable: local-only mode banner; product continues; voice Cook Mode unavailable (requires CloudKit)
- [ ] Gemini API fully down: AI-01 surfaced; saved meals + cached plans + local timers + manual Substitution Sheet (inert) all work
- [ ] RevenueCat unavailable: 24h cached-entitlement grace; BILL-01 not falsely shown

---

## Permissions (each denied)

- [ ] Camera denied → sample-photo fallback (verified above)
- [ ] Photos denied → paste-URL recipe import path
- [ ] Microphone denied → tap-only Cook Mode (no voice attempt)
- [ ] Reminders denied → in-app grocery list + copy/share
- [ ] Notifications denied → reactivation push suppressed; in-app nudges only
- [ ] Speech Recognition denied (iOS Speech framework) → Voice Cook Mode falls back to AVSpeechSynthesizer-only path with banner

---

## App lifecycle

- [ ] Force-quit mid-Cook Session → resume restores step + timer + a11y state
- [ ] Force-quit mid-recipe-import (async) → APNs push on completion
- [ ] App backgrounded during voice Cook Mode → session gracefully closed (no wasted tokens; refund logic NOT triggered per spec §13)
- [ ] Deep link `stir://tonight?trigger=reactivation` → Tonight Home opens
- [ ] Live Activity start/stop on Cook timer (deferred to step 7 ActivityKit work; verify present at submission)

---

## Kill switches (production flag flip)

- [ ] `disable_scan_parse=true` → scan returns canned "AI temporarily unavailable"; saved-meals-only path works
- [ ] `disable_cook_realtime=true` → all voice Cook Mode → fallback pipeline (re-test ≤30s after flag flip per CLAUDE.md invariant)
- [ ] `disable_imports=true` → recipe import shows IMPORT-01 path
- [ ] `force_saved_meals_only=true` → all solve attempts redirect to saved-meals picker

---

## App Store / legal

- [ ] Paywall: auto-renewal disclosure visible BEFORE Subscribe CTA on all 3 surfaces (soft / feature / settings-upgrade)
- [ ] Paywall: billing date + cancellation path documented inline
- [ ] Paywall: ToS + Privacy Policy links resolve (https://getstir.app/terms + /privacy live)
- [ ] Settings > Privacy: export bundle option present (deferred to v1.1 per spec §11; verify acknowledgment-only at v1)
- [ ] Settings > Privacy: CCPA delete request submittable
- [ ] About screen: subprocessor list visible + accurate
- [ ] Food-safety disclaimer copy present in:
  - [ ] Cook Mode footer
  - [ ] Substitution result
  - [ ] Paywall fine-print
  - [ ] Settings > Privacy > AI Disclosure (full screen)

---

## CCPA deletion (end-to-end)

Per `docs/runbooks/ccpa-deletion-workflow.md` pre-beta test:

- [ ] Throwaway Apple ID + 15-min usage → request deletion
- [ ] Email confirmation arrives
- [ ] APNs push arrives ("deletion request received")
- [ ] Approving in ops console enqueues backend deletion
- [ ] Within 24h: all Supabase tables show 0 rows for that canonical_user_key
- [ ] PostHog persons-API delete request returns 200
- [ ] Sentry shows user marked for deletion in Data Erasure dashboard
- [ ] Re-signing in 24h+ later: app behaves like fresh install

---

## Accessibility (manual VoiceOver pass)

Per `docs/qa/accessibility-audit.md` "Manual VoiceOver pass" section:

- [ ] Onboarding flow VoiceOver readout is logical
- [ ] Tonight Home reads cleanly (no decorative elements focused)
- [ ] Scan + Solve + Cook Mode tap variant: all interactive elements have clean labels
- [ ] Cook Mode voice variant + VoiceOver: no audio collision; mic state announces
- [ ] Substitution + Paywall + Settings + Plan & Billing: all screens pass
- [ ] Dynamic Type at AX5: no critical text clipping; layout reflows
- [ ] Voice Control: every primary action invokable by spoken command
- [ ] Reduce Motion: animations gated correctly (LoadingView, OnboardingCompletion, PaywallView)
- [ ] Contrast: WCAG AA minimum (4.5:1 normal, 3:1 large) across light + dark modes

---

## Performance (Instruments-measured)

Per `docs/qa/perf-audit.md`:

- [ ] Cold launch < 2s on iPhone 13
- [ ] Solve TTFB < 2s p95 (PostHog ai_request_completed query)
- [ ] Voice TTFA: normal turn < 500ms p95; tool-call turn < 1500ms p95 (ADR 0012)
- [ ] Cook Mode step transition < 200ms (timing probe)
- [ ] Scroll: 120Hz on Tonight Home, Dinner Options, Saved list (Animation Hitches template)

---

## CloudKit two-device test

- [ ] Sign into same iCloud account on Device A + Device B
- [ ] Save a favorite on Device A → appears on Device B within 5 minutes
- [ ] Add a pantry item on Device A → appears on Device B
- [ ] Cook a session on Device A → meal rating syncs to Device B's history
- [ ] Edit dietary preferences on Device B → reflects on Device A within 5 minutes

---

## Beta success thresholds (measured during 2-week beta, not pre-flight)

Per spec §16; documented in `docs/qa/beta-metrics.md`:

- [ ] 70% of beta users reach aha moment
- [ ] 50% complete ≥1 Cook Session
- [ ] ≥25% of Free beta users voice-tap → trial start
- [ ] Median meal rating ≥ 4
- [ ] Hard-rule violations in beta = 0 (LAUNCH BLOCKER)
- [ ] AI cost / Premium < $2.50/mo
- [ ] AI cost / Pro < $6.50/mo
- [ ] Cook Mode Live API share ≥ 90%
- [ ] Preamble-present rate ≥ 90%

---

## Sign-off

- Pre-flight + cold-install + scan + solve + Cook Mode + tier matrix + billing + identity + offline + permissions + lifecycle + kill switches + App Store/legal + CCPA + a11y + perf + CloudKit two-device: ALL must pass before TestFlight external invites
- Beta-thresholds: measured during beta; gating App Store submission
