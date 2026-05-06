# ADR 0029: Auto-consume pantry items on cook completion

- **Status**: Accepted
- **Date**: 2026-05-06
- **Owner-step**: standing
- **Related**: ADR 0028 (pantry surface), CLAUDE.md §AI pipeline map, `CookModeViewModel.performFinish`, `PantryItemRepository.upsertFromScan`, SCA-21 through SCA-27

## Context

The pantry shipped in step 4 (ADR 0028) as a write-only log: scan / manual adds rows, swipe deletes them, nothing else mutates. Cooking a dish never touches the pantry, so a user who scans 6 items, picks a dish, and cooks it sees the same 6 items in the pantry tomorrow. This pollutes every downstream AI surface that reads pantry — dinner-solve (`SolveViewModel.toPantrySnapshot`), substitution (`SubstitutionSheetViewModel:349`), voice Cook Mode (`RealtimeSession.swift:3352`) — each reads a snapshot that diverges further from reality with every cook. The user (Daniel) has flagged this as the most fundamental gap in the pantry feature.

A confirmation prompt at end-of-cook ("Mark which items you used") was rejected: friction at the most cognitively-fatigued moment of the flow (just finished cooking, ready to eat). The required information — what the recipe consumed — is already known structurally from `RecipePlan.ingredientArray` plus `CookingSession.substitutionArray`.

## Decision

Auto-consume the recipe's effective ingredients on cook completion, with a memory-state-aware rule that's destructive only on the items most likely to actually be consumed:

1. On `CookModeViewModel.performFinish` (after `cookingSessionRepository.markCompleted`, before `cookSessionCompleted` telemetry), invoke a new `PantryItemRepository.consumeForRecipe(_:substitutions:on:)`.
2. Build the **effective ingredient list** from the recipe: skip `isOptional`, and for any `RecipeIngredient` with an accepted `SubstitutionEvent` use the swap (`event.acceptedAlternativeText`, slug=nil) instead of the original.
3. For each effective ingredient, look up a pantry row via the existing `fetchExisting(slug:displayName:)` (slug-then-case-insensitive-name).
4. Apply the rule:
   - matched + `.ephemeral` → soft-delete (recipe consumed a today-only thing)
   - matched + `.remembered` → bump `lastSeenAt` (standing items aren't depleted by one cook; recency improves downstream voice prompt prioritization)
   - matched + `.expired` or `.unknown` → leave alone (state is suspect; SCA-22's `expiresAt` sweep should be the only writer for those transitions)
   - no match → no-op
5. Emit `pantry_auto_consume_resolved { ephemeral_deleted, remembered_bumped, unmatched, optional_skipped, substituted_count }`. Counts only, never ingredient names (privacy invariant — ADR 0009).
6. Surface a passive `.info` toast iff `ephemeral_deleted > 0`: "Pantry updated · N items used". No action affordance in v1 — see SCA-27 for the deferred undo path.

The conservative `.ephemeral`-only delete rule is the safety mechanism that lets us skip both the upfront prompt and the v1 undo: standing pantry items are never destructively mutated, so the worst case is one ephemeral row deleted that the user actually still has. They can re-add manually; the loss is bounded.

## Alternatives considered

- **Confirmation sheet at end-of-cook** — show "Mark items used" with checkboxes. Rejected: friction at the most fatigued moment of the flow; the structural data already implies the answer.
- **Auto-consume everything (delete `.remembered` too)** — Rejected: standing items (oil, salt, butter, flour) appear in 90%+ of recipes. Deleting them re-creates the empty-pantry problem within one cook. The standing/today distinction the data model already carries is the right axis.
- **Quantity-aware partial decrement** — recipe says "2 tbsp olive oil"; pantry says "1 jar". Rejected: `amountText` is free-form ("a few slices", "almost gone"), `normalizedAmount` is reliably populated only on AI-generated recipes (not imports). Quantity math is brittle and the wrong precision for the problem; binary "used or not" mapped to memory-state captures ~95% of cases honestly without a partial-use UI.
- **Server-side consume** — fire a webhook to Supabase, reconcile there. Rejected: pantry lives in CloudKit (CLAUDE.md invariant 3); the source of truth is on-device, and a server round-trip introduces a CloudKit-vs-Postgres consistency surface for no benefit.
- **Undo affordance in v1** — extend `StirToast` with an action button so the toast carries an "Undo" tap. Deferred to SCA-27: the conservative match rule (ephemeral-only delete) bounds the recovery cost; ship without it and revisit if telemetry or field reports surface real friction.

## Consequences

### Positive

- Pantry reflects reality after every cook. Dinner-solve, substitution, and voice Cook Mode all read a fresher snapshot.
- Zero added friction at session-end. The existing `cookSessionCompleted` trigger is the only hook; the toast is glanceable, not interruptive, and only appears when something was deleted.
- Bumping `lastSeenAt` on `.remembered` items improves voice Cook Mode prompt prioritization (the up-to-1000-item walk uses recency).
- Substitution events feed back into pantry state, closing a loop that was previously open.

### Negative

- Ephemeral rows get destructively mutated without an undo. Mitigated by the conservative match rule + manual re-add path. SCA-27 tracks the recovery-affordance follow-up.
- A recipe import with empty slugs and a name-fallback collision could delete the wrong `.ephemeral` row. Bounded but real; the ephemeral-only rule keeps blast radius small.
- One more code path writes to `PantryItem`. The repository now has three writers — scan upsert, manual insert, and recipe consume — each with subtly different cap/dedupe semantics. Test surface expands.

### Tradeoffs

- The standing/today axis is the cheapest way to model "depletes per cook" without quantity arithmetic. It's wrong some of the time (a `.ephemeral` row survives a cook because the user didn't use it all), but right ~95% of the time, which is far better than the current 0%. We trade residual error against not shipping a partial-use UI.

## Trigger to revisit (Deferred only)

N/A — Accepted. Trigger to **escalate** the matching rule (not the decision itself): if `pantry_auto_consume_resolved.unmatched / (ephemeral_deleted + remembered_bumped + unmatched) > 0.5` for a two-week window, the matcher needs hardening — likely SCA-26's name normalization (singular/plural, lowercase) or a tie-in to the IngredientCanonical bundled asset.

## Notes

- **Telemetry registration** lands in the same PR as the implementation: `pantry_auto_consume_resolved` is added to spec §15 + CLAUDE.md §Telemetry events.
- **Voice Cook Mode** uses the same `performFinish` exit path, so the consume fires for both tap and voice sessions without separate wiring.
- **Abandon-vs-finish discrimination** is already handled: `exit(markAbandoned:)` and `performFinish` are distinct paths in `CookModeViewModel`. The consume hook only fires from `performFinish`.
- **CloudKit replication** is automatic — `softDelete` and `lastSeenAt` writes propagate via `NSPersistentCloudKitContainer` (CLAUDE.md §Stack snapshot).
