# Stir — Design System v1

**Status:** draft, v1.1. This document is the design single source of truth. Any SwiftUI view in `Stir/Features/*` consumes tokens from `Stir/DesignSystem/*.swift`; any mockup or component spec references this file.

**Authored:** 2026-04-19
**Revised:** 2026-04-19 — tokens updated against mockups in `stir-app-design/project/DesignMockups/`. See `stir-app-design/project/DesignMockups/EXTRACTED_TOKENS.md` for the audit trail of what changed and why. Principles (§1, §2, §7, §11, §13) unchanged; tokens (§3–§6, §12) reconciled with the mockup source of truth.
**Owner:** Daniel
**Scope:** iPhone v1. iPad, macOS, web explicitly out.

---

## 1. Design principles

Stir is a weeknight **decision-and-execution** product. The design system optimizes for one job: a tired home cook, in a kitchen with wet hands and dim lighting, getting dinner decided in 2 minutes and guided for 30. Every visual choice traces back to that job.

Five principles, in priority order when they conflict:

1. **Legibility under distraction.** Oily fingers, steam, bad light, phone propped against a jar. Text readable at arm's length, tap targets generous, contrast high. Dynamic Type through XXXL must never crop the primary CTA.
2. **One decision per screen.** Dinner Options asks "which one?" — not "which one, and have you thought about portions, and here's an upsell." Pile-ups kill decisions. Secondary actions go in overflow; primary actions are impossible to miss.
3. **Confident but not slick.** This isn't a restaurant app. No glassy gradients, no parallax hero photos of truffle shavings. The aesthetic is competent, calm, and slightly warm — the feeling of a trusted friend at your kitchen counter, not a Michelin-starred Instagram reel.
4. **AI is infrastructure, not spectacle.** No sparkle emojis, no "✨ AI-powered" badges, no confetti on scan parse. When the model does something well, the result is what's celebrated, not the process. Voice mode is the one exception — it gets a subtle, intentional visual presence because it's the paid differentiator.
5. **Accessibility is a first-class constraint, not a polish pass.** WCAG 2.2 AA baseline is non-negotiable. VoiceOver, Dynamic Type, Reduce Motion, color-independent semantics all designed in from the start.

**The forbidden moves:**
- No photo-heavy recipe cards. Stir isn't a food magazine. Recipes are structured data; photos are nice-to-have, never the hero.
- No chrome-heavy tab bars with 5 destinations. v1 is three: Tonight, Saved, Settings.
- No modal stack deeper than 2. If a flow requires "paywall → upgrade detail → confirm → receipt," rethink the flow.
- No animations longer than 300ms. Loading skeletons tick at 1.2s cycles. No elastic bounces, no hero transitions between tabs.
- No emoji in product copy. One-off exceptions for feedback sheet ratings only (1★–5★ visual).
- No placeholder avatars. Stir has no social layer; there are no other users to represent.

---

## 2. Brand identity

**Name:** Stir
**Tagline:** "Cook what you already have."
**Tone:** warm, competent, concise. Think *sous-chef at your elbow* — not *concierge*, not *coach*, not *chatbot*.

**Voice examples:**
- ✅ "Here are three dinners from what you've got."
- ✅ "I'm not confident about a few ingredients. Confirm them to keep going."
- ✅ "Out of olive oil? Butter works here — same amount."
- ❌ "Let's cook something amazing tonight! ✨"
- ❌ "Oops! Something went wrong 😅"
- ❌ "Hey chef, ready to get cooking?"

Copy uses contractions. Sentences lean short. Error messages always offer a next action.

**Logomark:** wordmark-only for v1. "Stir" set in the display face (see Typography §4). No icon-plus-wordmark lockup yet; that comes with App Store screenshots in step 9.

---

## 3. Color

Color is semantic, not decorative. Every value has a named role.

### 3.1 Palette (light mode)

| Token | Hex | Role |
|---|---|---|
| `ink.900` | `#1A1612` | Primary text; high-stakes UI |
| `ink.700` | `#3D342C` | Secondary text |
| `ink.500` | `#6B5F54` | Tertiary text, captions |
| `ink.300` | `#A89E93` | Disabled text, placeholder |
| `ink.100` | `#E8E3DD` | Subtle dividers, rule lines |
| `paper.50` | `#FAF7F2` | Primary background (warm off-white, not sterile) |
| `paper.100` | `#F3EEE5` | Secondary background, card surface |
| `paper.200` | `#EBE3D6` | Tertiary background, grouped list |
| `ember.600` | `#C8532B` | **Primary action** — CTAs, active states, selection highlight |
| `ember.500` | `#E26340` | Ember hover/pressed |
| `ember.100` | `#FBEAE0` | Ember tint (selected chip, subtle highlight) |
| `ember.700` | `#8F3B1D` | Deep ember — gradient pair with `ember.600` on premium/Pro cards only. Never used as a flat fill. |
| `sage.600` | `#4A7C59` | **Success / positive** — confirmed ingredients, completed timers, meal ratings |
| `sage.100` | `#E4EEE6` | Sage tint |
| `amber.600` | `#B8860B` | **Warning / needs attention** — low-confidence parse chips, pending review |
| `amber.100` | `#F5ECD5` | Amber tint |
| `crimson.600` | `#9A2E2E` | **Critical / error / allergen** — dietary rule violations, hard-rule blocks |
| `crimson.100` | `#F2DCDC` | Crimson tint |
| `rust.600` | `#A8441F` | **Soft recoverable AI/parse error** — OCR couldn't read a page, low-confidence import. Distinct from `crimson.600` (hard dietary/allergen breach) and `amber.600` (pending review). Scope tightly: `IMPORT-01`, low-confidence scan output. |
| `voice.600` | `#5E4AE0` | **Voice mode accent only** — mic states, Live Activity indicators. Never used elsewhere. |
| `voice.100` | `#E8E3FA` | Voice tint |

### 3.2 Palette (dark mode)

Dark mode is first-class for v1 — people cook at night with the phone backlit. No token is optional.

| Token | Hex | Role |
|---|---|---|
| `ink.900` | `#F5F0E8` | Inverts to warm off-white |
| `ink.700` | `#D6CEC3` | Secondary text |
| `ink.500` | `#9A8F84` | Tertiary |
| `ink.300` | `#5E5349` | Disabled |
| `ink.100` | `#2E2822` | Dividers |
| `paper.50` | `#14100B` | Primary background (warm near-black, not pure #000) |
| `paper.100` | `#1F1A14` | Card surface |
| `paper.200` | `#2A241C` | Grouped list |
| `ember.600` | `#E26340` | Slightly brighter for contrast on dark bg |
| `ember.500` | `#F07D5A` | — |
| `ember.100` | `#3A1E13` | Ember tint dark |
| `ember.700` | `#C8532B` | Deep ember (equivalent of light `ember.600`) — gradient-pair only |
| `sage.600` | `#6FA07C` | Brighter for dark |
| `sage.100` | `#1E2E23` | — |
| `amber.600` | `#D4A21F` | — |
| `amber.100` | `#2E2614` | — |
| `crimson.600` | `#C94747` | — |
| `crimson.100` | `#2E1818` | — |
| `rust.600` | `#E26340` | Folds to the dark `ember.600` value on dark mode — the soft-error distinction collapses into the warmer ember hue on dark |
| `voice.600` | `#8473E8` | — |
| `voice.100` | `#1F1A33` | — |

### 3.3 Color rules

- **Never communicate semantics with color alone.** Confidence chips pair color with icon (checkmark/question/sparkle). Error banners pair crimson with an exclamation. Per WCAG 2.2 AA and spec §6 accessibility baseline.
- **Ember is the only hue used for primary CTAs — one brand signal.** Paywall is the deliberate exception: its "soft bottom sheet" and "inline" surfaces use `ink.900` CTAs to signal editorial consideration rather than bright-intent action (see §8.1 paywall override). Feature-specific paywall modals (e.g., voice upsell) revert to `ember.600`.
- **`ember.700` is gradient-stop-only.** Never a flat button fill. Always paired with `ember.600` as `LinearGradient(ember.600 → ember.700, topLeading → bottomTrailing)` on premium/Pro emphasis cards.
- **`rust.600` and `crimson.600` are semantically distinct.** Crimson = hard rule violation (allergen, dietary breach) — red-stop-red. Rust = soft recoverable failure (OCR couldn't read, low-confidence parse) — warmer, retry-affordance-implying. Do not mix.
- **Voice purple is quarantined.** Only appears in Cook Mode voice UI, Live Activity for voice sessions, and the voice affordance mic button. Don't use it as a secondary accent.
- **Contrast minimums:** text on background ≥4.5:1 for body, ≥3:1 for large text (≥17pt bold, ≥22pt regular). Verify with WebAIM contrast checker for every token pair in use.
- **No transparency on text.** Opacity tricks break over photos. If you need a lighter text treatment, use the next step down on the ink scale.

---

## 4. Typography

**Face:** iOS system font (SF Pro) for all body copy. Display face is **New York** (Apple's modern serif), used only for screen titles and the logomark — it carries the "warm, competent, slightly editorial" character without being precious.

Rationale: SF Pro for body because it's optimized for small sizes and scales cleanly through Dynamic Type. New York for display because a sans-only interface feels techy and cold; one restrained serif gives Stir its calm, sous-chef warmth without a third-party webfont.

### 4.1 Scale

All sizes reference Dynamic Type; hard-coded point sizes are the `.default` token — Dynamic Type scales up from there. Tracking is baked into every token; do not override per-use.

| Token | Face | Size | Line height | Weight | Tracking | Use |
|---|---|---|---|---|---|---|
| `display.xl` | New York | 34pt | 40 | Semibold | `-0.02em` | Welcome, Paywall hero |
| `display.lg` | New York | 28pt | 34 | Semibold | `-0.02em` | Screen titles (Tonight, Saved, Settings) |
| `display.md` | New York | 22pt | 28 | Semibold | `-0.015em` | Section headers, dish titles |
| `display.sm` | New York | 18pt | 24 | Semibold | `-0.01em` | In-card subheadings, pricing labels |
| `body.lg` | SF Pro | 17pt | 24 | Regular | `0` | Cook Mode step instruction — the one place body text goes large |
| `body.md` | SF Pro | 15pt | 22 | Regular | `0` | Default body |
| `body.sm` | SF Pro | 13pt | 18 | Regular | `0` | Captions, metadata |
| `label.lg` | SF Pro | 15pt | 20 | Medium | `0` | Button labels, chip text |
| `label.md` | SF Pro | 13pt | 18 | Medium | `0` | Small button labels, tab bar |
| `label.eyebrow` | SF Pro | 11pt | 14 | Bold | `+0.14em` (tracking ≈ 1.54pt) | UPPERCASE section eyebrows ("PRO FEATURE", "YOU'VE USED TODAY'S 3") |
| `label.microEyebrow` | SF Pro | 10pt | 13 | Bold | `+0.12em` | UPPERCASE tier labels ("MONTHLY", "ANNUAL") |
| `mono.md` | SF Mono | 15pt | 22 | Regular | `0`, tabular | Timer countdown, measurements in recipe |
| `mono.lg` | SF Mono | 44pt | 48 | Medium | `0`, tabular | Cook Mode active timer (hero number) |
| `mono.quote` | SF Mono | 13pt | 18 | Medium | `0` | Voice-command quotes ("say *next*", "say *how much butter?*") |

### 4.2 Typography rules

- **Every title uses New York Semibold.** Consistency over variation.
- **Body never bolds for emphasis.** Use weight differently: Medium for interactive (buttons, chips), Regular for prose, Bold reserved for uppercase eyebrow labels and alerts only.
- **Uppercase eyebrow labels always come with tracking.** `+0.14em` on `label.eyebrow`, `+0.12em` on `label.microEyebrow`. Never an uppercase label with zero tracking — it reads as shouted, not sectioned.
- **Display tracking is tight, not default.** New York at display sizes (22pt+) needs `-0.015em` to `-0.02em` or it reads mushy. Always use the tokenized tracking, never override.
- **Monospace for numbers that update.** Timers, servings counters, quantity scalars. Tabular figures prevent jitter on digit change. `mono.quote` is the exception — used for framing spoken hotwords as distinct tokens in body copy.
- **Line height is generous.** 1.4× body minimum. Cooking happens at arm's length; tight leading kills scannability.
- **Never shrink text to fit.** If content overflows, truncate with ellipsis or wrap. Shrinking is a design failure.
- **One-off hero numerals are NOT tokenized.** Welcome and Launch use bespoke sizes (88–100pt) per mockup 01 — those are per-screen choices justified inline in the SwiftUI view, not system-wide tokens.

---

## 5. Spacing & layout

### 5.1 Grid

- **Base unit:** 4pt.
- **Margins:** 16pt horizontal on most screens; 20pt on hero screens (Welcome, Paywall) for more breathing room.
- **Inter-component spacing:** multiples of 4. The most-used values: `8` (tight), `12` (default), `16` (section), `24` (block), `32` (hero), `48` (page section break).

### 5.2 Tokens

| Token | Value | Use |
|---|---|---|
| `space.1` | 4pt | Icon-to-label inside a button |
| `space.2` | 8pt | Chip internal padding |
| `space.3` | 12pt | Default between inline elements |
| `space.4` | 16pt | Screen horizontal margin |
| `space.5` | 24pt | Block separation |
| `space.6` | 32pt | Major section break |
| `space.7` | 48pt | Page-level section |

### 5.3 Container widths

iPhone-only for v1. No container max-width; use full screen width minus margins. Safe area inset always respected.

### 5.4 Corner radius

| Token | Value | Use |
|---|---|---|
| `radius.sm` | 8pt | Chips, small tags |
| `radius.md` | 12pt | Buttons, input fields, pricing tiles |
| `radius.card` | 14pt | **Default card surface** — Tonight inline cards, Solve option containers, Saved rows, Settings groups. Dominant card radius across the app. |
| `radius.lg` | 16pt | Hero cards only — `DishOptionCard`, `SavedMealCard` primary variant, Pro badge gradient card |
| `radius.accent` | 18pt | Elevated accent cards — inline paywall card, emphasized inline blocks with decorative corner glow |
| `radius.xl` | 22pt | Modals (centered paywall, substitution result) |
| `radius.sheet` | 24pt | Bottom-sheet top corners (iOS default — `.medium` detent sheets) |
| `radius.full` | 999pt | Mic button, pill controls, avatar chips |

Stir's corner radius language is **medium-soft**. Not rounded enough to feel playful, not sharp enough to feel clinical. Cards use 14pt by default, 16pt when they're the hero of the screen. Buttons are always 12pt. Modals are 22pt; bottom-sheet tops are 24pt (iOS default).

**Why three card radii instead of one?** The default `radius.card = 14` feels tighter and more everyday; `radius.lg = 16` is reserved for cards that anchor a screen and need a bit more presence; `radius.accent = 18` layers on a "this one is different" signal for promotional or status-elevated surfaces. The 2pt increments are small enough to feel like one family, not noise.

### 5.5 Elevation

No drop shadows in light mode — shadows fight with the warm paper palette and read as grimy. Elevation is communicated via:
- **1pt hairline border** in `ink.100` (light) or `ink.300` (dark) for cards on default background
- **Fill step-up** for modals (sheet uses `paper.100` while screen is `paper.50`)

Dark mode exception: one subtle shadow on Cook Mode step card to separate it from the background when the user is glancing at it from across the counter — `shadow(color: .black.opacity(0.35), radius: 12, y: 4)`.

---

## 6. Iconography

**Source:** SF Symbols exclusively. No custom icon set for v1.

**Style:** Regular weight by default, Semibold on pressed/active states. Never use Light or Thin — they vanish on dark mode at small sizes.

**Size tokens:**
| Token | Size | Use |
|---|---|---|
| `icon.sm` | 16pt | Inline with body text |
| `icon.md` | 20pt | Buttons, tab bar |
| `icon.lg` | 28pt | Primary action icons |
| `icon.xl` | 44pt | Hero icons on empty states, mic button |

**Semantic icon mapping** (the single source of truth — agents don't invent icons). This table is the full v1 vocabulary; additions require updating this table and the mirror `Icons.swift`.

| Concept | SF Symbol | Semantic key |
|---|---|---|
| Scan (camera) | `camera.viewfinder` | `.scan` |
| Scan — hand-held photo | `camera` | `.camera` |
| Import | `square.and.arrow.down` | `.import` |
| Saved meals | `bookmark` / `bookmark.fill` | `.bookmark` / `.bookmarkFill` |
| Favorite | `heart` / `heart.fill` | `.heart` / `.heartFill` |
| Cook | `fork.knife` | `.cook` (alias `.fork`) |
| Voice mic (idle) | `mic` | `.micIdle` |
| Voice mic (active) | `mic.fill` with `voice.600` glow ring | `.micActive` |
| Voice mic (disabled) | `mic.slash` | `.micDisabled` |
| Voice feature mark (abstract, non-mic) | `waveform` | `.voiceWave` |
| Timer | `timer` | `.timer` |
| Total cook time (inline) | `clock` | `.clock` |
| Substitution | `arrow.triangle.2.circlepath` | `.substitute` (alias `.swap`) |
| Refresh | `arrow.clockwise` | `.refresh` |
| Settings | `gearshape` | `.settings` (alias `.gear`) |
| Edit | `pencil` | `.edit` |
| Delete | `trash` | `.delete` |
| Share | `square.and.arrow.up` | `.share` |
| Grocery | `cart` | `.grocery` (alias `.cart`) |
| Reminders | `checklist` | `.reminders` |
| Widget (outline) | `square.grid.2x2` | `.widget` |
| Widget (filled) — paywall feature badges | `square.grid.2x2.fill` | `.widgetFill` |
| Premium upsell | `sparkles` (ONLY in paywall + tier badges) | `.premium` (alias `.sparkles`) |
| Pro upsell | `star.fill` | `.pro` (alias `.star`) |
| Allergen/dietary hard-rule violation | `exclamationmark.triangle.fill` in `crimson.600` | `.allergen` |
| Soft recoverable error (OCR, parse) | `exclamationmark.triangle` in `rust.600` | `.softError` |
| Pending review / low confidence | `questionmark.circle` in `amber.600` | `.lowConfidence` |
| Success / confirmed | `checkmark.circle.fill` in `sage.600` | `.success` |
| Dismiss / close | `xmark` | `.close` |
| Back navigation | `chevron.backward` | `.back` |
| Forward disclosure | `chevron.forward` | `.disclosure` |
| Info | `info.circle` | `.info` |
| Help | `questionmark.circle` | `.help` |
| Lock / gated | `lock.fill` | `.locked` |
| Home / tonight tab | `house` | `.home` |
| Search | `magnifyingglass` | `.search` |
| Filter | `line.3.horizontal.decrease` | `.filter` |
| Sync — available | `icloud` | `.syncOk` |
| Sync — unavailable (`SYNC-01`) | `icloud.slash` | `.syncOff` |
| Network ok | `wifi` | `.networkOk` |
| Network unreachable (`NET-01`) | `wifi.slash` | `.networkOff` |
| Pantry | `basket` | `.pantry` |
| Cookbook / recipe source | `book.closed` | `.cookbook` |
| Spiciness / heat | `flame` | `.heat` |
| Quick action | `bolt.fill` | `.quick` |
| Leftovers mode | `leaf.fill` | `.leaf` |
| Photo picker | `photo` | `.photo` |
| Link (external) | `link` | `.link` |
| Play / resume | `play.fill` | `.play` |
| Pause | `pause.fill` | `.pause` |
| Plus / add | `plus` | `.plus` |
| Minus / remove | `minus` | `.minus` |
| Notifications | `bell` | `.notifications` |
| Privacy / shield | `shield.fill` | `.privacy` |
| Profile / user | `person.crop.circle` | `.profile` |

**Not in v1 — deferred to v2 custom icon set:**

- **Logomark `stir` whisk icon** — no SF Symbol maps cleanly to "stir/whisk". Per §2 principle ("Logomark: wordmark-only for v1"), the brand renders as typeset "Stir" using `display.xl` New York Semibold. The whisk icon ships with the v2 custom icon set (§13).

---

## 7. Motion

### 7.1 Principles

- **Default duration: 200ms.** Most state changes.
- **Max duration: 300ms.** Sheet presentations.
- **Longer is not richer; it's slower.** Stir respects the user's time.
- **Reduce Motion is honored.** All motion degrades to instant or cross-fade when the user has Reduce Motion enabled.

### 7.2 Easing

Default easing: SwiftUI `.easeOut(duration: 0.2)`. Enter-stage transitions feel responsive; exits are slightly faster (`.easeIn(duration: 0.15)`) so dismissal doesn't feel sticky.

No spring animations on functional UI. Springs are reserved for the voice mic activation glow — the one place a tiny bit of delight is earned.

### 7.3 Specific motions

- **Skeleton loading:** 1.2s shimmer cycle, `paper.100` → `paper.200` gradient sweep. Used while scan parse, dinner solve, or recipe import run.
- **Dish card stream-in (Dinner Options):** cards arrive individually over 150ms each as SSE events land. Fade + slide-up 8pt.
- **Voice mic activation:** concentric pulse ring in `voice.100`, 400ms spring from 0.9 → 1.0 scale. Runs on first mic tap only.
- **Timer completion:** brief 120ms scale-up on the countdown `1.0 → 1.08 → 1.0`, combined with a haptic (respecting per-device setting). Not a bounce.
- **Paywall success:** checkmark draws in over 400ms (this one exception to the 300ms ceiling — success deserves a beat), then paywall dismisses.

---

## 8. Components

The atomic component catalog. Every component here has a named SwiftUI view in `Stir/DesignSystem/Components/`.

### 8.1 Buttons

Three variants. That's it.

| Variant | Use | Visual |
|---|---|---|
| `PrimaryButton` | The single most important action on a screen | `ember.600` fill, `paper.50` label, 12pt radius, 48pt min height, full-width default |
| `SecondaryButton` | Important but not hero | `paper.100` fill, `ink.900` label, 1pt `ink.100` border, same size |
| `TextButton` | Tertiary actions, links | `ember.600` label, no fill, no border |

**Never stack two primaries.** If a screen has two critical actions, one is secondary. If the decision is truly 50/50 (Dinner Options card selection), use card-as-button pattern instead.

**Disabled state:** 40% opacity on the whole button. Never swap to a different gray — consistent disabled pattern across variants.

**Pressed state:** 92% scale for 80ms, combined with a subtle darken (ember goes to `ember.500` on primary). SwiftUI's default button pressed behavior is close — override only if insufficient.

### 8.2 Chips

Used extensively on Scan Review (ingredient chips) and Setup (preference chips).

| State | Visual |
|---|---|
| Default | `paper.100` fill, `ink.700` label, 1pt `ink.100` border, 8pt radius, 12×8 padding |
| Selected | `ember.100` fill, `ember.600` label, 1pt `ember.600` border |
| Confidence: confirmed | default + `sage.600` checkmark icon |
| Confidence: needs review | `amber.100` fill, `amber.600` label, amber question-mark icon |
| Confidence: likely staple | default + tertiary `ink.500` text, no icon |
| Allergen warning | `crimson.100` fill, `crimson.600` label, allergen triangle icon |

Minimum tap target is 44×44pt even for small chips — add transparent padding if visual size is smaller.

### 8.3 Cards

| Variant | Use |
|---|---|
| `DishOptionCard` | Dinner Options — the aha moment |
| `SavedMealCard` | Saved library, Tonight Home recent |
| `InfoCard` | Generic content container |

**Dish Option Card** is the hero component of the app. It displays: rank (1/2/3), title, total time, why-it-fits reason, missing ingredient count, fit label (badge). Card is 100% tappable (not just a button inside). Active state on tap-down: 98% scale + ember border ring. Default corner radius 16pt, ink.100 border, paper.50 fill (slightly brighter than the paper.50 screen bg — wait, resolve: card uses `paper.100` on screen `paper.50` for subtle contrast).

### 8.4 Fit labels (badges)

Small pill used on dish cards to express fit. Four values:

| Label | Background | Text |
|---|---|---|
| Fastest | `ember.100` | `ember.600` |
| Least waste | `sage.100` | `sage.600` |
| Best fit | `voice.100` (reused here; sparingly) | `voice.600` |
| Missing X | `paper.200` | `ink.700` |

Only ONE fit label per dish (the primary). Secondary fit reasons go in the "why it fits" text, not as a second badge.

### 8.5 Input fields

Standard iOS text fields with these overrides:
- Height 48pt
- 12pt radius
- `paper.100` fill, 1pt `ink.100` border
- Focused state: 1pt `ember.600` border
- Error state: 1pt `crimson.600` border + inline error text below in `crimson.600 body.sm`

### 8.6 Sheets

`.sheet` presentation style for any modal that's not the paywall. Default detent is `.medium`, user can drag to `.large`. Sheet uses `paper.100` background (vs screen `paper.50`) for layered feel. 24pt top corner radius (iOS default). Grab indicator visible (iOS default, don't hide).

**Substitution Sheet** is the prototypical sheet — ingredient picker + problem text field + submit → result card.

### 8.7 Banners

Top-of-screen strip for persistent state. Three flavors:

| Type | Background | Icon | Use |
|---|---|---|---|
| Info | `paper.200` | info icon | `SYNC-01` iCloud unavailable, offline mode |
| Warning | `amber.100` | amber triangle | `BILL-01` grace period, `AI-VOICE-01` fallback |
| Error | `crimson.100` | crimson triangle | Rare; most errors are inline not banner |

Banner height 44pt, dismissible with an X on the right (unless state is unresolvable — grace period stays until billing resolves).

### 8.8 Empty states

Large centered illustration area (SF Symbol at `icon.xl`, `ink.300`), display.md heading, body.md body copy, optional primary button. Used on Saved Library (no meals yet), Leftovers (nothing queued), Grocery (nothing missing).

### 8.9 Cook Mode step card

The core UI surface. Full-screen, ember-tinted edge glow when voice is active.

**Structure** (top to bottom):
- Step number + "X of Y" progress
- Step title (optional, display.md)
- Step instruction text (body.lg, generous leading)
- Timer chip (if step has timer) with play/pause
- Primary: Next Step button (PrimaryButton, full width)
- Secondary row: Previous / Ask (opens Substitution Sheet) / Exit
- Mic affordance top-right on Premium+ only (44pt circle, voice.600 when active)

### 8.10 Paywall card

Tier comparison uses two stacked cards (Premium / Pro). Current tier (if any) shows a checkmark badge. Selected tier gets an ember border ring. Price shown in display.md, features listed as checklist with sage checkmarks.

---

## 9. Screens catalog (v1 inventory)

All screens mapped to spec §6 screen table. Every mockup produced for Stir must reference one of these names. No inventing screen types.

**Root / shell:**
1. Launch / Session Restore
2. Welcome
3. Offline fallback banner state

**Onboarding:**
4. Setup 1 — Preferences (diet rules, dislikes, goals)
5. Setup 2 — Kitchen & Servings
6. Onboarding complete transition

**Tonight (primary tab):**
7. Tonight Home
8. Tonight Home — first use (empty state)
9. Tonight Home — offline fallback
10. Use Soon card (leftovers prompt appears inline)

**Scan flow:**
11. Scan Camera primer (permission pre-request)
12. Scan Camera capture
13. Scan Review (ingredient chips, confidence states)
14. Scan Sample fallback (camera denied)

**Solve flow:**
15. Constraints Sheet
16. Dinner Options (streaming in, 3 cards)
17. Dinner Options — broaden constraints state (<3 viable)
18. Dish Preview
19. Dish Preview — with grocery export CTA

**Cook Mode:**
20. Cook Mode — tap-only (Free tier)
21. Cook Mode — voice active (Premium+)
22. Cook Mode — voice fallback banner (AI-VOICE-01)
23. Cook Mode — voice permission primer
24. Cook Mode — mid-step with active timer
25. Substitution Sheet (text)
26. Substitution Sheet — result card (safe)
27. Substitution Sheet — result card (unsafe/allergen)

**Post-cook:**
28. Outcome Feedback sheet
29. Leftovers prompt (when leftoverCount > 0)
30. Leftovers solve result

**Saved:**
31. Saved Library
32. Saved Library — Free tier locked (favorites gate)
33. Recipe Detail / Replay

**Import:**
34. Import Entry
35. Share Extension import in-app
36. Import Review / Edit
37. Import async processing (push-await)

**Grocery:**
38. Grocery list view
39. Grocery export to Reminders (success)
40. Grocery export fallback (permission denied, in-app)

**Widgets & extensions:**
41. Home Screen widget — small
42. Home Screen widget — medium
43. Home Screen widget — large
44. Home Screen widget — Free tier locked
45. Timer Live Activity — Lock Screen
46. Timer Live Activity — Dynamic Island (compact + expanded + minimal)

**Settings:**
47. Settings root
48. Household Preferences
49. Plan & Billing — Free
50. Plan & Billing — Trial
51. Plan & Billing — Premium active
52. Plan & Billing — Pro active
53. Plan & Billing — Grace period
54. Plan & Billing — Cancelled active
55. Plan & Billing — Expired
56. Notifications preferences
57. Privacy & Support
58. Local-Only / Sync Status explainer

**Paywall variants:**
59. Paywall — default (dinnerSolveQuotaExhausted trigger)
60. Paywall — voiceAffordanceTapped (highest-intent)
61. Paywall — savedFavoritesGate
62. Paywall — multiImageScanGate (Pro upsell)
63. Paywall — leftoversGate
64. Paywall — widgetsGate
65. Paywall — settingsUpgrade

**Error / permission recovery states:**
66. Permission Recovery — Camera denied
67. Permission Recovery — Microphone denied
68. Permission Recovery — Photos denied
69. Permission Recovery — Reminders denied
70. Error: NET-01 (full screen or inline)
71. Error: AI-01 (full screen)
72. Error: RATE-01 (inline on action)
73. Error: PAY-01 (inline on paywall)

---

## 10. Dark mode

Dark mode is not "invert the palette and call it done." Cooking often happens with overhead lights on; dark mode is chosen by users who prefer it, not because the app demands it. That means dark mode should feel equally considered — not as a fallback.

**Key adjustments:**
- Paper tones shift warm-neutral, not pure black. Pure black (`#000`) feels clinical and OLED-burn-prone on text-heavy screens.
- Ember saturates slightly to maintain contrast on darker backgrounds.
- Shadows are subtle but present (dark mode only — see §5.5).
- Images / photos: never assume dark mode support. Any photo in the UI (dish photo in Dish Preview, recipe photo in imported recipe) is displayed on `paper.100` in both modes; don't let it bleed to black background.

---

## 11. Accessibility checklist

Every component and screen verified against:

- [ ] Dynamic Type XS → XXXL with no cropped primary action
- [ ] 44×44pt minimum tap target
- [ ] 4.5:1 contrast for body text, 3:1 for large text
- [ ] VoiceOver label on every interactive element
- [ ] Semantic announcement on state change (timer started, turn advanced)
- [ ] No color-only meaning (icon + color for every state)
- [ ] Reduce Motion: all motion degrades to fade or instant
- [ ] Voice Control: every button reachable by its spoken label
- [ ] Caption / text alternative for any spoken AI output (Cook Mode voice shows transcript inline)
- [ ] Haptics optional, never required to understand state

---

## 12. File layout

All tokens live in SwiftUI:

```
Stir/DesignSystem/
  Tokens/                             # Phase 3 of token integration — delivered
    Colors.swift                      # Color.Stir.* — full palette from §3, light + dark adaptive
    Typography.swift                  # Font.Stir.* — scale from §4.1 with baked tracking
    Spacing.swift                     # CGFloat.Stir.space1...space7 + screen margins
    Radius.swift                      # CGFloat.Stir.radius* — 8-token scale from §5.4
    Icons.swift                       # Image.Stir.* — semantic → SF Symbol map from §6
  Motion/                             # Phase 5 (Cook Mode) — stubbed
    Durations.swift                   # .fast 150ms, .default 200ms, .sheet 300ms
    Easings.swift                     # .out, .in per §7.2
  Shadows/                            # Phase 5 (Cook Mode) — stubbed
    StirShadow.swift                  # sheetEdge, modal, cookStepCardDark, emberGlow, softPress
  Components/                         # Land per-feature as build steps consume them, NOT up-front
    PrimaryButton.swift
    SecondaryButton.swift
    TextButton.swift
    Chip.swift
    DishOptionCard.swift
    SavedMealCard.swift
    FitLabel.swift
    InputField.swift
    Banner.swift
    EmptyState.swift
    StepCard.swift                    # Cook Mode
    PaywallCard.swift
  Modifiers/
    StirBackground.swift              # applies paper.50/100/200
```

No view in `Stir/Features/*` hard-codes a hex, a pt value, or a font size. Everything goes through design system tokens. Lint rule: `grep -rE '#[0-9A-Fa-f]{6}' Stir/Features/` must return zero results.

**Tokens vs components:** tokens ship as a single layer (Phase 3). Components land feature-by-feature as build steps need them — there is no "build the component library up front" sprint. The `Components/` tree above is the eventual shape, not a green-field to-do list.

---

## 13. Evolution policy

This document is v1. Changes go through PR review (even solo — open a PR to yourself, sit on it for 24h, then merge). Color additions require naming rationale. New components require use-case justification — not "I might need this later."

v2 considerations (explicitly NOT for v1):
- Custom icon set
- Illustration library for empty states
- Third-party typeface (if SF Pro + New York ever feels insufficient)
- iPad adaptation
- Localization (right-to-left support)

Don't ship any of this in v1. They're notes for the next planning cycle.
