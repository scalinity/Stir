# ADR 0039: Resolve one household graph across identity promotion and CloudKit imports

- **Status**: Accepted
- **Date**: 2026-11-06
- **Owner-step**: household persistence
- **Related**: CR1-C1, CR1-C2, CR1-S1; `HouseholdProfileRepository`, `RootCoordinator`, ADR 0005

## Context

An installation can create content before iCloud becomes available. A fresh installation can also create a household before CloudKit imports its existing household. Exact-key lookup alone strands the first graph on identity promotion and leaves the second case with multiple same-key graphs.

## Decision

- Promote household roots only when the prior identity is this installation's exact `install:` key and the next identity is `ck:`. Never combine distinct CloudKit accounts.
- For one canonical key, choose the earliest `createdAt`, then lexically smallest UUID, as the stable household root. Mutable settings never choose the root.
- Move every household-owned child relationship to that root. Keep unique child content. For logically identical dietary rules and equipment, the latest `updatedAt` wins, including inactive/unavailable states; UUID breaks ties.
- Household settings come from the most recently edited completed profile, or the most recently edited profile if none is complete. Completion is retained if any same-key profile completed onboarding. Reconciliation does not invent a new settings timestamp.
- Keep duplicate household roots as empty forwarding anchors. CloudKit can deliver their children later; deleting the roots would risk cascade deletion or orphaned late imports. Reconciliation runs at bootstrap and after the main context merges imported changes. It waits until an active cook or import presentation closes before replacing that workflow's household reference.
- Compose onboarding and import repositories from the coordinator's selected persistence controller. A ready-state transition and foreground activation share one guarded import drain so a cold-start share requires no extra foreground cycle.

## Consequences

The logical household graph is unique even when CloudKit retains multiple root records. Empty roots cost one small record per independently created household and preserve late-import routing. Revisit an explicit schema-level redirect only if measurements show root accumulation is material; do not delete anchors merely to reduce record count.

Tests cover installation promotion, separate CloudKit identities, deterministic same-key consolidation, late children, settings conflicts, and queued-share readiness. Physical-device CloudKit delivery remains a separate acceptance check from in-memory repository tests.
