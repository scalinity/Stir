# Stir — Design Mockups

This folder holds the 17 screen-package deliverables from the Claude Design Kickoff.
Each package is a self-contained HTML file: an iPhone 16 Pro frame per variant,
light + dark side-by-side, tokens referenced from `Specs/Design-System.md`.

Produced in batches. Daniel reviews each batch before the next begins.

| # | File | Covers |
|---|---|---|
| 1 | `01_shell_and_launch.html` | Launch, Welcome, Offline fallback banner |
| 2 | `02_onboarding.html` | Setup 1 Preferences, Setup 2 Kitchen & Servings, completion transition |
| 3 | `03_tonight_home.html` | Default, first-use empty, offline, Use Soon inline card |
| 4 | `04_scan_flow.html` | Camera primer, capture, review with chip states, sample fallback |
| 5 | `05_solve_flow.html` | Constraints Sheet, Dinner Options (streaming + broaden), Dish Preview |
| 6 | `06_cook_mode_tap.html` | Tap-only Cook Mode (Free) — step card, timer active, sub sheet |
| 7 | `07_cook_mode_voice.html` | Voice Cook Mode (Premium+) — mic idle/active/disabled, fallback banner, primer |
| 8 | `08_substitution.html` | Substitution Sheet + result card safe + result card unsafe/allergen |
| 9 | `09_post_cook.html` | Outcome Feedback sheet, Leftovers prompt, Leftovers solve result |
| 10 | `10_saved.html` | Saved Library, Free-tier locked state, Recipe Detail/Replay |
| 11 | `11_import.html` | Import Entry, Share Extension, Import Review, async processing |
| 12 | `12_grocery.html` | Grocery list, Reminders export success, in-app fallback |
| 13 | `13_widgets_liveactivity.html` | Home widget small/medium/large/locked; Live Activity + Dynamic Island |
| 14 | `14_settings.html` | Settings root, Household Preferences, Notifications, Privacy, Sync |
| 15 | `15_plan_billing.html` | Plan & Billing in all 7 states |
| 16 | `16_paywall.html` | Paywall in all 7 trigger variants |
| 17 | `17_errors_and_permissions.html` | Permission recovery, NET-01, AI-01, RATE-01, PAY-01 |

## Conventions

- **Frame:** iPhone 16 Pro (390×844) via Stir's custom flat bezel (no liquid glass).
- **Palette:** tokens from `Specs/Design-System.md` §3, inlined as CSS custom properties in each file.
- **Typography:** SF Pro (body) + New York (display) with web-safe fallbacks.
- **Icons:** Lucide-style SVG stand-ins for SF Symbols. On-device uses real SF Symbols.
- **Time in status bar:** 6:30pm–8:30pm — the cooking window.
- **Battery:** 40–70%. No 100%, no 10%.
- **Dark mode:** rendered adjacent to light, not as a separate page.
- **Annotations:** small captions below variants where state is non-obvious.

## Batch schedule

- **Batch 1** (this drop): 01, 02, 03 — visual language foundation.
- Batches 2–6 ship after Daniel's review of Batch 1.
