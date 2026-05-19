# Sim StoreKit config — when paywall shows "unavailable" everywhere

## Symptom

Launch Stir in the iPhone 17 Pro Max sim. Paywall opens (Settings →
"Upgrade to Pro" or any trigger). Every SKU button reads
**"unavailable — check back later"**. Settings → "Compare plans"
shows the same on its Pro CTAs; the "Or choose Premium" section
renders unavailable rows post-SCA-683.

This means RevenueCat returned an empty offering at launch, which
means StoreKit2 couldn't resolve the 4 SKU product IDs from
`stir.subscriptions`. In the sim, that happens because the local
StoreKit configuration file isn't being loaded by the scheme.

## Why we need a local StoreKit config

The 4 SKUs (`stir.pro.annual`, `stir.pro.monthly`,
`stir.premium.annual.trial7`, `stir.premium.monthly`) are
**READY_TO_SUBMIT** in App Store Connect, not Approved. RevenueCat's
prod SDK refuses to resolve non-Approved products on real devices.
The sim therefore uses `Stir.storekit` (repo root) as a local catalog
so all 4 SKUs resolve without an App Store Connect roundtrip — paired
with the `test_…` RevenueCat key in `Config.xcconfig` (see the
`REVENUECAT_PUBLIC_API_KEY` comment block).

## Where the path lives

| File | Role | Path |
| --- | --- | --- |
| `Stir.storekit` | Local catalog of 4 SKUs | repo root |
| `project.yml` | xcodegen source for the scheme | `storeKitConfiguration: Stir.storekit` |
| `Stir.xcodeproj/xcshareddata/xcschemes/Stir.xcscheme` | Generated scheme | `<StoreKitConfigurationFileReference identifier="../../Stir.storekit">` |

xcodegen rewrites `Stir.storekit` (project.yml form, relative to
repo root) into `../../Stir.storekit` (scheme form). The `../..`
convention treats the `.xcodeproj` package as opaque: from the
scheme file, `../..` resolves to the repo root.

**SCA-679 pitfall:** the original `b2bdbb3` commit set
`storeKitConfiguration: Stir/Stir.storekit` (wrong subdirectory) →
xcodegen wrote `../../Stir/Stir.storekit` → file doesn't exist at
that path → StoreKit config silently failed to load → paywall
unavailable everywhere. SCA-720 fixed the source.

## Verifying after a project regen

1. `xcodegen generate` from the repo root.
2. `grep StoreKitConfigurationFileReference Stir.xcodeproj/xcshareddata/xcschemes/Stir.xcscheme` — confirm `identifier = "../../Stir.storekit"`.
3. Run the app in sim, open the paywall, confirm all 4 SKU buttons render with prices (not "unavailable").

If step 3 still shows unavailable: check the RevenueCat key in
`Config.xcconfig` is the `test_…` variant (not `appl_…` prod) per
the comment block.

## xcodegen drift warning

The team has been hand-editing files past xcodegen's awareness
(notably `Stir/App/Info.plist` carries `$(MARKETING_VERSION)` macros,
remote-notification UIBackgroundMode, CloudKitAPIToken; entitlements
carry `aps-environment`). Running `xcodegen generate` in the current
project.yml state **WILL** strip those. Treat regen as a deliberate
action: regenerate, then `git diff` and revert any non-storekit drift
before committing. SCA-720 leaves a project.yml cleanup follow-up
open for the next person who needs to regen for a different reason.
