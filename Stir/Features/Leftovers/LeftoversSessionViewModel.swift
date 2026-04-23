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
final class LeftoversSessionViewModel {
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

    let recipePlan: RecipePlan
    let household: HouseholdProfile
    let solveRequestID: UUID = UUID()

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
        seededFrom outcome: OutcomeFeedback?,
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
        // `leftoverCount` from OutcomeFeedback is a serving count, not
        // ingredient count — it's surfaced in the prompt sheet's
        // header ("You said X servings") but doesn't shape the item
        // list directly.
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
        _ = outcome  // reserved for future "expected yield" hint; referenced to avoid unused-param warning
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
