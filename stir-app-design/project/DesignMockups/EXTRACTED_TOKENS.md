# Stir — Tokens Extracted from Design Mockups

**Authored:** 2026-04-19
**Source of truth:** `stir-app-design/project/DesignMockups/*.html` + `_shared/colors_and_type.css`
**Supersedes (for token values):** `Specs/Design-System.md` §3 Color, §4 Typography, §5 Spacing & Layout, §6 Iconography, §12 File Layout.
**Does NOT supersede:** design principles (§1, §2, §7, §11, §13), nor product/pricing/tier decisions in CLAUDE.md and ADRs.

This document is the audit artifact before Swift tokens are created. Every entry names the mockup it came from and flags where the mockups extended or contradicted the existing spec.

---

## 1. Methodology

- Read all 17 mockups (`01_shell_and_launch.html` → `17_errors_permissions.html`) plus `_shared/colors_and_type.css` and `_shared/mock-page.css`.
- Counted every unique hex, type size, radius, letter-spacing, and font weight across the bundle.
- Cross-referenced against the CSS variables in `_shared/colors_and_type.css` (the designer's declared tokens).
- Discarded: mock-page gallery chrome (`#EFEAE1`, `#D9D2C4`, `#f7f3ec`), phone-frame chrome (radii 48/54), iOS system colors used only for accuracy (`#007AFF`, `#34C759`, `#FFCC00`, Visa `#1A1F71`), and scene-illustration fills (camera darks `#0a0805`/`#0c0806`, cookbook page `#E8DFCF`).
- Frame-of-reference: iPhone 16 Pro (390×844). All token values are in iOS points (1px on mockup = 1pt on device).

---

## 2. Color tokens

### 2.1 Primary palette — matches spec §3 exactly

All values in the shared CSS match `Specs/Design-System.md` §3.1 + §3.2 to the hex. Confirmed by counting instances across all 17 files:

**Light (declared in `_shared/colors_and_type.css` lines 41–95):**

| Token | Hex | Mockup count | Spec match |
|---|---|---|---|
| `ink.900` | `#1A1612` | 71 | ✓ |
| `ink.700` | `#3D342C` | 52 | ✓ |
| `ink.500` | `#6B5F54` | 101 | ✓ |
| `ink.300` | `#A89E93` | 20 | ✓ |
| `ink.100` | `#E8E3DD` | 37 | ✓ |
| `paper.50` | `#FAF7F2` | 21 | ✓ |
| `paper.100` | `#F3EEE5` | 20 | ✓ |
| `paper.200` | `#EBE3D6` | 21 | ✓ |
| `ember.600` | `#C8532B` | 41 | ✓ |
| `ember.500` | `#E26340` | 36 | ✓ |
| `ember.100` | `#FBEAE0` | 21 | ✓ |
| `sage.600` | `#4A7C59` | 24 | ✓ |
| `sage.100` | `#E4EEE6` | 21 | ✓ |
| `amber.600` | `#B8860B` | 24 | ✓ |
| `amber.100` | `#F5ECD5` | 21 | ✓ |
| `crimson.600` | `#9A2E2E` | 13 | ✓ |
| `crimson.100` | `#F2DCDC` | 12 | ✓ |
| `voice.600` | `#5E4AE0` | 10 | ✓ |
| `voice.100` | `#E8E3FA` | 8 | ✓ |

**Dark (declared lines 98–124):**

| Token | Hex | Mockup count | Spec match |
|---|---|---|---|
| `ink.900` dark | `#F5F0E8` | 50 | ✓ |
| `ink.700` dark | `#D6CEC3` | 17 | ✓ |
| `ink.500` dark | `#9A8F84` | 17 | ✓ |
| `ink.300` dark | `#5E5349` | 17 | ✓ |
| `ink.100` dark | `#2E2822` | 17 | ✓ |
| `paper.50` dark | `#14100B` | 17 | ✓ |
| `paper.100` dark | `#1F1A14` | 17 | ✓ |
| `paper.200` dark | `#2A241C` | 17 | ✓ |
| `ember.600` dark | `#E26340` | (folded with light) | ✓ |
| `ember.500` dark | `#F07D5A` | 3 | ✓ |
| `ember.100` dark | `#3A1E13` | 17 | ✓ |
| `sage.600` dark | `#6FA07C` | 17 | ✓ |
| `sage.100` dark | `#1E2E23` | 17 | ✓ |
| `amber.600` dark | `#D4A21F` | 17 | ✓ |
| `amber.100` dark | `#2E2614` | 17 | ✓ |
| `crimson.600` dark | `#C94747` | 9 | ✓ |
| `crimson.100` dark | `#2E1818` | 9 | ✓ |
| `voice.600` dark | `#8473E8` | 7 | ✓ |
| `voice.100` dark | `#1F1A33` | 6 | ✓ |

**Zero contradictions on the primary palette.** Mockups confirm every named token in the spec.

### 2.2 New color tokens introduced by mockups

| Token (proposed Swift name) | Light hex | Dark hex | Source | Count | Role |
|---|---|---|---|---|---|
| `ember.700` (aka `emberDeep`) | `#8F3B1D` | `#C8532B` | `15_plan_billing.html:52`, `16_paywall.html:28` | 2 | Gradient-stop pair with `ember.600` for premium Pro cards / tier badges. Always appears as `linear-gradient(135deg, ember.600 → ember.700)`. |
| `rust.600` | `#A8441F` | `#E26340` | `17_errors_permissions.html:28` | 3 uses within one file | Soft recoverable-error accent: "Couldn't read this page", OCR parse degraded. Distinct from `crimson.600` (hard dietary/allergen errors) and `amber.600` (pending review). |

**Recommendation:** Add both as named tokens. `ember.700` is used consistently enough that it's a real system color. `rust.600` is narrow but semantically distinct from the other warning family colors — keep it but constrain its use to soft AI/parse failures only (`IMPORT-01`, low-confidence OCR).

### 2.3 Flagged contradictions with Design-System.md

**C1 — Primary paywall CTA color.** Spec §8.1 states `PrimaryButton` uses `ember.600` fill. The mockup `16_paywall.html` chooses `ink.900` (warm black) for 2 of 3 paywall surface variants (soft bottom sheet, inline card). Only the feature modal (voice paywall) uses `ember.600`.

- `16_paywall.html:112` — `PaywallSolve` CTA: `background:c.ink900`
- `16_paywall.html:242` — `PaywallScan` CTA: `background:c.ink900`
- `16_paywall.html:161` — `PaywallVoice` CTA: `background:c.ember`

This is a deliberate editorial choice: the paywall adopts a "soft/considered" tonality using near-black CTAs, reserving ember for in-flow decision moments (Tonight Home, Solve, Cook Mode — all confirmed ember-CTA across mockups). **Not a mistake.** Recommendation: treat paywall CTA styling as a scoped override in the paywall component, not a global repeal of §8.1.

**C2 — `rust.600` vs `crimson.600` semantic overlap.** Spec §3.1 establishes one critical/error color (`crimson.600`). Mockup `17_errors_permissions.html` introduced a separate `rust.600` for a distinct error subtype. Either reconcile (map rust→crimson and vary intensity by context) or accept both with clear scoping rules. **Recommendation:** accept both. `crimson.600` = hard rule violations (allergen, dietary breach). `rust.600` = soft recoverable AI/parse failures. Already consistent with the spec's ethos that errors get multiple semantic tiers.

**C3 — Card radius scale.** Spec §5.4 declares `radius.lg = 16` as the card radius, full stop. Mockups actually use **three** card-level radii: `14` (default cards — 65 instances), `16` (hero cards like `DishOptionCard` — 16 instances), `18` (elevated/accent cards like inline paywall — 5 instances). See §4 below.

---

## 3. Typography tokens

### 3.1 Face families — matches spec

Confirmed from `_shared/colors_and_type.css` lines 8–18 and consistent usage:

| Role | CSS var | Swift mapping |
|---|---|---|
| Display (New York) | `var(--font-serif)` | `.custom("NewYork-Semibold")` with `.serif` design fallback |
| Body (SF Pro) | `var(--font-sans)` | `.system(size:..., design: .default)` |
| Mono (SF Mono) | `var(--font-mono)` | `.system(size:..., design: .monospaced)` |

**Usage distribution** (explicit `var(--font-*)` references; body defaults to sans):

- Serif (New York): 120 — displays, logomark, hero numerals
- Mono (SF Mono): 19 — timer countdowns, voice-command quotes, measurements
- Sans (SF Pro): 56 explicit (body defaults without explicit family pull from `body { font-family: var(--font-sans) }`)

### 3.2 Type scale — matches spec §4.1 exactly at the named tokens

From `_shared/colors_and_type.css` lines 21–38:

| Token | Size | LH | Weight | Spec match |
|---|---|---|---|---|
| `display.xl` | 34 | 40 | 600 | ✓ |
| `display.lg` | 28 | 34 | 600 | ✓ |
| `display.md` | 22 | 28 | 600 | ✓ |
| `body.lg` | 17 | 24 | 400 | ✓ |
| `body.md` | 15 | 22 | 400 | ✓ |
| `body.sm` | 13 | 18 | 400 | ✓ |
| `label.lg` | 15 | 20 | 500 | ✓ |
| `label.md` | 13 | 18 | 500 | ✓ |
| `mono.md` | 15 | 22 | 400 | ✓ |
| `mono.lg` | 44 | 48 | 500 | ✓ |

### 3.3 Letter-spacing — NEW in mockups

Spec §4 does not specify letter-spacing. Mockups use it consistently:

| Scale | Tracking | Count | Use |
|---|---|---|---|
| `display.xl` / `display.lg` | `-0.02em` | 29 | Welcome hero, primary titles |
| `display.md` | `-0.015em` | 23 | Dish titles, section headers, prices |
| `display.sm` (mockups use 22pt semibold body titles here) | `-0.01em` | 23 | In-card subheadings |
| `label.eyebrow` (11pt/10pt uppercase) | `+0.12em` | 34 | Pro-card eyebrow ("STIR PRO") |
| `label.eyebrowStrong` (11pt/12pt uppercase) | `+0.14em` | 61 | Section labels, upper-case headers ("PRO FEATURE", "YOU'VE USED TODAY'S 3") |
| `label.microEyebrow` (9pt–10pt) | `+0.1em` | 11 | "MONTHLY", "ANNUAL" pricing tier eyebrows |

**Recommendation:** Tokenize as `Font.Stir.displayXl.tracking(.tight)`, or bake the tracking into the typography tokens directly. The uppercase-eyebrow variants (`0.12em`, `0.14em`, `0.1em`) should become explicit `label.eyebrow` / `label.eyebrowStrong` / `label.microEyebrow` tokens — they recur dozens of times and have a distinct role separate from the existing `label.md` (which is for button labels).

### 3.4 Font weight distribution

| Weight | Count | Role |
|---|---|---|
| 600 (Semibold) | 308 | Display, button labels, titles, eyebrow labels |
| 700 (Bold) | 105 | Uppercase eyebrow labels — brand voice wants these extra-emphatic |
| 500 (Medium) | 72 | Interactive labels (chips, inline buttons, feature bullets) |
| 400 (Regular) | 1 | (body default — rarely called out explicitly) |
| 300 (Light) | 1 | Single decorative usage |

**Flag for §4:** Spec §4.2 says "Body never bolds for emphasis. Use weight differently: Medium for interactive (buttons, chips), Regular for prose, Bold reserved for alerts only." Mockups follow this — the 105 Bold usages are all for uppercase eyebrow labels, not body emphasis. Consistent.

### 3.5 Off-scale type sizes (one-off hero numerals)

These are not system tokens — they're single-purpose hero sizes in specific mockups:

| Size | Location | Purpose |
|---|---|---|
| 96pt | `01_shell_and_launch.html:249, 269` | Welcome/Launch hero numeral |
| 88pt | (1 instance) | Launch fallback hero |
| 60pt | (1 instance) | Onboarding completion count |
| 56pt | (1 instance) | Success check icon frame |
| 40pt | `01_shell_and_launch.html:321` | Welcome headline |
| 38pt | (1 instance) | Onboarding stat |
| 36pt | (2 instances) | Large stat |
| 30pt | `16_paywall.html:79` | Paywall headline (display.xl scaled up slightly) |
| 26pt | `16_paywall.html:141` | Paywall modal headline (between display.lg and display.xl) |
| 24pt | 6 instances | Mock-page section titles (gallery chrome — ignore) |

**Recommendation:** Do not tokenize. These are bespoke per-screen hero sizes. The spec's `display.xl` (34pt) is close enough to the 30/36/40pt range that per-screen `.system(size: 30, weight: .semibold, design: .serif)` calls on hero views are fine, but those should be justified in comments rather than enshrined as tokens.

---

## 4. Spacing tokens

### 4.1 Base unit 4pt — matches spec §5.1

Confirmed. Every mockup uses multiples of 4 for inter-element spacing.

### 4.2 Named spacing scale — matches spec §5.2

All 7 tokens (`space.1`–`space.7`: 4, 8, 12, 16, 24, 32, 48) appear in the mockups. `_shared/colors_and_type.css` declares them identically.

### 4.3 Screen margins

- Standard screen horizontal margin: `16pt` — spec match (§5.1, `--screen-margin: 16px` in shared CSS)
- Hero screen margin (Welcome, Paywall feature modal): `20pt` — spec match (`--screen-margin-hero: 20px`)

---

## 5. Radius tokens

### 5.1 Named scale — spec says 4 tokens; mockups use 6

From `_shared/colors_and_type.css` lines 140–146:

| Token | Spec | Shared CSS | Mockup count | Primary use |
|---|---|---|---|---|
| `radius.sm` | 8 | 8 ✓ | 14 | Chips |
| `radius.md` | 12 | 12 ✓ | 72 | Buttons, inputs, pricing cards |
| `radius.lg` | 16 | 16 ✓ | 16 | **Hero cards only** (`DishOptionCard`, `SavedMealCard` primary) |
| `radius.xl` | 24 | 24 ✓ | 1 direct usage | Sheets/modals — but mockups prefer 22 instead (see below) |
| `radius.full` | 999 | 999 ✓ | 182 | Pills, mic button, avatar circles |
| **`radius.card` (NEW)** | — | not in CSS | 65 | Default card surface — `14pt`, dominant card radius across Tonight, Solve, Saved, Settings |
| **`radius.modal` (NEW)** | — | not in CSS | 15 | Centered modals (voice paywall, substitution result) — `22pt` |
| **`radius.accent` (NEW)** | — | not in CSS | 5 | Elevated accent cards (inline paywall, emphasized inline blocks) — `18pt` |

### 5.2 Contradiction with spec

**Spec §5.4 says:** "Cards use 16pt; buttons 12pt. Consistent everywhere."

**Mockups say:** Cards use **14pt** by default, **16pt** for hero cards (dish options), **18pt** for elevated accent cards. Modals use **22pt**, not the spec's **24pt**.

**Recommendation:** Update spec §5.4 to the 7-token radius scale (add `.card = 14`, `.accent = 18`, rename `.xl = 22`). Keep `.lg = 16` explicitly for `DishOptionCard` and `SavedMealCard`. Document the semantic distinction in the code: default cards = 14, hero cards = 16, accent cards = 18, modals = 22.

### 5.3 Other radii spotted — don't tokenize

| Value | Count | Reason |
|---|---|---|
| 48, 54 | 20+19 | Phone frame chrome — gallery only |
| 38, 28 | 1+3 | One-off accent chrome |
| 20, 13, 11, 10, 6, 5, 4, 3, 2, 1 | various | Shape-specific decorative radii (progress bars, scan-line highlights, stat dots). Not system tokens. |

---

## 6. Elevation & shadow tokens

### 6.1 Matches spec §5.5

Spec says: no drop shadows in light mode; elevation via 1pt hairline borders + fill step-up. One exception for dark-mode Cook Mode step card.

**Mockups confirm** this at the 1-pt hairline border level. Every card surface in every mockup uses `border: 1px solid ${c.ink100}` on light or `border: 1px solid ${c.ink100}` on dark — where `ink.100` is the divider token.

### 6.2 Shadow patterns found

These are deliberate, scoped shadows:

| Shadow | Value | Source | Role |
|---|---|---|---|
| `shadow.sheetBottom` | `0 -8px 24px rgba(0,0,0,0.X)` or `0 -10px 40px rgba(26,22,18,0.X)` | `06_cook_mode_tap.html:227`, `08_substitution.html:60`, `11_import.html:116`, `12_grocery.html:263`, `16_paywall.html:72` | Top-edge shadow on bottom sheets that separate from underlying content |
| `shadow.modal` | `0 30px 60px rgba(0,0,0,0.25)` | `16_paywall.html:127` | Centered modal elevation |
| `shadow.cookStepCardDark` | `0 -10px 40px rgba(26,22,18,...)` (dark mode only) | `06_cook_mode_tap.html:227` | Spec §5.5 exception — matches |
| `shadow.emberButton` | `0 6px 20px ${c.ember}44` (25% alpha ember) | `06_cook_mode_tap.html:187` | Cook Mode primary action (mic/next-step) with colored glow |
| `shadow.softPress` (3D button) | `0 2px 0 ${dark?'#2a2520':'#e8e1d4'}` | `01_shell_and_launch.html:214`, `02_onboarding.html:104`, `03_tonight_home.html:136` | **NEW pattern** — skeuomorphic "pressed button" 2-pt drop that feels tactile. Dark companion `#2a2520`, light companion `#e8e1d4`. |

**Proposed tokens:**

- `Shadow.Stir.sheetEdge` — `color: .black.opacity(0.08), radius: 24, y: -8`
- `Shadow.Stir.modal` — `color: .black.opacity(0.25), radius: 30, y: 15`
- `Shadow.Stir.cookStepCardDark` — spec §5.5 value — already documented
- `Shadow.Stir.emberGlow` — `color: Color.Stir.ember600.opacity(0.27), radius: 10, y: 6`
- `Shadow.Stir.softPress` — `color: Color.Stir.pressShadowLight / pressShadowDark, radius: 0, y: 2` (uses custom shadow companion colors `#e8e1d4` light, `#2a2520` dark — add as `pressShadow` token)

### 6.3 backdropFilter usage — no SwiftUI direct equivalent

Mockups use CSS `backdropFilter: blur(...)` in:

- `13_widgets_liveactivity.html:204, 221, 327` — Dynamic Island overlay blur (`18–24px`)
- `16_paywall.html` — `BlurBG` component for under-sheet content is implemented via `filter: blur(20px) + opacity(0.55)`, not `backdropFilter`

**SwiftUI translation gap:** `backdropFilter` (background-blur-behind-element) maps to `.background(.ultraThinMaterial)` or `BlurView` via `UIViewRepresentable`. Document this as a translation rule when building the Dynamic Island Live Activity (step 7, not step 5).

**Under-sheet blurred content** (the paywall `BlurBG` component): in SwiftUI, use `.background { Color.Stir.paper50 }` on the foreground sheet and rely on sheet presentation style. Do not try to literally reproduce the blurred mock; the iOS sheet affordance already provides the correct visual separation via its material.

---

## 7. Motion tokens

Matches spec §7.1 and shared CSS:

| Token | Value | Spec match |
|---|---|---|
| `duration.fast` | 150ms | ✓ (exits) |
| `duration.default` | 200ms | ✓ |
| `duration.sheet` | 300ms | ✓ (ceiling) |
| `easing.out` | `cubic-bezier(0.2, 0.0, 0.2, 1)` | Maps to SwiftUI `.easeOut(duration: 0.2)` |
| `easing.in` | `cubic-bezier(0.4, 0.0, 1.0, 1)` | Maps to SwiftUI `.easeIn(duration: 0.15)` |

Reduce Motion override is declared in `_shared/colors_and_type.css` lines 164–170 — matches spec §7.1.

---

## 8. Iconography tokens

### 8.1 Size scale — matches spec §6

| Token | Size | Mockup match |
|---|---|---|
| `icon.sm` | 16 | ✓ |
| `icon.md` | 20 | ✓ |
| `icon.lg` | 28 | ✓ |
| `icon.xl` | 44 | ✓ |

### 8.2 Semantic → SF Symbol mapping

Mockups use SVG stand-ins per README convention. Each SVG has a semantic name; the table below maps every SVG name observed to its SF Symbols counterpart. **This is the v1 icon vocabulary.**

| Semantic name (mockup) | SF Symbol | Spec §6 match |
|---|---|---|
| `SF.alert` | `exclamationmark.triangle.fill` | New |
| `SF.allergen` | `exclamationmark.triangle.fill` (in `crimson.600`) | ✓ spec "Allergen warning" |
| `SF.arrowR` | `arrow.right` | New |
| `SF.back` | `chevron.backward` | New |
| `SF.bell` | `bell` | New |
| `SF.bolt` | `bolt.fill` | New |
| `SF.book` | `book.closed` | New |
| `SF.bookmark` | `bookmark` / `bookmark.fill` | ✓ |
| `SF.box` | `archivebox` | New |
| `SF.cam` / `SF.camera` | `camera` / `camera.viewfinder` | ✓ |
| `SF.cart` | `cart` | ✓ |
| `SF.check` | `checkmark` | ✓ (Success) |
| `SF.chef` | `fork.knife` | ✓ |
| `SF.chev` / `SF.chevronL` / `SF.chevronR` | `chevron.forward` / `chevron.backward` | New (navigation) |
| `SF.clock` | `clock` | New (distinct from timer — used for total cook time) |
| `SF.close` / `SF.x` | `xmark` | New |
| `SF.cloud` | `icloud` | New (sync status) |
| `SF.cloudOff` | `icloud.slash` | New (SYNC-01 iCloud unavailable) |
| `SF.edit` | `pencil` | ✓ |
| `SF.eye` | `eye` | New |
| `SF.filter` | `line.3.horizontal.decrease` | New |
| `SF.flame` | `flame` | New (spiciness indicator) |
| `SF.flash` | `bolt.fill` | New (quick action / fast) |
| `SF.fork` | `fork.knife` | ✓ |
| `SF.gear` | `gearshape` | ✓ |
| `SF.heart` | `heart` / `heart.fill` | ✓ |
| `SF.help` / `SF.question` | `questionmark.circle` | ✓ (Low confidence) |
| `SF.house` | `house` | New |
| `SF.info` | `info.circle` | New |
| `SF.link` | `link` | New |
| `SF.lock` | `lock.fill` | New |
| `SF.mic` / `SF.micFill` | `mic` / `mic.fill` | ✓ |
| `SF.minus` | `minus` | New |
| `SF.palette` | `paintpalette` | New |
| `SF.pantry` | `basket` | New |
| `SF.pause` | `pause.fill` | New |
| `SF.photo` | `photo` | New |
| `SF.play` | `play.fill` | New |
| `SF.plus` | `plus` | New |
| `SF.refresh` | `arrow.clockwise` | New (distinct from `swap`) |
| `SF.search` | `magnifyingglass` | New |
| `SF.share` | `square.and.arrow.up` | ✓ |
| `SF.shield` | `shield.fill` | New |
| `SF.sparkle` / `SF.sparkles` | `sparkles` | ✓ (paywall + tier badges only) |
| `SF.star` | `star.fill` | ✓ (Pro upsell) |
| `SF.stir` | custom (whisk) — no exact SF Symbol; use `wand.and.stars` placeholder, flag for custom icon in v2 | New — NO DIRECT SF SYMBOL |
| `SF.swap` | `arrow.triangle.2.circlepath` | ✓ (Substitution) |
| `SF.text` | `text.alignleft` | New |
| `SF.timer` | `timer` | ✓ |
| `SF.user` | `person.crop.circle` | New |
| `SF.warn` | `exclamationmark.triangle` | New (distinct from crimson allergen — warn is amber or rust) |
| `SF.wifi` / `SF.wifiSlash` | `wifi` / `wifi.slash` | New (NET-01) |

### 8.3 Flagged for v1 vs v2

- `SF.stir` (whisk) — no clean SF Symbol. Spec §13 explicitly defers a custom icon set to v2. For v1, either use `wand.and.stars` as a conceptually-adjacent placeholder or use a text-only "S" wordmark. **Recommendation:** v1 ships with wordmark only (spec §2 agrees — "wordmark-only for v1"). Strip `SF.stir` from the icon vocabulary and use Typography display token for the logomark rendering.

---

## 9. File-layout implication for Swift tokens

Matches spec §12 file layout. No additional files needed. One naming recommendation:

```
Stir/DesignSystem/Tokens/
  Colors.swift       // Color.Stir.* — matches §2.1 + §2.2 additions
  Typography.swift   // Font.Stir.* — with tracking baked in per §3.3
  Spacing.swift      // CGFloat.Stir.space1...space7, screenMargin, screenMarginHero
  Radius.swift       // CGFloat.Stir.radiusSm...radiusFull, card, accent, modal
  Icons.swift        // Icon.Stir.* — the semantic→SF Symbol map in §8.2
```

Motion and Shadow tokens land later when components are built (per scope boundary — v1 ships tokens + paywall retrofit only). **Recommendation:** stub `Stir/DesignSystem/Motion/` and `Stir/DesignSystem/Shadows/` directories with a single `.gitkeep` or brief README so the layout is discoverable, but don't implement durations/easings/shadows yet.

---

## 10. Summary: what to do in Phase 2–4

**Phase 2 (Specs/Design-System.md updates):**

- §3 Color: add `ember.700` (light `#8F3B1D`, dark `#C8532B`) and `rust.600` (light `#A8441F`, dark `#E26340`). Document `rust` scoping: soft AI/parse errors only.
- §4 Typography: add letter-spacing column to §4.1 table (`-0.02em` / `-0.015em` / `-0.01em` on display; `+0.12em` / `+0.14em` on uppercase eyebrow variants). Add `label.eyebrow` and `label.eyebrowStrong` to the scale.
- §5 Spacing & Layout: expand §5.4 radius scale to 7 tokens. Add `.card = 14`, `.accent = 18`. Rename `.xl` from 24 → 22 (with an aside: one-off 24 usages stay hard-coded). Update the prose "Cards use 16pt; buttons 12pt" to reflect the card/hero/accent distinction.
- §6 Iconography: replace partial semantic-icon table with the full mapping in §8.2 of this doc.
- §12 File Layout: add stub paths for Motion/ and Shadows/ to make deferred scope visible.
- Flag visible in §8.1: paywall CTA uses `ink.900` per mockup — note as component-level override, not a PrimaryButton policy change.

**Phase 3 (Swift tokens):**

- `Colors.swift` — Color.Stir namespace. Light/dark via `Color(UIColor { trait in trait.userInterfaceStyle == .dark ? dark : light })` pattern. Every token from §2.1 + §2.2.
- `Typography.swift` — Font.Stir namespace with Dynamic Type scaling via `.font(.system(...).textStyle(...))` or `ScaledMetric`. Bake letter-spacing via `.tracking()` modifier wrapped in typography helpers.
- `Spacing.swift` — `CGFloat.Stir` extension: `space1`…`space7`, `screenMargin`, `screenMarginHero`.
- `Radius.swift` — `CGFloat.Stir`: `radiusSm/Md/Lg/Xl/Full/Card/Accent/Modal`.
- `Icons.swift` — Single source of truth: `Icon.Stir.scan`, `.cook`, `.voiceActive`, `.voiceIdle`, … exposing either a `String` (SF Symbol name) or an `Image(systemName:)` already built. Prefer the latter for compile-time usage checks.

**Phase 4 (paywall retrofit):**

- Replace `.tint` / `.yellow` / `.green` / `.orange` / `.white` / `.secondary` with `Color.Stir.*` tokens.
- Replace `.font(.title2.bold())`, `.font(.headline)`, `.font(.callout)`, `.font(.caption)` with `Font.Stir.*` tokens.
- Replace hardcoded paddings (`padding(.horizontal, 24)`, `padding(.vertical, 32)`, etc.) with `CGFloat.Stir.space*` references.
- Primary CTA `background(.tint)` → `background(Color.Stir.ink900)` per mockup C1 (flagged above).
- Restore outer tint: set `.tint(Color.Stir.ember600)` at the `NavigationStack` level so selection/focus states stay ember without fighting the CTA override.
- Document SwiftUI translation gaps inline:
  - Gradient CTA background (not in mockup's current CTA, but present on Pro card): `LinearGradient(colors: [.Stir.ember600, .Stir.ember700], startPoint: .topLeading, endPoint: .bottomTrailing)`
  - `backdropFilter: blur` → not translated; iOS sheet material handles the blurred-behind effect natively.
  - The mockup's 3-surface paywall (soft bottom sheet / feature modal / inline) is **not** scope for this retrofit. Step-5 paywall remains single-sheet. The retrofit applies the visual tokens to the existing sheet; the multi-surface pattern lands in later steps.

**Lint contract:** `grep -rE '#[0-9A-Fa-f]{6}' Stir/Features/` returns zero results after Phase 4.

---

## 11. Questions flagged for Daniel

These are judgment calls that deserve your review before I commit:

1. **Paywall CTA color contradiction** — I'm implementing `ink.900` per mockup (contradicts §8.1 `PrimaryButton = ember.600`). Confirm this is a scoped paywall override, not a systemic policy change for all PrimaryButtons.
2. **`rust.600` naming** — `rust` isn't in the spec vocabulary. Alternate names: `ember.muted`, `parse.error`, `soft.error`. Recommend `rust.600` because the mockup designer picked that name and it preserves traceability.
3. **Card radius renumbering** — spec has `.lg = 16`, mockups use `.card = 14` as the default. Option A: add `.card = 14` as a new token and keep `.lg = 16` for DishOptionCard. Option B: renumber (`.lg = 14`, add `.heroCard = 16`). Going with Option A as it preserves existing spec references.
4. **Mockup paywall copy/pricing** — 16_paywall.html shows a single "Stir Pro $8/mo" tier. The spec (and CLAUDE.md) have Premium $9.99 + Pro $14.99 with annual trial. **I am NOT retrofitting the content** — only visual tokens. If you wanted the 3-surface paywall structure reworked, that's beyond token scope and should be a separate design-review → build task.
5. **`SF.stir` semantic icon** — no direct SF Symbol maps cleanly. I'm omitting from the v1 icon vocabulary and using wordmark-only per §2 principle.
