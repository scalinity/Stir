# ADR 0016: Design tokens live in `/Shared/` for App Group access across main + widget + share extension

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 9 (beta prep — design system foundation)
- **Related**: `Specs/Design-System.md §12` (file layout), `stir-app-design/project/DesignMockups/EXTRACTED_TOKENS.md §9`, ADR 0002 (design system deferred), commit `66e9629` (step-7 Dynamic Type migration that first introduced tokens)

## Context

Stir ships four SwiftUI-facing build targets: `Stir` (main app), `StirShareExtension`, `StirWidgets`, and `StirTests`. All four consume the same visual tokens — colors, typography, spacing, radius, iconography. When the token layer was first built (step-7 Dynamic Type migration prereq, commit `66e9629`), the files landed in `/Shared/` instead of the spec-prescribed `Stir/DesignSystem/Tokens/`. `Specs/Design-System.md §12` was never updated; reality and spec have disagreed silently for ~5 days. A step-9 design pass is about to add two more token files (Shadow, Motion) and future readers need to know where tokens actually live.

## Decision

**Design tokens live in `/Shared/`.** Any token file that needs to be compiled into more than the main app target ships there. XcodeGen's `project.yml` already lists `Shared` under each target's `sources:`, so new files drop in and propagate automatically with `xcodegen generate`. `Specs/Design-System.md §12` is updated in the same commit as this ADR to point at the actual location.

**Components stay main-app-only.** `Stir/DesignSystem/Components/` holds reusable SwiftUI components (PrimaryButton, DishOptionCard, StepCard, etc.) that consume shared tokens but do not themselves cross target boundaries. Widgets needing a visually-matching button or card write their own WidgetKit-compatible implementation on top of the same tokens — WidgetKit's SwiftUI subset differs enough that sharing a component across main + widget targets is a worse choice than duplicating the (small) visual wrapper code.

## Alternatives considered

- **Duplicate token files across targets** — rejected. Three (or four) copies of `Colors.swift` is three (or four) places to drift; every palette tweak becomes multi-file surgery with no compile-time guarantee the copies agree.
- **Static library / SwiftPM package for tokens** — rejected at v1 scope. Adds toolchain surface (package manifests, version pinning, separate build graph) that doesn't pay off until the token layer is externally versioned. `/Shared/` with XcodeGen multi-target membership is the simpler equivalent.
- **Widget duplicates a subset; main app owns canonical** — rejected. The duplication problem shrinks but doesn't go away, and widget-specific rendering must still visually match. Shared tokens + per-target components wins.
- **Keep the spec-prescribed location, break the extension targets** — rejected. Targets already work; breaking them to satisfy docs is backwards. Code decides, spec follows.

## Consequences

### Positive

- One canonical source for tokens across all four targets; no silent divergence possible.
- Palette / typography changes flow to widgets and share extension automatically.
- New tokens (Shadow, Motion in step 9; anything else later) have an obvious home.
- `xcodegen generate` is the whole new-file workflow — no manual `.pbxproj` edits.

### Negative

- `/Shared/` mixes tokens with App Group–shared models (`AppGroup.swift`, `PendingImport.swift`, `SharedStorage.swift`, `SharedTier.swift`, `TimerActivityAttributes.swift`, `TonightSnapshot.swift`). Not a problem at ~12 files; if it grows past 20, subdivide into `/Shared/Tokens/` + `/Shared/Models/` + `/Shared/Storage/`.
- WidgetKit's SwiftUI subset is narrower than the main app's. Token consumers in widget code must stay inside WidgetKit-compatible surface area — e.g., `Motion.swift` animations that rely on full view-identity tracking may behave differently in widget vs. main-app contexts. Widget-incompatible usages are inline-commented in the token file rather than gated at the compiler level.

### Tradeoffs

- Loss of the spec-prescribed location for the pragmatic gain of native multi-target consumption. When docs and code disagree, code wins and docs catch up — especially on mechanical layout questions like where files live.

## Trigger to revisit (Deferred only)

N/A — Accepted. Revisit only if:

1. A fifth target is added (e.g., watchOS companion) and the `/Shared/` pattern stops scaling cleanly.
2. `/Shared/` grows past 20 files and needs internal subdivision (at which point this ADR should amend with the new subfolder structure, not be replaced).
3. Token layer becomes externally versioned (shared across multiple apps) — SwiftPM starts to pay off.

## Notes

- The move from "`Stir/DesignSystem/Tokens/`" → "`/Shared/`" happened silently during step-7 Dynamic Type migration (commit `66e9629`, 2026-04-23). That commit's message acknowledges the work as a prereq for the UI redesign but didn't flag the location deviation. This ADR closes the loop retrospectively and brings Spec §12 back into sync with reality.
- Target membership is handled by XcodeGen's `sources:` blocks, not manual `.pbxproj` edits. The workflow for adding a token: write the `.swift` file to `/Shared/`, run `xcodegen generate`, commit both the new file and the regenerated `project.pbxproj`.
- `Stir/DesignSystem/` (no subfolder) continues to hold `StirPrimaryButton.swift` at ADR time; the step-9 component pass will create `Stir/DesignSystem/Components/` and move `StirPrimaryButton.swift → Components/PrimaryButton.swift` as part of Phase 2 (see step-9 task brief Q3).
