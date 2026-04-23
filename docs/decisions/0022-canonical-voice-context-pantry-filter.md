# ADR 0022: Canonical voice-context pantry filter — `userConfirmed && !deletedAt && !displayName.isEmpty`

- **Status**: Accepted
- **Date**: 2026-04-23
- **Owner-step**: Step 6 (voice)
- **Related**: P2-I / CR1-W5 from step-6 review 2026-04-23; `HouseholdProfile.voiceContextSnapshot`; `VoiceContextSnapshot`; `RealtimeHouseholdContext(snapshot:)`; `SubstitutionRequest.HouseholdContext(snapshot:)`; CLAUDE.md north-star #5 (hard-rule validator invariant); ADR 0020 (mint-path TTL cache)

## Context

Before this ADR, three separate call sites projected `HouseholdProfile.pantryItems` for the voice path — each with its own filter:

| Site | Filter |
|---|---|
| `CookModeViewModel.buildRealtimeHouseholdContext` (mint context) | `deletedAt == nil && userConfirmed` |
| `RealtimeSession.buildHouseholdContext` (mint context) | `deletedAt == nil && userConfirmed` |
| `RealtimeSession.dispatchSubstitution` (substitution round-trip) | `!displayName.isEmpty` (no user-confirmed check) |

The substitution path accepted pantry items that had been scanned but not confirmed — a drift that could surface unconfirmed items to the hard-rule substitution validator. Correctness gap: CLAUDE.md north-star #5 requires hard-rule validator gets all safety-relevant pantry context, and unconfirmed items are neither reliably safe nor reliably labeled.

## Decision

A pantry item is included in voice context if and only if:

1. `userConfirmed == true`, AND
2. `deletedAt == nil`, AND
3. `displayName` is non-empty.

This rule is encoded once, in `HouseholdProfile.voiceContextSnapshot()`, as a single immutable `VoiceContextSnapshot` value. All three consumer sites (mint-context in VM, mint-context in RealtimeSession, substitution round-trip) convert from the snapshot via DTO initializers (`RealtimeHouseholdContext(snapshot:)`, `SubstitutionRequest.HouseholdContext(snapshot:)`). Filter drift is no longer expressible at the call site.

## Alternatives considered

- **Make substitution permissive (match prior behavior), validate fresh on backend** — Rejected: doubles server-side validation cost on every substitution and doesn't remove the root-cause filter drift in iOS.
- **Filter at the Core Data fetch predicate level** — Rejected: Core Data predicates on NSSet-relationship filtering are fragile (`userConfirmed` is scalar); an in-memory filter in Swift is clearer and easier to evolve.
- **Accept the drift; document "unconfirmed items may surface to substitution"** — Rejected: silent drift is the class of issue this review surfaced, and the fix is cheap.

## Consequences

### Positive

- Hard-rule validator sees a consistent pantry view regardless of code path.
- Three drifting filters collapse to one rule in one method with one test surface.
- `VoiceContextSnapshot` is a Sendable value-type seam — any future voice-path consumer (Speech fallback, future tool calls) inherits the same filter by construction.

### Negative

- Users with a lot of scanned-but-unconfirmed pantry items will see fewer substitution suggestions referring to them. Acceptable because unconfirmed items have uncertain canonical slugs and skipping them reduces false-substitution risk.
- Adds one indirection layer between Core Data types and DTOs. Small; the DTOs already were value types.

### Tradeoffs

Correctness of the hard-rule validator path > breadth of pantry coverage in substitution. Users can confirm items via the pantry sheet to bring them into substitution scope.

## Notes

- `VoiceContextSnapshot` lives on `HouseholdProfile+Extensions.swift` to keep the canonical projection next to the source data.
- Rule is ENFORCED at construction (private `insertTurn` / init chain); no public API accepts a snapshot bypassing the filter.
- Tests: the three DTO initializers (`RealtimeHouseholdContext(snapshot:)`, `SubstitutionRequest.HouseholdContext(snapshot:)`) can be exercised directly against a mock snapshot without Core Data.
