# ADR 0032: Allergen-regenerator botanical-safe allowlist (no template_blob bump)

- **Status**: Accepted
- **Date**: 2026-05-08
- **Owner-step**: Step 3 (post-CA2-1 follow-up)
- **Related**: SCA-150, SCA-58 (Sprint A/B/C deferred-work bundle), `_shared/hard_rules.ts` `ALLERGEN_KEYWORD_EXPANSION`, ADR 0014 (refresh-as-pruning) for "favor false positives over false negatives" stance, CLAUDE.md §"AI pipeline map" (dinner_solve hard-rule validator + retry).

## Context

CA2-1 (2026-05-04) tightened the `nut` allergen trigram to a word-boundary match so `coconut` / `butternut squash` / `nutmeg` / `donut` no longer fire as false positives on the FIRST pass. But the validator still has to be aggressive on the keywords it does match — a missed almond ships an allergen, and that bias is permanent (CLAUDE.md "favor false positives over false negatives").

When a real `nut`-keyword hit fires (`almond flour`, `cashew cream`), `dinner-solve` regenerates that slot. The regenerator's userText payload tells the model "this slot violated hard rules — produce a replacement." Empirically the model sometimes blanket-avoids ALL "*nut*" foods on the second pass, including coconut/butternut/nutmeg, even though those are botanically safe for tree-nut allergies. Result: a less creative replacement, occasionally a second `slot_hard_rule_violation` because the model now hits a different constraint trying to dodge "nuts" altogether.

The Linear ticket (SCA-150) listed two options. Option A (extend the regenerator prompt with a botanical allowlist) is what landed; Option B (widen retry from 1 to 2 attempts on allergen violations only) was rejected because it doubles regenerator-call cost without addressing the root cause (model uncertainty on what counts as a "nut").

## Decision

**Append a botanical-safety clause to the regenerator's userText whenever the slot's violations include a `kind: 'allergen'` issue with `value` in `{nut, tree_nut, peanut}`.** The clause names coconut, butternut squash, and nutmeg as botanically NOT tree nuts — safe for tree-nut/peanut allergies — while explicitly keeping pine nut on the avoid-list because of cross-reactivity in tree-nut-allergic users (Roux 2003, Cabanillas 2015 — included in code comment for future maintainers).

Implementation:
- New constant `ALLERGEN_BOTANICAL_SAFE_NOTES` in `_shared/hard_rules.ts` exposes the per-allergen-value note string.
- New exported pure helper `buildReplacementUserText(rank, violations)` in `dinner-solve/index.ts` composes the userText. The botanical clause is appended ONCE per call regardless of how many ingredient violations triggered the same allergen value (Set-based dedupe).
- `requestReplacementDish` now consumes `ValidationIssue[]` instead of `unknown[]` and calls the helper.
- 8 unit tests in `tests/dinner_solve_replacement_user_text_test.ts` pin the dedupe + per-allergen behavior without mocking Gemini.

The validator itself is **NOT loosened** — coconut etc. still trigger the FIRST-pass keyword match if the matcher's word-boundary rules ever drift. The clause only helps the SECOND-pass replacement reason about what "no nuts" actually means.

## Alternatives considered

- **Option B — widen retry from 1 to 2 attempts on allergen violations only** — Rejected. Doubles regenerator cost on the worst-case path without giving the model better information; the second retry has the same prompt as the first, so no reason to expect a better outcome. Cost impact is non-trivial: at the post-beta `slot_hard_rule_violation` rate this would add ~0.3¢/solve in the affected cohort, vs Option A's ~0.0¢ (a few extra prompt tokens on the regenerator call only).
- **Loosen the validator (drop `coconut` / `nutmeg` from the keyword expansion)** — Rejected explicitly. SAFETY: missing a real almond ships an allergen. Aggressive false-positive bias is the right place to be. CA2-1's word-boundary fix already handles the safe-name false positives at first-pass; this ADR addresses the regenerator second-pass behavior that CA2-1 didn't touch.
- **Bump `prompt_versions.version` to v2.2.0 with the same `template_blob` as v2.1.0** — Rejected. The system-prompt template is unchanged; the behavioral change is in the regenerator's userText (code, not template). A version bump with identical template_blob would (a) confuse future readers reading `prompt_versions.template_blob` history, and (b) imply gating that doesn't exist (the new clause fires for 100% of allergen-violation regenerator calls, not the rollout_pct of v2.2.0). If a future template-blob change wants to absorb this clause INTO the system prompt, it can bump to v2.2.0 then; the regenerator userText change is documented here as the surface that ships the clause today.
- **Add a feature flag `regenerator_botanical_allowlist_enabled`** — Rejected. The change is reasoning-additive (gives the model MORE accurate information). There's no realistic kill-switch scenario; if the clause regresses the model's behavior, fix the wording in code rather than flag-flip in production.

## Consequences

### Positive

- The model gets accurate botanical taxonomy on the regenerator pass for the most common false-positive failure mode (`nut`-keyword matches on actually-safe coconut/butternut/nutmeg).
- The validator's safety bias is preserved — nothing about the validation logic changes; the new clause is purely advisory at the model layer.
- Pure, exported `buildReplacementUserText` helper is unit-testable without spinning up Gemini mocks.
- Pine nut warning is encoded explicitly so the clause doesn't accidentally license the model to use pine nut for nut-allergic users (a real cross-reactivity hazard).

### Negative

- The regenerator userText grows by ~80 tokens on allergen-violation paths. At post-beta `slot_hard_rule_violation` rates this is in the noise (≪ 1¢/day on Free, even less per-tier).
- Pine nut's cross-reactivity science is still settling. The clause's guidance to "treat pine nut AS a tree nut" matches current AAAAI / ACAAI conservative practice but may need revision if research consensus shifts.

### Tradeoffs

- We pay a small per-regenerator-call token cost in exchange for less re-violation churn on the second pass. Worth it: the alternative (Option B's double-retry) was 2-4× more expensive.

## Trigger to revisit

Reopen this ADR if any of:

1. **Pine nut science shifts.** If AAAAI / ACAAI guidance updates to declare pine nut routinely safe for tree-nut allergic users, the clause's pine-nut warning becomes a dated false-restriction. Update wording + cite the new guidance.
2. **`slot_hard_rule_violation` rate post-beta still > 5% and `replacement_also_invalid` rate within that > 30%.** If regenerator-pass failure remains high, the clause isn't doing enough — either escalate to Option B (extra retry attempt), expand the botanical-safe table to additional allergens, or revisit the validator's matcher semantics.
3. **A future system-prompt template change** wants to absorb the botanical guidance into the template_blob itself (e.g. as part of a broader "model reasoning hints" section). At that point, the regenerator userText clause should be removed in the same migration that lands the new template — the constants in `hard_rules.ts` can stay for any future regenerator-only paths.
4. **Allergen kinds beyond nut/tree_nut/peanut hit similar false-positive issues post-beta.** The `ALLERGEN_BOTANICAL_SAFE_NOTES` table is the extension point: add new entries for soy, gluten, etc. as needed without re-architecting.

## Notes

- The clause sits AFTER the standard "violated hard rules" + "produce ONE replacement" instructions in the userText, on its own paragraph, so the model never reads it in isolation. Test `nut allergen: appends the botanical clause` in `dinner_solve_replacement_user_text_test.ts` pins this ordering.
- We did NOT add a golden integration test against a real Gemini model (the Linear ticket's "golden-test fixture confirms coconut-with-nut-allergy doesn't re-trigger violations" criterion). Reason: integration tests against `STIR_RUN_AI_INTEGRATION_TESTS=1` are flaky-by-vendor and the cost is real (~$0.005/run × N CI runs). The unit tests pin the userText shape, which is the deterministic part; the model's actual response is part of the "measure post-beta" gate documented in the SCA-150 ticket. If Daniel wants the model-level golden test, file as a follow-up under SCA-58.
