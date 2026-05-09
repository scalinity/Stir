# Release Gate Checklist — Step 9 → App Store Submission

**Status owner:** Daniel
**Last updated:** 2026-04-24

Every item below MUST be ticked before submitting Stir v1.0.0 to App Store review.

Composite of:
- Spec §19 — Legal & Regulatory Checklist
- CLAUDE.md release-gate items in step-9 brief
- Phase 0-9 deliverables produced during step 9 (cross-referenced inline)

Pass criterion: every box checked OR explicit "Blocked on:" entry with owner + ETA.

---

## 0. Build correctness

- [ ] `xcodebuild build -scheme Stir -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` returns BUILD SUCCEEDED with zero non-noise warnings
- [ ] `deno test --config Backend/supabase/functions/deno.json --allow-all Backend/supabase/tests/` all green in isolation (full-suite flakiness per CLAUDE.md §Deferred shared-edge-runtime entry acknowledged but not blocking)
- [ ] No API keys in iOS bundle: `grep -rn "AIzaSy\|sk-proj\|sk-[a-zA-Z0-9]\{20\}\|AQ\." Stir/ --include="*.swift" --include="*.plist" --include="*.xcconfig"` returns zero matches (confirmed 2026-04-24, Phase 0)

---

## 1. Core product flows

- [ ] Full happy path Free tier (scan → 3 dinners → tap-Cook Mode → done)
- [ ] Full happy path Premium trial (above + voice Cook Mode + saved favorites + leftovers)
- [ ] Full happy path Premium paid (post-trial transition in sandbox)
- [ ] Full happy path Pro (multi-image scan when shipped + priority queue when wired)
- [ ] All permission-denied fallbacks tested (camera / photos / mic / reminders / iCloud / notifications)
- [ ] CloudKit sync verified across 2 devices (favorites + pantry + dietary prefs)
- [ ] Local-only mode works without iCloud (banner shown; Cook Mode tap variant works)
- [ ] Offline mode: 24h cached entitlement + read-only cook paths

Reference: `docs/qa/beta-qa-checklist.md` sections "Cold install" through "Offline / degraded".

---

## 2. Voice Cook Mode

- [ ] Voice works for Premium+ (happy + barge-in + tool-call + refresh + close)
- [ ] Forced fallback tested (`disable_cook_realtime=true` flag + AI-VOICE-01 banner + Speech → Gemini text → AVSpeechSynthesizer)
- [ ] Free tier voice-tap → ENT-VOICE-01 paywall (verified)
- [ ] Voice cap enforcement: Premium 13/mo, Pro 27/mo (ADR 0015)
- [ ] `voice_turn_stuck_watchdog_fired` rate < 5% of tool-call turns (CLAUDE.md §Deferred)
- [ ] Voice TTFA p95: normal turn < 500ms; tool-call turn < 1500ms (ADR 0012 split-gate)
- [ ] Cook Mode Live API share ≥ 90% in beta (per spec §16 threshold)
- [ ] Preamble-present rate ≥ 90% in beta tool-call turns (per spec §16 threshold)

Reference: `docs/qa/beta-qa-checklist.md` "Cook Mode — voice variant"; `docs/qa/perf-audit.md` voice TTFA section.

---

## 3. AI quality

Eval results from CI nightly runs against staging defaults (per spec §16):

- [ ] `eval_pantry_scan_v1`: precision ≥ 0.90, recall ≥ 0.75
- [ ] `eval_dinner_solve_v1`: 100% hard-rule pass, 85% cookability
- [ ] `eval_cook_turns_v1`: wrong-step rate < 3%, preamble-present ≥ 95%
- [ ] `eval_substitutions_v1`: **100% hard-rule pass, 0 allergen violations** (LAUNCH BLOCKER per spec §16)
- [ ] `eval_recipe_import_v1`: 85% acceptable
- [ ] `eval_grocery_v1`: 98% missing-item recall

---

## 4. Billing & subscription

- [ ] Trial start + conversion + cancellation + grace + reactivation tested in StoreKit sandbox
- [ ] Upgrade Premium → Pro tested (mid-month + at renewal); non-metered features flip immediately, metered caps catch up next period (CLAUDE.md snapshot rule)
- [ ] Downgrade Pro → Premium tested
- [ ] Restore purchases works across reinstall
- [ ] All 6 `billing_state` transitions logged + dashboard-visible (`none|active|trial|grace|cancelled_active|expired`)
- [ ] RevenueCat webhook signature verified
- [ ] Install→ck alias-forward preserves entitlement
- [ ] Quota anti-abuse: install→ck merge SUMS counters (not clamps); sign-out + sign-in does NOT reset quota

---

## 5. Beta period (2-week minimum)

- [ ] First TestFlight build uploaded + Beta App Review cleared (runbook: `docs/launch/testflight-setup.md`)
- [ ] Apple TestFlight external group ran for ≥ 2 weeks
- [ ] 10-15 testers recruited from spec §17 audience
- [ ] Beta welcome email sent (`docs/launch/beta-welcome-email.md` — Daniel writes; deferred to Phase 7)
- [ ] Beta thresholds met (per spec §16, measured in `docs/qa/beta-metrics.md`):
  - [ ] 70% of beta users reached aha moment
  - [ ] 50% completed ≥ 1 Cook Session
  - [ ] ≥ 25% of Free voice-tap → trial start
  - [ ] Median meal rating ≥ 4
  - [ ] Hard-rule violations = 0 (LAUNCH BLOCKER)
  - [ ] AI cost / Premium < $2.50/mo
  - [ ] AI cost / Pro < $6.50/mo
- [ ] Top 5 beta-feedback issues triaged (fix / defer-to-v1.1 / accept)
- [ ] If hotfix needed: single hotfix pass + new TestFlight build + smoke-tested
- [ ] If thresholds missed: extend beta rather than ship (per CLAUDE.md invariant)

---

## 6. Accessibility

Per `docs/qa/accessibility-audit.md`:

- [ ] VoiceOver pass on Onboarding / Tonight / Scan / Solve / Cook Mode (tap + voice) / Substitution / Paywall / Settings / Plan & Billing
- [ ] Dynamic Type at all sizes XS-AX5
- [ ] Tap targets ≥ 44×44
- [ ] Voice Control labels (every primary action invokable by spoken command)
- [ ] Reduce Motion respected
- [ ] Contrast WCAG AA (4.5:1 normal, 3:1 large)
- [ ] 5 specific code-level a11y fixes shipped (search bar, grocery dismiss, leftovers plus, paywall handleSuccess animation — committed 1598fd7)

---

## 7. App Store submission package

Per `docs/appstore/`:

- [ ] App name + subtitle + keywords + 4000-char description (`metadata.md`)
- [ ] Promotional text (170-char, updatable without review)
- [ ] What's New (release notes for v1.0)
- [ ] 10 screenshots × 2 device classes (6.7" + 6.1") — per `screenshots.md` storyboard
- [ ] 30s preview video (portrait, captioned, voice Cook Mode hero) — per `preview-video-script.md`
- [ ] App Privacy nutrition label entered in App Store Connect (`app-privacy-details.md` is source of truth)
- [ ] `Stir/App/PrivacyInfo.xcprivacy` present + accurate (committed 939df9b)
- [ ] Paywall disclosure compliance audit passed (`paywall-disclosure-audit.md`)
- [ ] Review notes filled (`review-notes.md` — demo account + scenarios + AI disclosure)
- [ ] ToS URL https://getstir.app/terms returns HTTP 200 with legitimate content
- [ ] Privacy Policy URL https://getstir.app/privacy returns HTTP 200
- [ ] Phased release configured 10% → 50% → 100%
- [ ] Custom product pages (3) configured: Default / hands-free-voice / leftovers

---

## 8. Legal

Per `docs/legal/`:

- [ ] Terms of Service finalized (lawyer-reviewed, [LEGAL REVIEW REQUIRED] markers resolved)
- [ ] Privacy Policy finalized (lawyer-reviewed)
- [ ] Food-safety disclaimer wording finalized (`food-safety-disclaimer.md` — 4 in-app copy sites: Cook Mode footer, Substitution result, Paywall fine-print, Settings > Privacy > AI Disclosure full screen)
- [ ] CCPA deletion workflow tested end-to-end (`docs/runbooks/ccpa-deletion-workflow.md` pre-beta test section; legal-compliance companion at `docs/legal/ccpa-deletion-runbook.md`)
- [ ] privacy@getstir.app mailbox provisioned + 48h SLA auto-responder live
- [ ] support@getstir.app mailbox provisioned + 48h SLA auto-responder live
- [ ] Trial disclosure on every paywall meets Apple's current subscription requirements (audited in `paywall-disclosure-audit.md`)

---

## 9. Infrastructure

- [ ] Kill switches tested in production (4 flips) — `disable_scan_parse / disable_cook_realtime / disable_imports / force_saved_meals_only`. Each must take effect within 30 seconds of flag change (per CLAUDE.md invariant)
- [ ] Sentry alerts configured (per `docs/sentry/alerts.md` — step 8 deliverable)
- [ ] PostHog dashboards configured (per `docs/posthog/dashboards.json` — step 8 deliverable)
- [ ] Ops console accessible with admin role (`/ops` SPA per step 8)
- [ ] Backend rate limiting active (per-IP + per-user across all `/v1/*`)
- [ ] RevenueCat webhook signature verified
- [ ] Session pruning verified — voice cumulative tokens < 40K in 95%+ of sessions
- [ ] Prod Supabase region adjacent to Gemini endpoint (verify per spec §21.30; us-central1 default)
- [ ] LOG_IP_SALT secret set on prod (per `docs/runbooks/ip-salt-rotation.md` — committed 82624b5)
- [ ] APNs push delivery confirmed working

---

## 10. Code-level pre-flight (one-shots)

- [ ] All in-app copy (paywall, Cook Mode, substitution, settings) uses correct cap numbers per ADR 0015 (Premium 13 voice, Pro 27 voice)
- [ ] Spec §9, §10, §12 caps match CLAUDE.md (verified 2026-04-24, Phase 0; committed c452ad6)
- [ ] No `[TBD]` / `XXX` / `FIXME-LAUNCH` markers in shipping code (`grep -rn "FIXME-LAUNCH\|TBD\|XXX" Stir/ --include="*.swift"` returns zero hits)
- [ ] Privacy nutrition label aligns with `PrivacyInfo.xcprivacy` (subprocessor list + collected data types match)
- [ ] All third-party SDKs verified to ship privacy manifests (RevenueCat 5.68+, PostHog 3.54+, Sentry 8.58+; supabase-swift 2.43.1 doesn't ship one but isn't on Apple's listed SDK list — Daniel re-verifies at submission time)
- [ ] CFBundleShortVersionString matches across main app + 2 extensions (1.0.0; committed 939df9b)

---

## 11. Launch readiness

- [ ] On-call rotation documented (Daniel solo, 72h post-launch window)
- [ ] Incident response plan written (`docs/runbooks/incident-response.md` — Daniel writes pre-beta)
- [ ] Phased release rollback trigger defined (crash rate > 0.5% in phase 10% → halt + investigate)
- [ ] Social media posts queued (per spec §17 — X/LinkedIn/Reddit/founder story; Daniel writes)
- [ ] Customer support SLA documented (48h first response)
- [ ] Apple Developer Program enrolled ($99/yr active, per spec §21.3)
- [ ] App Store Connect app records created for all 3 bundle IDs (dev/beta/prod, per spec §21.4)

---

## 12. Capabilities + provisioning (Apple Developer)

Per spec §21.5:

- [ ] iCloud / CloudKit
- [ ] In-App Purchase
- [ ] Push Notifications
- [ ] Background Modes (remote notifications, background fetch)
- [ ] App Groups (for share extension + widget IPC)
- [ ] Widgets / Live Activities
- [ ] CloudKit container schema deployed to production (per spec §21.6)
- [ ] APNs auth key generated + uploaded to backend secrets (per spec §21.16)

---

## 13. Cost & margin verification

- [ ] AI cost / Premium user / month measured during beta < $2.50 (per spec §16; CLAUDE.md target $1.89 with $1.69-$2.08 measured range at 13-cap)
- [ ] AI cost / Pro user / month measured during beta < $6.50 (per spec §16; CLAUDE.md target $3.69 with $3.51-$4.32 measured range at 27-cap)
- [ ] Cohort economics from spec §9 hold against 2 weeks of beta data (Premium monthly CM ≥ $6.25/mo at $9.99 ARPU; Pro annual year-1 CM ≥ $4.13/mo)

---

## 14. Step-9 §Deferred items resolved

Per `docs/superpowers/plans/step-9-deferred-survey.md`:

- [ ] M1 — Per-feature canned_fallback_json schema registry (DEFERRED in step-9 session pending Daniel's parallel WIP commit; ship before opening ops console to non-Daniel admins)
- [ ] M2 — Source-IP HMAC salt (SHIPPED 82624b5)
- [ ] M3 — stir_ops_cost_anomaly_scan session_id rewrite + runaway_session detector (DEFERRED in step-9 session; ship before beta scale ramp)
- [ ] M4 — Error envelope drift protection (SHIPPED a9f2056)
- [ ] S3 — Pre-push hook (Tier-2; defer to v1.1 if not shipped)

Items deferred to v1.1 (logged in `docs/roadmap/v2.md` — Phase 8):
- TanStack Query migration for ops SPA
- ops SPA runtime test harness (Vitest + RTL)
- W16 processPushSend integration coverage
- APNs untested changes W10/W11/W44
- pgmq-dispatch reclaim sweep as SQL stored proc
- RealtimeSession three-part split (LOC trigger; touch owns)
- CookModeViewModel voice-telemetry extraction (LOC trigger)

---

## Sign-off

When all items above are checked OR explicitly blocked-with-ETA:

- [ ] Status: **Ready for App Store submission**
- [ ] OR — **Blocked on:** [enumerate specific items + owner + ETA]

Decision rule: if ANY beta-threshold (§5) or AI-quality-eval (§3) is missed, EXTEND BETA rather than submit. Submission is not the finish line; a working product is.

After submission:
- Apple review window: 24-72h typical
- Daniel available to respond to reviewer questions within 24h
- Phased release auto-progresses 10% → 50% → 100% if no reject signal
- Crash-rate-monitoring + AI-cost-monitoring stay live for first 72h
