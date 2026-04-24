# Food Safety Disclaimer — In-app Strings

**Status:** Source of truth for in-app disclaimer copy. Lawyer-reviewed wording lives here; iOS code references these strings.
**Last updated:** 2026-04-24

Per spec §19 ("Claims risk") + ToS §2 ("AI-generated content disclaimer") + ToS §5 ("Limitation of liability"), Stir must display a food-safety disclaimer in 4 specific places. This doc is the single source of truth for the wording.

---

## Where disclaimers must appear (4 sites)

| # | Site | Visibility | Wording |
|---|---|---|---|
| 1 | Cook Mode footer | Always visible during an active cooking session | "Stir's guidance is AI-generated. Verify doneness, food safety, and allergen compatibility yourself." |
| 2 | Substitution result footer | Visible on every substitution result (sheet variant + voice-function-call variant) | "AI-suggested swap. Verify allergen and dietary compatibility before cooking." |
| 3 | Paywall fine-print | Visible on all 3 paywall surfaces (soft / feature / settings-upgrade) | "Stir provides cooking suggestions, not medical, dietary, or food-safety advice. Always verify independently." |
| 4 | Settings > Privacy > AI Disclosure | Standalone disclosure screen reachable from Settings | Full-form disclosure (see §3 below) |

---

## Wording rationale

Each string is short enough to fit common UI density without truncation at Dynamic Type AX5, but long enough to make the AI-generated-content posture explicit. Three repeating themes:

- **"AI-generated"** — sets reader expectation that output is probabilistic, not authoritative
- **"Verify ... yourself / independently / before cooking"** — places responsibility on the user
- **"Allergen compatibility"** — surfaces the highest-risk vector (allergens) as a specific check, not a generic disclaimer

The wording avoids:

- Medical advice claims (would conflict with §19 "no medical, dietary, or food-safety guarantees")
- Dietary recommendation claims (e.g., "this meal is healthy" — never)
- Definitive food-safety claims (e.g., "this temperature is safe" — never)

---

## Full Settings > Privacy > AI Disclosure (300-word screen)

```
About Stir's AI

Stir uses Google's Gemini AI to:
- Identify ingredients from photos of your kitchen
- Suggest dinner ideas based on what you have
- Provide step-by-step cooking guidance
- Suggest ingredient substitutions
- Power hands-free voice cooking (Premium)

The AI generates suggestions, not authoritative advice. Output is
probabilistic and may contain errors. Specifically:

**Food safety**
Stir's cooking guidance, including suggested cook times and
temperatures, is based on AI inference. You are solely responsible
for verifying that food is properly cooked, stored, and handled.
When in doubt, consult an authoritative food-safety resource (e.g.,
the USDA Food Safety and Inspection Service at fsis.usda.gov).

**Allergens**
Stir's substitution suggestions and ingredient identifications may
not catch every potential allergen. If you or anyone in your
household has a food allergy, verify every ingredient and
substitution against your allergen list independently. Stir is not
a substitute for an allergen specialist.

**Diet & medical**
Stir provides general dinner suggestions, not personalized dietary
advice. If you have a medical condition (diabetes, kidney disease,
heart disease, etc.) or specific dietary requirements, consult a
registered dietitian or your physician.

**AI errors**
Stir's AI may occasionally:
- Misidentify ingredients in scan photos
- Suggest recipes incompatible with your dietary preferences
- Recommend substitutions that don't account for an allergen
- Provide cook times or instructions that aren't right for your
  specific equipment

When you spot errors, please tap the "flag" button on the AI result.
Your feedback helps us improve.

**Liability**
Per our Terms of Service, Stir is provided "as is" without warranty.
You assume responsibility for verifying any AI-generated content
before relying on it.

For more, see our Terms of Service and Privacy Policy.
```

---

## Implementation guidance for iOS

These strings should live in a single localizable strings file (`Localizable.strings` or `Localizable.xcstrings`) in iOS, keyed for grep-ability:

```swift
// Localizable.xcstrings keys
"food_safety.cook_mode.footer"
  = "Stir's guidance is AI-generated. Verify doneness, food safety, and allergen compatibility yourself."

"food_safety.substitution.footer"
  = "AI-suggested swap. Verify allergen and dietary compatibility before cooking."

"food_safety.paywall.fine_print"
  = "Stir provides cooking suggestions, not medical, dietary, or food-safety advice. Always verify independently."

"food_safety.disclosure.body"
  = "About Stir's AI..."  // The 300-word screen above
```

Reference these strings via `String(localized:)` in:

- `Stir/Features/CookMode/CookModeRoot.swift` (footer view)
- `Stir/Features/Substitution/SubstitutionSheetView.swift` (result section)
- `Stir/Features/Billing/PaywallView.swift` (paywall fine-print block)
- `Stir/Features/Settings/AIDisclosureView.swift` (new view, reached from Settings > Privacy)

**Verification before submission:** grep for raw English copy of any of the 3 short strings; if found anywhere outside the strings file, refactor to use the localized key.

---

## Lawyer review checklist (DRAFT signal — remove before publish)

- [ ] Cook Mode footer wording (5 sites' string #1) — confirm sufficient prominence
- [ ] Substitution result footer (string #2) — verify allergen-specific call-out is strong enough
- [ ] Paywall fine-print (string #3) — alignment with Apple's subscription-disclosure rules + strong-enough disclaimer
- [ ] Full disclosure screen (§3 above) — comprehensive and aligned with ToS §2 + §5; no claims that overshoot
- [ ] Localization plan — these strings live in one place; if expanding to non-English, lawyer confirms each translation

---

## Internal cross-references

- Spec §19 — Claims risk
- `docs/legal/terms-of-service.md` §2, §5
- `docs/legal/privacy-policy.md` (no direct overlap, but linked from disclosure screen)
- iOS implementation file paths above
