# ADR 0028: Pantry management surface lives under Settings

- **Status**: Accepted
- **Date**: 2026-05-05
- **Owner-step**: Step 4 (Saved meals + tap-based Cook Mode chrome) — pantry-view sub-screen
- **Related**: CLAUDE.md §Tier entitlements (`Remembered pantry items` cap), `SettingsRootView`, `ScanReviewView`, future `PantryListView`, ADR 0002 (generic SwiftUI through v1 beta)

## Context

Until 2026-05-05, the iOS app had no surface to view or edit the user's CloudKit pantry. Items were write-only-via-scan from `ScanReviewView`. The grocery-generate over-aggressive-matching incident on 2026-05-05 (model returned `missing=0 already=5` for a flatbread recipe against a probably-stale pantry snapshot) made it impossible for the user to verify whether the diff was correct, because they couldn't see what's in their pantry.

Two reasonable surfaces exist: a fourth tab (Pantry) alongside Tonight / Saved / Settings, or a sub-screen under Settings ("Manage pantry" row → push).

## Decision

Land the pantry view as a Settings sub-screen, not a fourth tab.

## Alternatives considered

- **Fourth tab (Pantry)** — promote pantry to top-level chrome alongside Tonight / Saved / Settings. Rejected because pantry is a low-frequency surface (users update it after scans, which happen weekly, or when spot-checking the grocery diff) and does not warrant top-level tab real estate. A fourth tab is also a load-bearing chrome change: `RootCoordinator.Tab` enum, `StirTabRoot` layout balance, tab-bar accessibility ordering, and deep-link route table all shift. Settings push is one row and one navigation target. Defer until either (a) usage telemetry shows pantry-view opens >1× per active week, or (b) multi-image scan + scan-history flows warrant a dedicated tab.
- **Embed in Tonight** — surface pantry inline on the Tonight screen. Rejected because Tonight's mockup-03 grammar is "tonight's pick + secondary tiles" — pantry doesn't fit that mental model.

## Consequences

### Positive

- One new ADR-bound entry in `docs/decisions/README.md`; no chrome churn.
- `SettingsRootView` gains a "Manage pantry" row; `PantryListView` is the destination — fits the same NavigationStack-pushed grammar as HouseholdPreferences and NotificationPrefs.
- Demotion-from-tab is harder than promotion-to-tab; starting at Settings preserves optionality. Promoting later is a 5-line `RootCoordinator` + `RootView` change.
- Users gain a way to verify the pantry snapshot before/after grocery diffs, closing the loop on the 2026-05-05 incident.

### Negative

- Discoverability is lower than a tab — users who want to "see my pantry" must learn the Settings → Manage pantry path. Mitigated by adding a future entry-point from Scan and (potentially) from grocery-generate empty-state copy.
- New `PaywallTrigger.pantryCapReached` and a tier→cap mapping helper on `EntitlementService` — small surface-area additions to the entitlement layer.

### Tradeoffs

- Trading peak discoverability for chrome stability and reversible commitment. Worth it because pantry-view usage is unproven and a tab is sticky once shipped.

## Notes

Future telemetry: `pantry_viewed`, `pantry_item_added`, `pantry_item_edited`, `pantry_item_deleted`. These land with the telemetry wiring task — spec §15 + CLAUDE.md §Telemetry events update accompanies that PR, NOT this ADR.
