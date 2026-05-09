# TestFlight setup runbook

End-to-end procedure for shipping the first Stir TestFlight build, configuring the external test group, and starting the beta window. Daniel-owned; this runbook stands up the skeleton so the upload sequence isn't recall-from-memory.

> **Status:** scaffold. Validated against Apple docs and `xcodebuild`/`xcrun altool` behavior at the time of writing; commands may shift between Xcode versions. Re-verify before first run, especially the `xcrun altool` → `xcrun notarytool` migration if a future Xcode deprecates `altool`.

> **Related:** SCA-213 (this runbook), SCA-217 (130-item beta-qa checklist run on the build this runbook produces), SCA-218 (App Store screenshots), `docs/launch/release-gate.md` Phase 7.

---

## Pre-flight checklist (1×, before first archive)

- [ ] **Xcode 26+ installed** (per CLAUDE.md, iOS 26 SDK is required for App Store as of 2026-04-28)
- [ ] **Apple Developer Program account active** for the team that owns bundle ID `com.scalinity.stir`
- [ ] **Apple ID signed in** in Xcode → Settings → Accounts; team selectable in target signing pane
- [ ] **Distribution certificate present** (Xcode → Settings → Accounts → Manage Certificates → Apple Distribution; if absent, click `+` → Apple Distribution)
- [ ] **App Store Connect record created** for `com.scalinity.stir` at https://appstoreconnect.apple.com
  - SKU: `stir-ios-v1`
  - Primary language: English (U.S.)
  - Bundle ID: `com.scalinity.stir`
  - Privacy Policy URL: https://getstir.app/privacy (gated on SCA-212 lawyer review + URL going live)
- [ ] **App Store Connect → App Information → Privacy details filled** — required even for TestFlight external groups; Apple shows the Privacy nutrition label to testers and reviewers
- [ ] **Archive scheme set to Release.** Stir scheme → Run → Build Configuration → Release. Archive uses Run config by default.
- [ ] **Automatic signing OFF for the Stir target** when distributing — Xcode → Stir target → Signing & Capabilities → uncheck Automatically manage signing for Release. Manual provisioning profile required for App Store distribution. (Automatic is fine for Debug/local sim runs.)
- [ ] **Provisioning profile**: download or generate `Stir App Store` profile in Apple Developer portal → Profiles → `+` → Distribution → App Store → choose `com.scalinity.stir` → use the Distribution certificate above → name it `Stir App Store`. Drag the `.mobileprovision` into Xcode.
- [ ] **Entitlements verified** in `Stir.entitlements`: `aps-environment = production`, CloudKit container identifier `iCloud.com.scalinity.stir`, App Groups for widget extension, Sign in with Apple capability if used. Mismatch with Developer portal capabilities = upload reject.
- [ ] **Build number bump rule** decided: monotonically increasing across all uploads to App Store Connect (TestFlight + Production share the build-number namespace). Recommended: `MARKETING_VERSION` = `1.0.0`, `CURRENT_PROJECT_VERSION` = unix timestamp at archive time, OR a simple incrementer maintained in `Stir.xcconfig`.

---

## Archive command

From the repo root, with the Stir scheme selected:

```bash
xcodebuild \
  -scheme Stir \
  -destination 'generic/platform=iOS' \
  -archivePath build/Stir-$(date +%Y%m%d-%H%M%S).xcarchive \
  -configuration Release \
  archive
```

Notes:
- Use `generic/platform=iOS` (not a simulator destination) — archives target real devices.
- Archive path uses a timestamp so re-runs don't clobber prior archives.
- Watch the build log for **provisioning errors** ("No profiles for 'com.scalinity.stir' were found") and **entitlement mismatches** ("doesn't match the entitlements file's value for the X entitlement"). Both block archive.
- Archive takes longer than a debug build (full symbol generation, dSYM, no compiler short-circuits). 5–10 min on M-series Mac is normal.

---

## Export options plist

Save as `build/ExportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store</string>
  <key>destination</key>
  <string>upload</string>
  <key>teamID</key>
  <string>[YOUR_TEAM_ID]</string>
  <key>uploadBitcode</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
  <key>signingStyle</key>
  <string>manual</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.scalinity.stir</key>
    <string>Stir App Store</string>
    <key>com.scalinity.stir.StirWidgets</key>
    <string>StirWidgets App Store</string>
    <key>com.scalinity.stir.StirShareExtension</key>
    <string>StirShareExtension App Store</string>
  </dict>
</dict>
</plist>
```

Replace `[YOUR_TEAM_ID]` with the 10-char Team ID from Apple Developer → Account → Membership. Add a `provisioningProfiles` entry for every embedded extension target (widgets, share extension, app intents — verify the bundle IDs match `Stir.xcodeproj` target settings).

`uploadBitcode = false` because Apple deprecated bitcode for iOS in Xcode 14; setting it `true` causes a warning but doesn't block.

---

## Upload command

```bash
xcodebuild \
  -exportArchive \
  -archivePath build/Stir-<timestamp>.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist
```

Or use Apple's Transporter app (App Store): drag the `.ipa` from `build/export/` into Transporter → Sign in → Deliver. Transporter is more forgiving than CLI for first-time uploads — it shows specific errors with copyable text. Use it for the first upload; switch to CLI once the flow is reliable.

After upload completes:
1. Wait 10–30 minutes for App Store Connect to finish processing the build.
2. App Store Connect → Stir → TestFlight tab → confirm the build appears under iOS Builds with "Processing" → "Ready to Submit" or "Missing Compliance".

---

## Beta App Review pre-submission

Apple reviews the **first** external TestFlight build (and any build with significant new features). Internal testing groups skip this review; external groups require it.

In App Store Connect → Stir → TestFlight → External Testing → on the build's Test Information page:

- [ ] **What to test** copy (≤ 4000 chars):
  ```
  Stir is an iPhone-only app for the weeknight "what's for dinner" moment. Open the app, scan whatever's in your kitchen, get three dinner options, then cook with hands-free voice or tap-through Cook Mode.

  Things to try:
  - Sign in to iCloud first (Settings → Apple ID), then open the app and scan a real (messy) fridge.
  - Pick a dinner option you'd actually eat. Run the cook flow end-to-end with timers.
  - Try voice Cook Mode (Premium, free during beta) — ask "I'm out of cumin, what should I use?" mid-recipe.
  - Rate the meal at the end. The 1–5 star rating teaches Stir your preferences.

  Known limits:
  - English / US only at launch.
  - iPhone only — no iPad layout, no companion web/desktop.
  - First-cook flow is the aha moment; please report anything that breaks or feels wrong there.
  ```
- [ ] **Demo account credentials** — Apple needs a working sign-in path if your app has auth. Stir is no-mandatory-login, so the demo-account block can read: "No login required. Sign in to iCloud on the device for full functionality (pantry sync). Without iCloud, the app still functions in single-device mode." Apple's reviewer needs to be able to reach the core flow without a login wall.
- [ ] **Sign-in info** field — leave blank if no login required, or provide a sandbox Apple ID + StoreKit sandbox account if using SIWA. (Stir uses Sign in with Apple optionally; provide a sandbox tester if SIWA is on for the beta build.)
- [ ] **Contact info** — your email, phone, and first/last name (Apple uses this if reviewer has questions).
- [ ] **Notes for the reviewer** (≤ 4000 chars):
  ```
  Stir uses CloudKit private database for user content and Supabase for operational metadata only. No user-generated content is stored on third-party servers. Camera + microphone permissions are gracefully degradable — denying either does not crash the app.

  Voice Cook Mode uses Google Gemini Live API via ephemeral session tokens minted server-side. No API keys are bundled in the app. During beta, voice access is open to all testers regardless of subscription state; production gates voice behind Premium per ADR 0015.

  StoreKit subscription products are present but billing is disabled for beta builds via RevenueCat sandbox keys. Testers see Premium-tier features unlocked without a paywall.

  Privacy Policy: https://getstir.app/privacy
  Terms of Service: https://getstir.app/terms

  If reviewer needs to reproduce a bug, please contact me at [CONTACT EMAIL] — I can stage the demo account state remotely.
  ```
- [ ] **App review attachment** — optional screenshot/video walkthrough; helpful for reviewers if any feature is non-obvious. (Not required.)

Submission usually clears within 24–48 hours. Reject reasons commonly seen:
- Privacy Policy URL not live (gated on SCA-212 + lawyer review)
- Demo account/sign-in info doesn't work (verify before submit)
- "What to test" too short or generic ("please test the app")
- Crash on launch on reviewer's device (re-test on a clean simulator profile pre-submit)

---

## External test group setup

App Store Connect → Stir → TestFlight tab → External Testing section → click **`+`** to add a new group.

- [ ] **Group name**: `Stir v1.0 External Beta`
- [ ] **Enable public link**: NO for the first cohort. Public links bypass per-tester invite emails and dilute the cohort. Enable only if recruitment exhausts personal-network + curated channels.
- [ ] **Add testers**: invite via Email tab → paste tester emails (one per line). Apple sends a TestFlight invite email automatically; recipient redeems the invite, installs TestFlight, then installs Stir.
- [ ] **Build assignment**: select the latest processed build from the dropdown.
- [ ] **Public link expiration**: N/A unless public link enabled.

Apple caps external testers at **10,000 across all external groups**, but per-group cap is implicit — keep the first cohort to 10–15 (per spec §17 audience). Larger cohorts dilute feedback signal and inflate the support burden.

---

## Tester recruitment outreach templates

For the cold-recruit batch (Reddit, Discord, niche forums). Skip personal-network — those are 1:1 conversations.

### Reddit / forum post template

> **Title:** `[BETA] iOS dinner-decision app for weeknight cooks — looking for 5–10 testers`
>
> Hey r/[SUBREDDIT],
>
> I'm shipping an iPhone-only app called Stir that solves the "what's for dinner with what I have" problem. You scan your fridge, get three dinner ideas using only what's there, and cook with timers + (Premium) hands-free voice. iOS 17+, US English, 2-week TestFlight beta.
>
> **What I'm looking for:**
> - You actually cook at home most weeknights (not aspirationally — actually).
> - You have an iPhone signed into iCloud.
> - You're willing to send 1–2 short feedback messages over the 2-week window.
> - You're OK using a beta app where things might break.
>
> **What you get:** full Premium access during the beta (voice cooking + everything else), and your name in the credits if you want it.
>
> **What I don't need:** anyone looking for free Premium long-term, anyone who wants to stress-test scale, designers or PMs auditioning for a job — just home cooks.
>
> Reply or DM with a one-line description of how you cook on weeknights. I'll send TestFlight invites to the first 10–15 that match.

### Discord channel template

Shorter, more conversational:

> Hey, looking for 5 iPhone home cooks for a 2-week TestFlight beta of Stir — scan-your-fridge → three-dinners → cook-with-timers app. iOS 17+, US English. Full Premium during beta. Reply if you cook real meals on weeknights and want in.

### Personal-network outreach (1:1, not template-shaped)

For close friends/colleagues, just text or email them directly with the gist + ask. The structured ask shape feels weird coming from someone they know. Daniel writes those.

---

## What to do when the first upload fails

The first upload to App Store Connect almost always fails for one of these reasons. Match the error to the fix.

| Symptom | Probable cause | Fix |
|---|---|---|
| "No profiles for 'com.scalinity.stir' were found" | No Distribution provisioning profile, or wrong type | Apple Developer → Profiles → create `Stir App Store` (Distribution / App Store / com.scalinity.stir). Drag the `.mobileprovision` into Xcode. |
| "Code signing 'Stir.app' failed" | Distribution certificate missing or expired | Xcode → Settings → Accounts → Manage Certificates → `+` Apple Distribution. |
| "doesn't match the entitlements file's value for the … entitlement" | Capability enabled in Xcode but not on Developer portal (or vice versa) | Apple Developer → Identifiers → `com.scalinity.stir` → enable matching capability. Re-download the provisioning profile after change. |
| "ITMS-90683: Missing Purpose String in Info.plist" | iOS 14+ requires `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, etc. | Add `NSCameraUsageDescription` and `NSMicrophoneUsageDescription` strings to `Stir/Info.plist` with user-facing reasons. Also `NSPhotoLibraryUsageDescription` if photo picker is used, `NSRemindersUsageDescription` if Reminders integration. |
| "ITMS-90809: Deprecated API Usage" | Some private framework or deprecated API path triggered the linter | Read the specific API in the rejection email; usually a Carthage/SPM dep that's behind. Update or remove. |
| Build is stuck "Processing" for >2h | App Store Connect bug, sometimes a TLS handshake fail on Apple's side | Wait. If still stuck after 4h, contact App Store Connect support. Don't re-upload — duplicate processing rows confuse the review queue. |
| Upload succeeds, but build never appears in TestFlight | Likely missing `aps-environment` or other entitlement; build was rejected silently. Check the email Apple sent at the upload-receipt address. | Same fix path as the entitlement-mismatch row above. |

---

## Post-upload checklist

Once the first build is **Ready to Submit**:

- [ ] **Run the SCA-217 130-item beta-QA checklist on the TestFlight build** before sending to external testers. Don't ship a build to 10 testers and discover bugs after; catch what you can on your own device first.
- [ ] **Submit for Beta App Review** if external testing is enabled.
- [ ] **Add 1–2 internal testers** (yourself + a willing collaborator) to the Internal Testing group as a sanity check; internal testing has no Apple review delay.
- [ ] **Wait for Apple Beta App Review approval** (24–48h typical).
- [ ] **Once approved**, distribute to the External group via the build's Manage Testers UI.
- [ ] **Send the SCA-215 welcome email** to each tester within an hour of distributing the build.
- [ ] **Monitor TestFlight crash reports + Sentry dashboard** the first 24h after distribution. First-day crashes catch the regressions QA missed.

---

## Provenance

- Step-9 plan Phase 7 Task 7.1 — `docs/superpowers/plans/2026-04-24-step-9-beta-launch.md`
- Release gate Phase 7 row — `docs/launch/release-gate.md`
- Pairs with: SCA-217 (run beta-qa-checklist on this build), SCA-215 (welcome email), SCA-218 (screenshots)
- Linear: SCA-213 (parent SCA-58)
