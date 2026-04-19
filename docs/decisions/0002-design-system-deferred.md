# ADR 0002: Design system deferred; generic SwiftUI accepted through v1 beta

- **Status**: Deferred
- **Date**: 2026-04-19
- **Owner-step**: Step 9 (beta) — or earlier if a branding / marketing need forces it
- **Related**: FD1 review findings (step-5 review, commit `d3ab381`), `DesignSystem/` directory (currently empty scaffolding)

## Context

The step-5 review's frontend-design agent (FD1) scored Stir's UI 6/10 with a direct critique: "reads as well-built generic iOS SwiftUI with no distinct Stir visual language" — stock SF Symbols on system colors, no bespoke type pairing, no cooking-relevant warmth, no memorable visual elements. The issues span Paywall, Settings, SavedMeals, DishPreview. The fix would be a token layer (accent palette, cream surfaces, display typography, custom illustrations) threaded through the app — a design sprint, not a code review cleanup.

Stir's build order (CLAUDE.md §Build order) prioritizes proving core mechanics and economics before polish: steps 1–5 land the free-tier product + paywall; step 6 ships voice (the headline differentiator); step 7 adds widgets / shortcuts / leftovers; step 8 is telemetry + ops; step 9 is beta. Apple's App Store acceptance doesn't require a bespoke identity — Stir's paywall is HIG-compliant, a11y-acceptable, and state-complete today. But beta reviewers and early-access users will form brand impressions immediately.

## Decision

**Defer the design system.** Ship through step 8 on generic SwiftUI materials. Do NOT invest in a `DesignSystem/` token pass, custom fonts, or bespoke illustrations in the step 5–8 window.

**Trigger to revisit:** ANY of the following reopens this:

1. Step 9 beta prep begins (this is the default trigger — design work *must* precede public TestFlight).
2. Beta testers report more than 3 standalone "the app looks generic / cheap" pieces of qualitative feedback.
3. Marketing decides to run paid acquisition before beta (paid-install users judge the paywall on aesthetic; the current generic styling would cap trial-start rate).
4. A premium competitor launches in the weeknight-dinner-AI space with visibly stronger brand presence.

## Alternatives considered

- **Do it now during step 5 cleanup** — rejected: the review flagged it but the work is a design sprint (palette decisions, type pairings, possibly a visual designer), not a code fix. Scoping it into the review-fix commit would have landed superficial color tweaks that'd need ripping out during a real design pass.
- **Do it in step 6 (voice)** — rejected: step 6's risk surface is already high (Gemini Live validation gate, UX that's hardware-sensitive). Mixing design work in would entangle failure modes.
- **Do it piecemeal as features land** — rejected: token systems work by being applied uniformly. Partial adoption is worse than none (jarring inconsistency between "new-style" and "old-style" screens).

## Consequences

### Positive

- Steps 5–8 ship on schedule without a design sprint in the critical path.
- The design work, when it happens, can be scoped correctly (full audit + token layer + roll-out plan), not as a cleanup patch.
- Focus stays on mechanics + economics during the phase where those are actually at risk.

### Negative

- App looks generic during internal demos and any pre-beta investor / friend showings.
- Review feedback noting "generic" is persistent — FD1 flagged it, any future reviewer will too.
- Risk that "ship first, polish later" becomes "never polish" if beta goes well and ship pressure mounts. The trigger list above is the guard against this.

### Tradeoffs

- Aesthetic impression cost during the pre-beta window, in exchange for velocity through steps 5–8.
- Mitigations already in place:
  - Paywall copy is strong (spec §9 + CLAUDE.md); weak visuals won't fully mask the value prop.
  - Every screen has loading / empty / error states; polish is about aesthetic, not completeness.
  - HIG compliance + a11y baseline are met — this isn't a "we'll fix a11y later" situation.

## Trigger to revisit

See "Decision" section above. The default trigger is **step 9 kickoff**; the hard triggers are beta feedback signal, paid-acquisition decision, or competitive pressure.

## Notes

- FD1 score breakdown at time of deferral: Visual 5/10, Typography 7/10, Color 5/10, Layout 8/10, Animation 4/10, Consistency 6/10, A11y 7/10, Responsiveness 5/10.
- Related non-design-system fixes were NOT deferred and landed in commit `d3ab381`: star touch-target, accessibilityHidden on hero crown, restore toast animation, cancelledFooter single CTA, Free tier icon metaphor, trial disclosure heading weight, successContent padding, @ScaledMetric widths (next commit), Toast extraction (next commit), ProComparisonSheet header (next commit). Those are a11y + polish, not design-system work.
- `Stir/DesignSystem/` directory is currently empty-scaffolding (per repo layout in CLAUDE.md §Repo layout). When this decision reopens, that's the natural home for tokens.
