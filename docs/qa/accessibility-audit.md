# Accessibility Audit — Step 9

Date: 2026-04-24
Scope: All 46 SwiftUI feature files + 16 DesignSystem components + app-root views.
Method: Code-level grep audit (Claude, phase 2 of step 9) + manual VoiceOver/Dynamic Type/Voice Control pass (Daniel, TestFlight build on device).

Sign-off convention: each row is PASS, FIX SHIPPED, or DEBT (accepted).

---

## Executive summary

The codebase was already substantially a11y-conscious before step 9: `accessibilityLabel` / `accessibilityHidden` / `accessibilityAddTraits` / `accessibilityValue` used deliberately; `accessibilityReduceMotion` environment read across all animated views I checked; 44×44 hit targets enforced in most Button wrappers with `.frame(minWidth:minHeight:) + .contentShape(Rectangle())`. The code-level audit found 5 specific issues that are now fixed (see below). The manual-device VoiceOver pass remains Daniel-owned and is tracked in `docs/qa/beta-qa-checklist.md`.

---

## Fixed in this pass (phase 2)

All shipped in commit: a11y — phase 2 targeted fixes.

| # | File + line | Issue | Fix |
|---|---|---|---|
| 1 | `Stir/Features/Saved/SavedMealsView.swift:191` | Search-bar magnifyingglass `Image(systemName: "magnifyingglass")` was VoiceOver-focusable with default "magnifying glass" label — distracts VoiceOver user from the adjacent TextField. | `.accessibilityHidden(true)` on the decorative icon. |
| 2 | `Stir/Features/Saved/SavedMealsView.swift:199` | Clear-search Button icon-only; no `accessibilityLabel`. VoiceOver would read "X mark circle fill". Tap target was inner icon only (~22pt). | Added `.frame(minWidth: 44, minHeight: 44) + .contentShape(Rectangle())` and `.accessibilityLabel("Clear search")`. |
| 3 | `Stir/Features/Grocery/GroceryListView.swift:341` | Dismiss button (X on grocery card) lacked `accessibilityLabel` and sub-44 hit area. | Added 44×44 minFrame + `.accessibilityLabel("Dismiss")`. |
| 4 | `Stir/Features/Leftovers/LeftoversPromptView.swift:294` | Plus-to-add-leftover Button had 36×36 tap target and no label. | Added 44×44 minFrame + `.accessibilityLabel("Add leftover item")`. |
| 5 | `Stir/Features/Billing/PaywallView.swift:71` | `handleSuccess()` called `withAnimation(.spring(duration: 0.4))` without respecting `accessibilityReduceMotion`. | Added `@Environment(\.accessibilityReduceMotion) private var reduceMotion` and gated `withAnimation(reduceMotion ? nil : .spring(duration: 0.4))`. |

---

## Already compliant (code-level confirmed)

Documented here so future-Claude doesn't re-investigate these.

### VoiceOver labels on icon-only buttons

- `Stir/App/LoadingView.swift` — Spinner has `.accessibilityElement()` + `.accessibilityLabel("Loading")` + `.accessibilityAddTraits(.updatesFrequently)` + `reduceMotion` guard.
- `Stir/DesignSystem/Components/StarRatingRow.swift` — HStack has `.accessibilityElement(children: .ignore)` + `.accessibilityLabel("Rated \(rating) out of 5")`; each decorative star is `.accessibilityHidden(true)`.
- `Stir/Features/Grocery/GroceryListView.swift:192` — Checkbox Button has full quartet: `.accessibilityLabel + .accessibilityValue + .accessibilityAddTraits + .accessibilityHint` + 44×44 minFrame.
- `Stir/Features/Leftovers/LeftoversPromptView.swift:191` — Same quartet pattern on the leftover-selection checkbox.
- `Stir/Features/Saved/SavedMealsView.swift:184` — Sort menu Button: `.accessibilityLabel("Sort — \(sortOption.rawValue)")`.
- `Stir/Features/Saved/SavedMealsView.swift:253` — Favorite toggle Button: `.accessibilityLabel(isFavorite ? "Remove from favorites" : "Save to favorites")`.
- `Stir/Features/Solve/DishPreviewView.swift:56, 64` — Grocery + favorite buttons: `.accessibilityLabel("Add to grocery")`, `.accessibilityLabel(...favorites...)`.
- `Stir/Features/Import/ImportEntryView.swift:98` — Clear-URL button: `.accessibilityLabel("Clear URL") + .accessibilityHint`.
- `Stir/Features/CookMode/CookModeRoot.swift:524` — Dismiss (X) button: `.accessibilityLabel("Dismiss")`.
- `Stir/Features/CookMode/OutcomeFeedbackView.swift:85` — Each star in the 1-5 rating has individual `.accessibilityLabel("\(index) star[s]") + .accessibilityAddTraits + .accessibilityHint`.
- `Stir/Features/CookMode/StepCardView.swift:295, 355` — Ask row + voice row: Icon is `.accessibilityHidden(true)` and the Text label is visible (SwiftUI uses text as a11y label automatically).
- `Stir/Features/Settings/SettingsRootView.swift:142, 165, 189, 210, 227` — All Buttons use `Label { Text(...) } icon: { Image(...) }`, so SwiftUI derives the a11y label from the visible text automatically.

### Reduce Motion

- `LoadingView.swift:114` — gated
- `OnboardingCompletionView.swift:197` — gated
- `PaywallView.swift:71` — NOW gated (fixed above)

### Tap targets ≥ 44×44

All interactive icon buttons audited either have the visual tap area at ≥44 natively, or wrap with `.frame(minWidth: 44, minHeight: 44) + .contentShape(Rectangle())`. The specific fixes above close the last 3 gaps I found.

Non-interactive visual elements at sub-44 sizes (step-number circles at 22×22 in `ImportReviewView.swift:150`, the rotation-spinner in `OnboardingCompletionView.swift:194` at 16×16) are decorative and do NOT need tap-target expansion.

---

## Accepted debt (design-system justified; not shipping as fixes)

These have inline `// justification:` comments explaining deliberate design choices. The trade-off: some may render tightly at Dynamic Type AX5. Daniel's device QA pass verifies rendering; if problems emerge, follow-up PR.

- `Stir/DesignSystem/Components/StarRatingRow.swift:53` — `.font(.system(size: 11))` on decorative stars. Justification: "11pt micro cluster for tight list rows." Stars are `.accessibilityHidden(true)`; VoiceOver reads the parent's "Rated X out of 5" label, so Dynamic Type invisibility of stars is cosmetic, not functional.
- `Stir/DesignSystem/Components/SavedMealCard.swift:145` — `.font(.system(size: 11))` on same star cluster (SavedMealCard variant).
- `Stir/DesignSystem/Components/Chip.swift:86` — 12pt semibold chip caption. Dense info tile; will not scale with AX5.
- `Stir/DesignSystem/Components/SelectableChip.swift:65` — 12pt semibold; same as Chip, matches mockup 02 inline-check size.
- `Stir/Features/Settings/NotificationPrefsView.swift:118, 154` — 13pt semibold "bell" glyphs with inline text.
- `Stir/Features/Tonight/TonightHomeView.swift:361` — 18pt serif "Aa" glyph for the type-in tile. One-off typographic element; parent row is the tap target and reads as a full sentence via VoiceOver.
- `Stir/App/ConfigurationErrorView.swift:27` — one-off hero error glyph per §4.1.

All other `.font(.system(size:))` uses are iconography paired with a dynamic-type text label, or use the `CGFloat.Stir.iconSm/Md/Xl` tokens which are the design-system icon-size constants (icons don't scale with Dynamic Type by design convention — Apple's own apps follow this).

---

## Manual VoiceOver pass (Daniel-owned — goes into `beta-qa-checklist.md`)

The code-level audit cannot verify:

1. **VoiceOver reading order** — does it move through screens in the natural visual order, or skip around?
2. **Custom composite views** — are container views grouping their children's a11y info correctly (via `.accessibilityElement(children: .combine)`) or do they leak incoherent fragments?
3. **Cook Mode voice-variant interactions** — VoiceOver + Gemini Live audio output sharing the audio channel. Known tricky; requires device test.
4. **Dynamic Type at AX1 through AX5** — clipping, truncation, overlap, button height constraints failing.
5. **Voice Control addressability** — can users invoke every button by spoken command (e.g., "Tap Scan")? Requires Voice Control enabled + "Show names" command.
6. **Reduce Motion outside the 3 checked sites** — some UIs may animate through implicit SwiftUI transitions (sheet presentation, etc.). Daniel's pass validates.
7. **Color contrast in dark mode** — especially orange/ember on warm backgrounds, placeholder text, disabled-state ink300.

Each of these gets a checklist row in `docs/qa/beta-qa-checklist.md` under the "Accessibility" section, for Daniel to run on the TestFlight build.

---

## Sign-off

VoiceOver + Dynamic Type + Voice Control code-level sweep complete, 2026-04-24.
Manual device pass: pending (Daniel, once TestFlight build is up).
