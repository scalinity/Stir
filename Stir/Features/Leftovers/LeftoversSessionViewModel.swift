// LeftoversSessionViewModel
//
// Drives the Leftovers follow-up flow after a Cook Mode session ended
// with `OutcomeFeedback.leftoverCount > 0`. Two-stage:
//
//   1. Prompt stage: user confirms which leftovers they have — picks
//      from pre-seeded suggestions (names pulled from the just-cooked
//      recipe + recent pantry items) and/or types custom items.
//   2. Solve stage: calls `/v1/ai/dinner-solve` with
//      `context_hint=leftovers` + `leftovers_items=[{displayName, ...}]`
//      and streams the DinnerSolveEvents into the same 3-dish shape
//      the main Solve UI renders.
//
// Trigger invariant (CLAUDE.md § "What NOT to do by default"):
// leftovers is driven EXCLUSIVELY by `OutcomeFeedback.leftoverCount > 0`.
// This VM never infers leftovers from a heuristic.
//
// Telemetry: the leftovers solve fires the SAME
// `dinner_solve_requested` / `dinner_solve_completed` events as a
// regular solve — no leftovers-specific event names (spec §15).

import Foundation
import OSLog

@Observable
@MainActor
final class LeftoversSessionViewModel: Identifiable {
    /// Two-stage machine: show the prompt to collect items, then show
    /// the solve result. A fresh instance per leftovers invocation so
    /// state doesn't leak across sessions.
    enum Stage: Equatable {
        case prompt
        case solving
        case options
        case error(code: String, message: String)
    }

    private(set) var stage: Stage = .prompt

    /// Items the user has selected/entered. Per-item portion count
    /// defaults to 1 (ingredient-granularity — "salmon, 2 portions"
    /// maps to one LeftoversItem with approximateAmountText = "2
    /// portions").
    var items: [LeftoversEntry] = []

    /// Returned dishes from the leftovers solve — max 3. Ordered by
    /// the backend (highest-fit first).
    private(set) var dishes: [DishCard] = []

    /// Metrics captured on the `done` event. Surface to caller if it
    /// wants to flag the event to ops / show a cost hint.
    private(set) var lastPromptVersion: String?

    /// SCA-56 (DB1 #11): snapshot of `selectedItems.count` at the
    /// moment `findFollowUpIdea` fires, before the user can toggle
    /// items off in the prompt UI after dishes start rendering.
    /// Telemetry on `leftovers_dish_selected.leftovers_items_count`
    /// reads this so the per-dish funnel slice reflects what the
    /// solve actually consumed, not the post-toggle state.
    private(set) var selectedItemsCountAtSolve: Int = 0

    let recipePlan: RecipePlan
    let household: HouseholdProfile
    let solveRequestID: UUID = UUID()
    /// Identifiable conformance — backed by `solveRequestID` so SwiftUI's
    /// `.fullScreenCover(item:)` keys cover presentations off the same
    /// stable handle the backend telemetry uses. Two consecutive finishes
    /// produce distinct VMs and distinct presentations.
    nonisolated var id: UUID { solveRequestID }

    private let aiDispatch: AIDispatch
    private let analytics: PostHogClient
    /// Optional entitlement service — present in production (injected by
    /// the coordinator), nil in unit tests that don't exercise the gate.
    /// findFollowUpIdea consults this for a snappy local Premium check
    /// before firing the dinner-solve request; server-side ENT-LEFTOVERS-01
    /// remains the authoritative check (SA2-3 defense-in-depth).
    private let entitlements: EntitlementService?
    /// Closure the coordinator uses to present the paywall when the
    /// client gate trips. Optional so tests can assert the call without
    /// threading through a UI layer.
    private let presentPaywall: ((PaywallTrigger) -> Void)?

    init(
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        aiDispatch: AIDispatch,
        analytics: PostHogClient = .shared,
        entitlements: EntitlementService? = nil,
        presentPaywall: ((PaywallTrigger) -> Void)? = nil,
    ) {
        self.recipePlan = recipePlan
        self.household = household
        self.aiDispatch = aiDispatch
        self.analytics = analytics
        self.entitlements = entitlements
        self.presentPaywall = presentPaywall

        // Seed item suggestions from the just-cooked recipe: each
        // ingredient becomes a pre-selected default with amount-text
        // carried through. User can toggle off items they don't have
        // leftover, adjust portions, or type custom items.
        //
        // OutcomeFeedback is NOT used to seed the list — the yield-hint
        // field (`leftoverCount`) is a serving count, not an ingredient
        // count, so it's surfaced in the prompt sheet's header but
        // doesn't shape the items array. If future work needs an
        // outcome-aware seed, re-add it as an explicit `outcomeHint:
        // OutcomeFeedback?` parameter (S19 — dropped the previous
        // `seededFrom outcome` param that was unused).
        let ings = (recipePlan.ingredients as? Set<RecipeIngredient>) ?? []
        let orderedIngs = ings.sorted { ($0.sortOrder) < ($1.sortOrder) }
        self.items = orderedIngs.compactMap { ing in
            guard let name = ing.displayName, !name.isEmpty else { return nil }
            return LeftoversEntry(
                displayName: name,
                canonicalSlug: ing.canonicalIngredientSlug,
                approximateAmountText: ing.amountText,
                isSelected: false,      // user must opt in — keeps the default list honest
            )
        }
    }

    // MARK: - User actions

    func toggle(_ entry: LeftoversEntry) {
        guard let idx = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[idx].isSelected.toggle()
    }

    func setAmount(_ amount: String, for entry: LeftoversEntry) {
        guard let idx = items.firstIndex(where: { $0.id == entry.id }) else { return }
        items[idx].approximateAmountText = amount.trimmingCharacters(in: .whitespaces).isEmpty ? nil : amount
    }

    /// SCA-56 (W1): host calls this when `createLeftoversSolveWithDish`
    /// throws so the cover stays up and the existing `.error` UI in
    /// `LeftoversSolveView` renders an actionable banner instead of
    /// the cover silently dismissing as if persistence succeeded.
    /// Re-uses the existing `(code, message)` shape so no new view
    /// surfaces are required.
    ///
    /// SCA-73: also captures the failed dish so the ErrorView's
    /// "Try again" button can re-run the same persistence attempt
    /// (most failures — Core Data lock contention, transient validation
    /// — are retry-safe). Cleared by `clearPersistenceFailure()` on
    /// retry-tap or by stage advancing past `.error`.
    func markPersistenceFailed(code: String, message: String, dish: DishCard? = nil) {
        lastFailedDish = dish
        stage = .error(code: code, message: message)
    }

    /// SCA-73: cleared from `.error` back to `.options` by the
    /// LeftoversSolveView ErrorView's Retry button immediately before
    /// the host's `onSelect` retry runs. Drops `lastFailedDish` so a
    /// second failure on the same dish (or on a different dish picked
    /// after a retry) gets a fresh attempt rather than retry-storming.
    func clearPersistenceFailure() {
        lastFailedDish = nil
        // Return to the populated dish-list so the user sees the
        // options again while persistence retries. If the solve
        // produced zero dishes (.error from `findFollowUpIdea`'s
        // empty-result path), revert to `.prompt` so the prompt
        // stage's "Find idea" CTA is reachable.
        stage = dishes.isEmpty ? .prompt : .options
    }

    /// SCA-73: dish snapshot from the last persistence failure. Nil
    /// when no failure has happened in this VM lifetime. ErrorView
    /// surfaces a Retry button only when this is non-nil.
    private(set) var lastFailedDish: DishCard?

    func addCustomItem(name: String, amount: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        items.append(LeftoversEntry(
            displayName: trimmedName,
            canonicalSlug: nil,
            approximateAmountText: amount?.trimmingCharacters(in: .whitespaces),
            isSelected: true,
        ))
    }

    /// Selected items the solve will use. Caller can check `.isEmpty`
    /// before enabling the "Find idea" button.
    var selectedItems: [LeftoversEntry] {
        items.filter(\.isSelected)
    }

    // MARK: - Solve

    /// Kick off the leftovers solve. Emits the same telemetry events as
    /// a regular dinner-solve; transitions stage: prompt → solving →
    /// options | error.
    func findFollowUpIdea() async {
        guard !selectedItems.isEmpty else { return }

        // SCA-65: a leftovers session has started — record the action +
        // cancel any pending +20h followup notification so it doesn't
        // fire later for an already-resolved cook. recordAction() before
        // cancel() so the unactioned-streak suppression math sees the
        // engagement signal even if the notification had already fired
        // and the user is acting late.
        LeftoversFollowupScheduler.shared.recordAction()
        LeftoversFollowupScheduler.shared.cancel()

        // Client-side Premium+ gate. Server-side ENT-LEFTOVERS-01 is the
        // authoritative check (handles modified clients + direct curl);
        // this snappy local check avoids the round-trip + paywall flash
        // for the common case. Nil entitlements falls through to the
        // server gate rather than fail-open.
        if let entitlements {
            switch entitlements.canAccess(.leftoversMode) {
            case .allowed:
                break
            case .blockedByTier, .blockedByBilling:
                presentPaywall?(.leftoversGate)
                stage = .prompt
                return
            case .blockedByQuota:
                // Leftovers reuses the dinner-solve quota — if that's
                // capped, surface RATE-01 paywall instead of the
                // tier paywall. canAccess for .leftoversMode currently
                // never returns blockedByQuota (see EntitlementService
                // :193), so this branch is forward-compat only.
                presentPaywall?(.dinnerSolveQuotaExhausted)
                stage = .prompt
                return
            }
        }

        stage = .solving
        // SCA-56 (DB1 #11): freeze the count at solve-start so
        // post-render item toggling can't distort
        // `leftovers_dish_selected.leftovers_items_count`.
        selectedItemsCountAtSolve = selectedItems.count

        analytics.capture(
            .dinnerSolveRequested,
            properties: StepSevenTelemetry.dinnerSolveRequested(
                contextHint: "leftovers",
                leftoversItemsCount: selectedItems.count,
            ),
        )

        let startedAt = Date()
        let request = DinnerSolveRequest(
            solveRequestID: solveRequestID,
            parseID: nil,
            ingredients: [],  // leftovers path skips pantry
            constraints: nil,
            householdContext: householdContext(),
            contextHint: .leftovers,
            leftoversItems: selectedItems.map { e in
                DinnerSolveRequest.LeftoversItem(
                    displayName: e.displayName,
                    canonicalSlug: e.canonicalSlug,
                    approximateAmountText: e.approximateAmountText,
                )
            },
            // SCA-44 / ADR 0030: leftovers path doesn't consume preference
            // memory in v1 — fans out in a follow-up alongside substitution.
            feedbackSummary: nil,
        )

        var returned: [DishCard] = []
        do {
            let stream = try await aiDispatch.dinnerSolve(request: request)
            for try await event in stream {
                switch event {
                case .dish(let dish):
                    returned.append(dish)
                    // Transition to options as soon as one dish lands so
                    // the user sees progress instead of a long spinner.
                    dishes = returned.sorted(by: { $0.rank < $1.rank })
                    if stage != .options { stage = .options }
                case .slotError:
                    // A missing slot just means we render what we have.
                    continue
                case .done(_, let cost, let dishesReturned, let retryCount, let promptVersion):
                    self.lastPromptVersion = promptVersion
                    analytics.capture(
                        .dinnerSolveCompleted,
                        properties: StepSevenTelemetry.dinnerSolveCompleted(
                            contextHint: "leftovers",
                            dishesReturned: dishesReturned,
                            totalCostUSD: cost,
                            retryCount: retryCount,
                            promptVersion: promptVersion,
                            totalLatencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                        ),
                    )
                    if returned.isEmpty {
                        stage = .error(code: "AI-02", message: "Couldn't find a follow-up idea from those leftovers. Try selecting more items.")
                    } else {
                        stage = .options
                    }
                }
            }
        } catch {
            Logger.solveFeature.error("leftovers solve failed: \(error.localizedDescription, privacy: .public)")
            stage = .error(code: "AI-01", message: "Something hiccuped. Try again in a moment.")
        }
    }

    // MARK: - Household context

    private func householdContext() -> DinnerSolveRequest.HouseholdContext {
        let rules = (household.dietaryRules as? Set<DietaryRule>)?
            .filter(\.isActive)
            .compactMap { rule -> DinnerSolveRequest.DietaryRuleLite? in
                guard let kind = rule.kind, let value = rule.value else { return nil }
                return DinnerSolveRequest.DietaryRuleLite(
                    kind: kind,
                    value: value,
                    severity: rule.severity ?? "soft",
                )
            } ?? []
        let equipment = (household.kitchenEquipment as? Set<KitchenEquipment>)?
            .filter(\.isAvailable)
            .compactMap(\.code) ?? []
        return DinnerSolveRequest.HouseholdContext(
            servings: Int(household.servingsDefault),
            dietaryRules: rules,
            availableEquipment: equipment,
        )
    }
}

// MARK: - Leftovers entry model

struct LeftoversEntry: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    var displayName: String
    var canonicalSlug: String?
    var approximateAmountText: String?
    var isSelected: Bool
}
