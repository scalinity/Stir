// SolveViewModel
//
// Drives the constraints → solve → options → preview state machine.
// Consumes the AsyncThrowingStream<DinnerSolveEvent, Error> from AIDispatch,
// accumulating .dish / .slotError / .done events into renderable state.
//
// Persistence: once the stream emits .done, we commit the complete solve
// to CloudKit via SolveRepository (MealSolveRequest + SuggestedDish[] +
// RecipePlan[] + ingredients + steps) in ONE viewContext save.

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SolveViewModel {
    enum Phase: Sendable, Equatable {
        case idle
        case constraints
        case solving
        case options
        case error(message: String, code: String)
    }

    struct ConstraintsInput: Sendable, Equatable {
        var maxTimeMinutes: Int?
        var cuisineLeaning: String?
        var useFirst: [String] = []
        var avoidEquipment: [String] = []
        var goal: String?

        /// True when the user has expressed at least one explicit
        /// preference. Used to decide whether to attach the constraints
        /// block to the request and Core Data record.
        var hasAnyValue: Bool {
            maxTimeMinutes != nil
                || cuisineLeaning != nil
                || !useFirst.isEmpty
                || !avoidEquipment.isEmpty
                || goal != nil
        }
    }

    struct SlotState: Identifiable, Sendable, Equatable {
        let rank: Int
        var dish: DishCard?
        var errorCode: ErrorCode?
        var id: Int { rank }
    }

    private(set) var phase: Phase = .idle
    /// Always size 3 — slots filled in rank order as the stream emits.
    private(set) var slots: [SlotState] = [
        SlotState(rank: 1), SlotState(rank: 2), SlotState(rank: 3),
    ]
    private(set) var selectedDish: DishCard?
    private(set) var lastCostUSD: Double?
    private(set) var lastLatencyMS: Int?
    private(set) var lastPromptVersion: String?
    private(set) var persistedSolveID: UUID?
    private(set) var persistedSuggestedDishIDs: [UUID] = []

    var constraints = ConstraintsInput()
    private(set) var ingredientsForSolve: [DinnerSolveRequest.IngredientLite] = []
    private(set) var parseIDForSolve: UUID?

    private let aiDispatch: AIDispatch
    private let solveRepo: SolveRepository
    private let householdStore: CurrentHouseholdStore
    private var streamTask: Task<Void, Never>?

    init(
        aiDispatch: AIDispatch,
        solveRepo: SolveRepository,
        householdStore: CurrentHouseholdStore,
    ) {
        self.aiDispatch = aiDispatch
        self.solveRepo = solveRepo
        self.householdStore = householdStore
    }

    // MARK: - Flow entry

    func prepare(
        with ingredients: [DinnerSolveRequest.IngredientLite],
        parseID: UUID? = nil,
    ) {
        // Cancel any in-flight stream from a prior solve. Without this,
        // late .dish events from the old stream land in the reset slots
        // array (CA2-3).
        streamTask?.cancel()
        streamTask = nil
        self.ingredientsForSolve = ingredients
        self.parseIDForSolve = parseID
        self.phase = .constraints
        self.slots = [SlotState(rank: 1), SlotState(rank: 2), SlotState(rank: 3)]
        self.selectedDish = nil
        self.lastCostUSD = nil
        self.lastLatencyMS = nil
        self.lastPromptVersion = nil
        self.persistedSolveID = nil
        self.persistedSuggestedDishIDs = []
    }

    /// Spawn the AIDispatch stream. ConstraintsSheet calls this on "Solve".
    func startSolve() {
        guard let household = householdStore.profile else {
            phase = .error(message: "Household profile missing.", code: "VAL-01")
            return
        }
        let request = buildRequest(household: household)

        PostHogClient.shared.capture(.dinnerSolveRequested, properties: [
            "constraints_max_time": constraints.maxTimeMinutes ?? -1,
            "constraints_cuisine": constraints.cuisineLeaning ?? "",
            "constraints_use_first_count": constraints.useFirst.count,
            "ingredient_count": ingredientsForSolve.count,
            "dietary_rule_count": request.householdContext.dietaryRules.count,
        ])

        phase = .solving
        let started = Date()

        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self, aiDispatch] in
            guard let self else { return }
            let stream = await aiDispatch.dinnerSolve(request: request)
            do {
                for try await event in stream {
                    self.handle(event, startedAt: started)
                }
            } catch StirError.rateLimited(_, let message) {
                self.phase = .error(message: message, code: "RATE-01")
                Self.emitSolveFailed(code: "RATE-01")
            } catch StirError.entitlementRequired(let code, let message) {
                self.phase = .error(message: message, code: code.rawValue)
                Self.emitSolveFailed(code: code.rawValue)
            } catch StirError.server(let code, let message, _) {
                self.phase = .error(message: message, code: code.rawValue)
                Self.emitSolveFailed(code: code.rawValue)
            } catch {
                self.phase = .error(
                    message: "Dinner planning is temporarily unavailable. Try again shortly.",
                    code: "AI-01",
                )
                Logger.solveFeature.error("solve stream failed: \(error.localizedDescription, privacy: .public)")
                Self.emitSolveFailed(code: "AI-01")
            }
        }
    }

    // MARK: - Stream event handling

    private func handle(_ event: DinnerSolveEvent, startedAt: Date) {
        switch event {
        case .dish(let dish):
            if let idx = slots.firstIndex(where: { $0.rank == dish.rank }) {
                slots[idx].dish = dish
                slots[idx].errorCode = nil
            }
            if phase == .solving {
                phase = .options
            }
        case .slotError(let rank, let code):
            if let idx = slots.firstIndex(where: { $0.rank == rank }) {
                slots[idx].errorCode = code
            }
        case .done(_, let cost, let dishesReturned, let retryCount, let promptVersion):
            self.lastCostUSD = cost
            self.lastLatencyMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            self.lastPromptVersion = promptVersion
            PostHogClient.shared.capture(.dinnerSolveCompleted, properties: [
                "dishes_returned": dishesReturned,
                "total_cost_usd": cost,
                "retry_count": retryCount,
                "prompt_version": promptVersion,
                "total_latency_ms": lastLatencyMS ?? 0,
                "any_hard_rule_violations": slots.contains { $0.errorCode != nil },
            ])
            // Persist to CloudKit now that we have the full result.
            persistCompletedSolve()
            if dishesReturned == 0 {
                phase = .error(
                    message: "Couldn't find three dishes with those constraints. Try relaxing one.",
                    code: "AI-02",
                )
            } else {
                phase = .options
            }
        }
    }

    // MARK: - Persistence

    private func persistCompletedSolve() {
        guard let household = householdStore.profile else { return }
        let dishInputs: [SolveRepository.DishInput] = slots.compactMap { slot in
            guard let d = slot.dish else { return nil }
            return SolveRepository.DishInput(
                rank: d.rank,
                title: d.title,
                summary: d.whyItFits,
                totalTimeMinutes: d.totalTimeMinutes,
                fitLabelPrimary: SuggestedDish.FitLabel(rawValue: d.fitLabelPrimary) ?? .bestFit,
                fitLabelSecondary: d.fitLabelSecondary.flatMap(SuggestedDish.FitLabel.init(rawValue:)),
                missingIngredientCount: d.missingIngredientCount,
                hardConstraintPass: d.hardConstraintPass,
                reasoningSummary: d.reasoningSummary,
                confidence: d.hardConstraintPass ? 0.9 : 0.5,
                recipePlan: SolveRepository.RecipePlanInput(
                    title: d.title,
                    summary: d.whyItFits,
                    servings: d.recipePlan.servings,
                    difficulty: d.recipePlan.difficulty,
                    estimatedMinutes: d.totalTimeMinutes,
                    cuisine: d.recipePlan.cuisine,
                    // Prefer the prompt version the backend actually ran
                    // (from the .done event) over a hardcoded fallback.
                    aiVersion: lastPromptVersion ?? "unknown",
                    ingredients: d.recipePlan.ingredients.map { ing in
                        SolveRepository.IngredientInput(
                            displayName: ing.displayName,
                            canonicalSlug: ing.canonicalSlug,
                            amountText: ing.amountText,
                            isOptional: ing.isOptional ?? false,
                        )
                    },
                    steps: d.recipePlan.steps.map { step in
                        SolveRepository.StepInput(
                            stepNumber: step.stepNumber,
                            instructionText: step.instructionText,
                            timerSeconds: step.timerSeconds,
                            cautionTags: step.cautionTags ?? [],
                        )
                    },
                ),
            )
        }
        do {
            let outcome = try solveRepo.createSolveWithDishes(
                on: household,
                constraints: toCoreDataConstraints(),
                pantrySnapshot: toPantrySnapshot(),
                dishes: dishInputs,
                aiRequestId: nil,
            )
            self.persistedSolveID = outcome.solveRequestId
            self.persistedSuggestedDishIDs = outcome.suggestedDishIds
        } catch {
            Logger.solveFeature.error("persist solve failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Selection

    func selectDish(_ dish: DishCard) {
        selectedDish = dish
        PostHogClient.shared.capture(.suggestedDishSelected, properties: [
            "rank": dish.rank,
            "fit_label_primary": dish.fitLabelPrimary,
        ])
    }

    /// Look up the persisted RecipePlan for a DishCard the user has seen
    /// in the options grid. Uses the rank → persistedSuggestedDishIDs
    /// mapping populated by persistCompletedSolve (sorted by rank). Nil
    /// if persistence hasn't completed yet or the dish row is gone.
    func persistedRecipePlan(for dish: DishCard) -> RecipePlan? {
        let idx = dish.rank - 1  // ranks are 1-based
        guard idx >= 0, idx < persistedSuggestedDishIDs.count else { return nil }
        return solveRepo.fetchRecipePlan(forSuggestedDishId: persistedSuggestedDishIDs[idx])
    }

    /// Current household — exposed for Cook Mode entry which needs the
    /// profile for CookingSession's household FK. Nil during a cold
    /// launch before CurrentHouseholdStore has resolved.
    var currentHousehold: HouseholdProfile? { householdStore.profile }

    /// Toggle favorite on a persisted RecipePlan. Delegates to SolveRepository;
    /// called from DishPreviewView's favorite tap after the FeatureGate
    /// check clears. Silent on Core Data save failure (logged).
    @discardableResult
    func setFavorite(_ newValue: Bool, for plan: RecipePlan) -> Bool {
        solveRepo.setFavorite(newValue, on: plan)
    }

    /// Single emission point for `ai_request_failed` on the solve path.
    /// Extracted from three inline copies in the catch arms so the property
    /// shape (`{ code, feature: "dinner_solve" }`) lives in one place —
    /// drift in one arm would silently misattribute the funnel bucket.
    private static func emitSolveFailed(code: String) {
        PostHogClient.shared.capture(
            .aiRequestFailed,
            properties: ["code": code, "feature": "dinner_solve"],
        )
    }

    /// AIDispatch passthrough so Cook Mode + Substitution Sheet can call
    /// /v1/ai/substitution without re-building a separate client. Same
    /// actor instance RootCoordinator owns.
    var dispatch: AIDispatch { aiDispatch }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Helpers

    private func buildRequest(household: HouseholdProfile) -> DinnerSolveRequest {
        let dietaryRules: [DinnerSolveRequest.DietaryRuleLite] = household.dietaryRuleArray
            .filter { $0.isActive }
            .compactMap { rule in
                guard let kind = rule.kind, let value = rule.value else { return nil }
                return DinnerSolveRequest.DietaryRuleLite(
                    kind: kind,
                    value: value,
                    severity: rule.severity ?? "soft",
                )
            }
        let availableEquipment = household.kitchenEquipmentArray
            .filter { $0.isAvailable }
            .compactMap { $0.code }

        let constraintsWire: DinnerSolveRequest.Constraints?
        if constraints.hasAnyValue {
            constraintsWire = DinnerSolveRequest.Constraints(
                maxTimeMinutes: constraints.maxTimeMinutes,
                cuisineLeaning: constraints.cuisineLeaning,
                useFirst: constraints.useFirst.isEmpty ? nil : constraints.useFirst,
                avoidEquipment: constraints.avoidEquipment.isEmpty ? nil : constraints.avoidEquipment,
                goal: constraints.goal,
            )
        } else {
            constraintsWire = nil
        }

        return DinnerSolveRequest(
            solveRequestID: UUID(),
            parseID: parseIDForSolve,
            ingredients: ingredientsForSolve,
            constraints: constraintsWire,
            householdContext: DinnerSolveRequest.HouseholdContext(
                servings: Int(household.servingsDefault),
                dietaryRules: dietaryRules,
                availableEquipment: availableEquipment,
            ),
            contextHint: nil,
            leftoversItems: nil,
        )
    }

    private func toCoreDataConstraints() -> MealSolveRequest.Constraints? {
        guard constraints.hasAnyValue else { return nil }
        return MealSolveRequest.Constraints(
            maxTimeMinutes: constraints.maxTimeMinutes,
            cuisineLeaning: constraints.cuisineLeaning,
            useFirst: constraints.useFirst.isEmpty ? nil : constraints.useFirst,
            avoidEquipment: constraints.avoidEquipment.isEmpty ? nil : constraints.avoidEquipment,
            goal: constraints.goal,
        )
    }

    private func toPantrySnapshot() -> MealSolveRequest.PantrySnapshot {
        MealSolveRequest.PantrySnapshot(
            ingredients: ingredientsForSolve.map { ing in
                MealSolveRequest.PantrySnapshot.Ingredient(
                    displayName: ing.displayName,
                    canonicalSlug: ing.canonicalSlug,
                    amountText: ing.amountText,
                )
            },
        )
    }
}

extension Logger {
    static let solveFeature = Logger(subsystem: "com.scalinity.stir", category: "SolveFeature")
}
