# ADR 0037: App chrome is system UI — Liquid Glass comes from the OS

- **Status**: Accepted
- **Date**: 2026-11-05
- **Owner-step**: standing
- **Related**: `Specs/Design-System.md` §8.6, §8.12; `Stir/App/RootView.swift` (`StirTabRoot`); `Stir/DesignSystem/Modifiers/ScrollEdgeBar.swift`; mockups 03 / 06 / 11 (chrome only — this ADR takes precedence)

## Context

Tab bars, navigation bars, toolbar buttons, alerts, confirmation dialogs and partial-height sheets render with Liquid Glass on iOS 26+ when they are the system components. Liquid Glass is applied at the toolbar-item layer, so no per-button styling turns it off; the only way to avoid it is to hide the system bar and draw a replacement. Hand-drawn replacements re-implement behavior the system already provides (scroll-edge treatment, back-swipe, search placement, Dynamic Type, accessibility traits, adaptive layouts) and drift from the platform with every OS release.

## Decision

Use the system components for all app chrome and let the OS render Liquid Glass:

- **Tab bar**: `TabView` with `.tabItem` labels (Tonight / Saved / Settings). No custom bar, no tab-bar hiding.
- **Navigation bars**: `.navigationTitle` in the system font — large on the Saved and Settings tab roots, inline on pushed screens, sheets and covers. The system back button handles back navigation.
- **Toolbar actions**: `.toolbar` placements:
  - Close (`xmark`) goes in `.cancellationAction`.
  - Done / Save / Add / Import / Submit go in `.confirmationAction`.
  - Icon actions go in `.primaryAction`.
- **Search**: `.searchable`.
- **Alerts and confirmations**: `.alert` (including `TextField` prompts) and `.confirmationDialog`.
- **Sheets**: no opaque presentation backgrounds on partial-height detents, so the system sheet material shows.
- **Custom bars that must stay** (bottom action bars): `.scrollEdgeBar(edge:)`. It uses `safeAreaBar` on iOS 26+ (the scroll edge effect provides legibility, so there is no fill or hairline) and `safeAreaInset` over the `.bar` material on iOS 17–25. Not for top-edge rows under a large title: the extended edge effect blurs the large title, so filters such as Saved's All/Favorites picker live in the content (first list row, and above the empty state).

The iOS 17.0 deployment target is unchanged. The system components above adapt per OS version without availability checks; `scrollEdgeBar` is the only availability-gated code. The brand accent reaches system controls through the asset-catalog `AccentColor` (ember).

## Alternatives considered

- **Hide system chrome and draw Stir-styled bars, buttons and dialogs** (`StirTopBar`, `StirCircleIconButton`, `StirCustomTabBar`, `StirDialog`). Rejected:
  - It needs a hand-built replacement for every system behavior.
  - It loses back-swipe and search-bar integration.
  - It hid real defects. The pushed Pantry screen had no back control, and its `.searchable` was attached to a hidden bar.
- **Serif titles inside the system bar** (a `.principal` `Text`). Rejected in favor of the standard system title. Serif display type stays in content headings.
- **Raise the deployment target to iOS 26.** Not needed. The system components already adapt, and the iOS 17 floor is a settled product decision.

## Consequences

### Positive

- Chrome tracks the platform automatically: glass, scroll-edge effects, accessibility and future OS changes.
- The custom chrome code is gone (top bar, circle icon button, tab bar, dialog overlay, serif-title modifier).
- Navigation regains standard behavior: back-swipe on onboarding and Dish Preview, and a working search drawer on Pantry.

### Negative

- Navigation-bar titles and toolbar buttons use the system font, not the Stir display serif or `label.*` tokens.
- Alerts and confirmation dialogs use system typography and layout.

### Tradeoffs

- Brand expression moves from chrome into content: serif headings, paper surfaces, ember CTAs and cards. Platform fidelity was chosen over pixel-matching the chrome in the mockups.

## Notes

What stays custom, and why:
- **Content-layer brand components**: `PrimaryButton`, `SecondaryButton`, `TextButton`, chips, and the card-based Settings lists. Liquid Glass is for the control/navigation layer, not content.
- **No system equivalent**: toasts and banners; Cook Mode's step rail, recipe strip and voice pills; the onboarding progress dots; the Tonight greeting header.
- **Camera overlay controls in Scan capture**: these were never system chrome.
