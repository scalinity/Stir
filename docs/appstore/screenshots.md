# Screenshot Storyboard

10 screenshots × 2 device classes (6.7" + 6.1" iPhone). Capture from Release build on physical device with curated demo account. iPad deferred per v1 spec.

---

## Device targets + dimensions

| Device class | Reference device | Portrait dimensions | Count |
|---|---|---|---|
| 6.7" | iPhone 15 Pro Max / iPhone 17 Pro Max | 1290×2796 | 10 |
| 6.1" | iPhone 15 / iPhone 17 | 1170×2532 | 10 |

Same 10 shots re-captured per device class. Apple auto-scales for 6.5"/5.5" fallback if we don't supply separate captures; at launch Daniel provides only the two required sizes.

---

## Demo account staging

Sign into TestFlight with a dedicated test Apple ID. Seed the account:

| State | Value |
|---|---|
| Tier | Premium with 2 days trial remaining |
| Preferences | no dietary rules; mild dislikes (olives, cilantro); family of 2; dinner-prep time 20-30 min |
| Pantry (15 items) | spinach, chicken thighs, canned tomatoes, onions, garlic, pasta, rice, eggs, butter, parmesan, feta, bell peppers, lemon, olive oil, frozen peas |
| Saved favorites (3) | Quick pasta pomodoro, Sheet-pan chicken, Spinach frittata |
| Recent rating | meal last cooked rated 5 |
| Permission state | Camera + Reminders granted; Mic granted (Premium); Notifications granted |
| Simulator chrome | 9:41 AM, battery full (green), Wi-Fi 3-bar, no cellular indicator, no silent switch |

**Capture tool:** iPhone natively (side-button + volume-up). Clean status bar via `xcrun simctl status_bar ...` if shooting on simulator; for device captures use a fresh charge + Wi-Fi only.

---

## Shot-by-shot

Each shot has: (1) screen state, (2) overlay copy (rendered in Figma or iMovie title tool, NOT in the app), (3) staging notes.

### Shot 1 — "Point at your kitchen"

- **Screen:** Scan primer (mockup `04_scan_flow.html` → primer state)
- **Overlay:** "Point at your kitchen"
- **Subcopy:** "Fridge, pantry, or counter — anything works."
- **Staging:** Scan button visible at bottom; hero illustration/camera-viewfinder framing fills the upper 70% of the screen.

### Shot 2 — "Get 3 dinners in 60 seconds"

- **Screen:** Dinner Options after Solve (mockup `05_solve_flow.html` → loaded)
- **Overlay:** "Get 3 dinners in 60 seconds"
- **Subcopy:** "Based on what's already in your kitchen."
- **Staging:** 3 dish cards visible:
  1. "Spinach and feta frittata — 20 min"
  2. "Chicken thighs with olives & lemon — 40 min"
  3. "Lemon garlic pasta — 25 min"
  Each card shows fit labels (vegetarian icon, clock, "uses spinach" ingredient-tag).

### Shot 3 — "Cook hands-free" (Premium badge visible)

- **Screen:** Cook Mode voice variant, active turn (mockup `07_cook_mode_voice.html`)
- **Overlay:** "Cook hands-free" + Premium badge
- **Subcopy:** "Ask, swap, time — without touching your phone."
- **Staging:** Step 3 of 8 ("Sauté the onions for 3 minutes"); timer running 2:47; microphone waveform animating (take the shot mid-waveform for visual motion). Spoken-response bubble visible: "Sauté the onions for 3 minutes, stirring occasionally."

### Shot 4 — "Out of something? Fix it mid-cook"

- **Screen:** Substitution result after asking "can I use Greek yogurt instead of sour cream?" (mockup `08_substitution.html` → safe-result state)
- **Overlay:** "Out of something? Fix it mid-cook"
- **Subcopy:** "AI suggests swaps that fit your diet."
- **Staging:** Substitution sheet showing "Use Greek yogurt 1:1 for sour cream in this recipe. Same tang, slightly thicker texture." with green "Safe swap" indicator and food-safety disclaimer footer visible.

### Shot 5 — "Missing items, one tap away"

- **Screen:** Grocery Export success (mockup `12_grocery.html`)
- **Overlay:** "Missing items, one tap away"
- **Subcopy:** "Write your grocery list straight to Reminders."
- **Staging:** 5 missing items listed (sour cream, fresh dill, chicken stock, lemons, butter) with "Exported to Reminders" toast visible; partial Reminders icon visible at edge to telegraph integration.

### Shot 6 — "Turn leftovers into tomorrow's dinner"

- **Screen:** Leftovers mode — Leftover Suggestion (mockup `09_post_cook.html` → leftover solve)
- **Overlay:** "Turn leftovers into tomorrow's dinner"
- **Subcopy:** "Less waste. More ideas."
- **Staging:** Leftover Suggestion card: "Your leftover chicken + rice → Chicken fried rice" with "Cook this tomorrow" CTA.

### Shot 7 — "Save your weeknight winners"

- **Screen:** Saved library (mockup `10_saved.html` → 6 favorites visible)
- **Overlay:** "Save your weeknight winners"
- **Subcopy:** "Cook your favorites in one tap."
- **Staging:** 6 saved favorites in a 2-column grid, each with star rating + "last cooked 5 days ago" relative timestamps. Favorite-star icon in ember tint.

### Shot 8 — "One tap to tonight's dinner"

- **Screen:** iOS Home Screen with Stir widget (mockup `13_widgets_liveactivity.html` → Tonight widget)
- **Overlay:** "One tap to tonight's dinner"
- **Subcopy:** "Pin Stir to your Home Screen."
- **Staging:** Stir widget in a 2×2 slot at top-left of a simulated Home Screen; widget shows "Tonight's dinner — Spinach frittata, 20 min". Adjacent apps on the Home Screen are generic iOS defaults (Weather, Calendar, Photos) to avoid competitor confusion. Status bar shows 9:41 / full battery.

### Shot 9 — "Use the spinach before it goes"

- **Screen:** Tonight Home — Use-soon card (mockup `03_tonight_home.html` → Use Soon)
- **Overlay:** "Your kitchen remembers"
- **Subcopy:** "Ingredients close to expiring bubble to the top."
- **Staging:** Tonight Home with a Use-soon nudge card at top: "Use your spinach before it goes — want 3 dinner ideas?" with a subtle 48h expiry timer visual.

### Shot 10 — "Fits your diet, your time, your ingredients"

- **Screen:** Dish preview with fit labels illuminated (mockup `05_solve_flow.html` → dish preview)
- **Overlay:** "Fits your diet, your time, your ingredients"
- **Subcopy:** "Stir reads your kitchen and your preferences."
- **Staging:** Dish preview for "Spinach and feta frittata" with 3 fit labels illuminated: "Vegetarian" / "20 min" / "Uses spinach". Recipe steps visible below but slightly scrolled off to prioritize the fit-labels visual.

---

## Copy-overlay style

Exported as transparent PNG overlays via Figma; composited in Final Cut / iMovie title-tool on top of raw screenshots.

- **Title font:** SF Pro Display Black
- **Title size:** 64pt (6.7") / 56pt (6.1")
- **Subcopy font:** SF Pro Display Medium
- **Subcopy size:** 36pt (6.7") / 32pt (6.1")
- **Fill:** Linear gradient `#FF7A33 → #FF4D6D` (verify against `Specs/Design-System.md` — gradient should match the primary palette ember-to-pink swirl)
- **Drop shadow:** 0 / 2 / 8 / rgba(0,0,0,0.25)
- **Position:** title centered horizontally, 120pt from top of safe area; subcopy 16pt below title
- **White scrim behind subcopy:** 30% black rectangle blur if the underlying UI content is light / low-contrast
- **No alternate language text** — US-only launch per spec §11. Localize per market if/when we expand.

---

## Capture + export workflow

1. On the demo device, drive the UI to each shot's target state using the staging notes.
2. Take the screenshot (iPhone: side-button + volume-up; Simulator: ⌘S).
3. Airdrop to Mac, open each PNG in Figma.
4. Apply the title-overlay layer from the shared Figma file at `/design/appstore-overlays.fig` (Daniel creates this file once; reuse for each iteration).
5. Export PNG at target dimensions via Figma > Export > 1290×2796 (6.7") / 1170×2532 (6.1").
6. Verify each export:
   - No status-bar clock drift (all shots show 9:41)
   - No carrier name in status bar (Wi-Fi-only)
   - No personal Apple ID leakage (demo account only)
   - No debug overlays (no FPS counter, no Xcode runtime overlays)
7. Upload to App Store Connect under "App Previews and Screenshots" for each device class.

---

## Re-shoot triggers (v1.1+)

- Major UX change to a featured screen (Dinner Options, Cook Mode, Paywall)
- Tier change affecting Premium copy ("20 voice sessions" → "13 voice sessions" per ADR 0015; already reflected in Shot 3's Premium badge since it's a visual not a count)
- Price change requiring "$9.99" updates in screenshots (we don't bake price into shots to avoid this)
- Localization expansion (new storefront = new screenshot pack per language)

---

## Known inconsistencies to watch

- Mockup HTMLs in `stir-app-design/project/DesignMockups/` may drift from shipped UI. The shot list references mockups for LAYOUT REFERENCE but the actual shipped UI is the source of truth for color/copy. If the shipped view differs materially, flag in `docs/decisions/` and update the mockup in the same PR.
- Voice Cook Mode "Premium badge" positioning in the shipped UI vs the mockup — Daniel verifies that the screenshot shows the badge in a prominent way (if the shipped UI hides it behind a gesture, reconsider the shot composition).

---

## Deliverables checklist

- [ ] 10 screenshots at 6.7" (1290×2796) — `shot1-67.png` through `shot10-67.png`
- [ ] 10 screenshots at 6.1" (1170×2532) — `shot1-61.png` through `shot10-61.png`
- [ ] Naming convention: `stir-screenshot-<shot#>-<device>.png` (Daniel's preference; no special Apple naming required)
- [ ] Upload to App Store Connect for Primary listing + each of the 3 custom product pages (per `metadata.md` configuration)
