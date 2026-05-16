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

    /// Intentionally internal — DishPreviewView needs an AIDispatch
    /// handle to instantiate GroceryViewModel for the "Add to grocery"
    /// action. The SolveVM is the single AIDispatch owner in the Solve
    /// feature; exposing it here avoids threading a separate AIDispatch
    /// through every DishPreviewView caller.
    let aiDispatch: AIDispatch
    private let solveRepo: SolveRepository
    private let householdStore: CurrentHouseholdStore
    /// SCA-44: builder for the on-device preference-memory digest sent
    /// as `feedback_summary` on the dinner-solve request body. Best-
    /// effort — `buildDigest(for:)` returns nil on CoreData read
    /// failure or when no rated meals fall within the tier window, and
    /// the solve proceeds without feedback context (the prompt
    /// template treats missing feedback as "no signal" rather than
    /// "negative signal").
    private let preferenceMemoryService: PreferenceMemoryService
    /// Paywall presentation hook injected at construction by ScanFlowRoot.
    /// Invoked on RATE-01 so the Dinner-Solve-quota-exhausted user sees
    /// the paywall instead of a silent error screen — and so
    /// `paywall_viewed.trigger = dinner_solve_quota_exhausted` actually
    /// fires (was missing from 48h probe; spec §15 declared but unwired).
    private let presentPaywall: ((PaywallTrigger) -> Void)?
    private var streamTask: Task<Void, Never>?

    init(
        aiDispatch: AIDispatch,
        solveRepo: SolveRepository,
        householdStore: CurrentHouseholdStore,
        entitlements: EntitlementService,
        presentPaywall: ((PaywallTrigger) -> Void)? = nil,
        preferenceMemoryService: PreferenceMemoryService? = nil,
    ) {
        self.aiDispatch = aiDispatch
        self.solveRepo = solveRepo
        self.householdStore = householdStore
        self.preferenceMemoryService = preferenceMemoryService
            ?? PreferenceMemoryService(entitlementService: entitlements)
        self.presentPaywall = presentPaywall
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

    /// Prime the VM from already-persisted dishes (no AI spend, no
    /// stream). Used by `OtherOptionsRoot` to mount `DishPreviewView`
    /// against the alternates from a previously-completed solve.
    ///
    /// Sets `phase = .options` directly — `DinnerOptionsView`'s
    /// `.task(id:)` only auto-solves when phase is `.constraints`, so
    /// this seed cannot accidentally re-issue the dinner-solve request.
    ///
    /// Rank alignment matters: `persistedRecipePlan(for:)` looks up the
    /// dish-id by `dish.rank - 1` index. We pad both arrays to length 3
    /// so a tap on a rank-3 card always resolves to the rank-3 UUID
    /// even if rank-2 is missing (corner case: that dish's RecipePlan
    /// was soft-deleted between persistence and seed). Empty slots
    /// fill with a fresh placeholder UUID that resolves to `nil` via
    /// `fetchRecipePlan` — tapping such a slot can't happen because
    /// OtherOptionsRoot only renders cards that came in via `inputs`.
    func seedFromPersistedSolve(
        inputs: [(rank: Int, card: DishCard, dishId: UUID)],
    ) {
        streamTask?.cancel()
        streamTask = nil
        // `uniquingKeysWith: first` (not `uniqueKeysWithValues:`) so a
        // CloudKit-conflict-induced duplicate-rank in Core Data does not
        // fatalError on the user — first occurrence wins, drift is
        // logged below for triage rather than crashing.
        let byRank = Dictionary(inputs.map { ($0.rank, $0) }, uniquingKeysWith: { first, _ in first })
        let ranks = [1, 2, 3]
        self.slots = ranks.map { rank in
            SlotState(rank: rank, dish: byRank[rank]?.card, errorCode: nil)
        }
        self.persistedSuggestedDishIDs = ranks.map { rank in
            // Placeholder UUID for missing ranks — preserves positional
            // alignment so `persistedRecipePlan(for:)` (which indexes
            // by `dish.rank - 1`) resolves correctly for the ranks
            // that DID seed. The placeholder won't match any row in
            // fetchRecipePlan; tap on a missing-rank slot becomes a
            // silent no-op in DishPreviewView (already error-toasted).
            byRank[rank]?.dishId ?? UUID()
        }
        // Single summary log per seed — gives triage signal (which
        // ranks landed, how many duplicates dropped) without spamming
        // one line per missing rank.
        let seededRanks = ranks.filter { byRank[$0] != nil }
        let missingRanks = ranks.filter { byRank[$0] == nil }
        let droppedDuplicates = inputs.count - byRank.count
        if !missingRanks.isEmpty || droppedDuplicates > 0 {
            Logger.solveFeature.debug(
                "solve_vm_seed_summary input_count=\(inputs.count, privacy: .public) seeded_ranks=\(seededRanks, privacy: .public) missing_ranks=\(missingRanks, privacy: .public) dropped_duplicates=\(droppedDuplicates, privacy: .public)",
            )
        }
        self.phase = .options
        self.selectedDish = nil
        self.lastCostUSD = nil
        self.lastLatencyMS = nil
        self.lastPromptVersion = nil
        self.persistedSolveID = nil
    }

    /// Spawn the AIDispatch stream. ConstraintsSheet calls this on "Solve".
    func startSolve() {
        guard !ingredientsForSolve.isEmpty else {
            phase = .error(message: "Add at least one ingredient to get dinner options.", code: "VAL-01")
            Self.emitSolveFailed(code: "VAL-01")
            return
        }

        guard let household = householdStore.profile else {
            phase = .error(message: "Household profile missing.", code: "VAL-01")
            return
        }
        let request = buildRequest(household: household)

        // Privacy posture (ADR 0009): no user content to PostHog. The
        // `cuisineLeaning` field is a free-text TextField — we flag
        // presence only, never the raw string. Mirrors the
        // `has_cuisine: Bool` shape already used at
        // ConstraintsSheet.commit() for the `constraints_set` event.
        // SCA-44: `feedback_summary_present` + `recent_meal_count` so
        // the funnel can split conversion by whether the preference-
        // memory loop actually had data to feed in. Spec §15.
        PostHogClient.shared.capture(.dinnerSolveRequested, properties: [
            "constraints_max_time": constraints.maxTimeMinutes ?? -1,
            "has_cuisine": constraints.cuisineLeaning != nil,
            "constraints_use_first_count": constraints.useFirst.count,
            "ingredient_count": ingredientsForSolve.count,
            "dietary_rule_count": request.householdContext.dietaryRules.count,
            "feedback_summary_present": request.feedbackSummary != nil,
            "recent_meal_count": request.feedbackSummary?.recentMealCount ?? 0,
        ])

        phase = .solving
        // Reset slots so re-solve flows (Tune-from-options, "Try
        // again" from the error banner) show skeletons while the new
        // stream is in flight rather than the previous solve's stale
        // cards. The first-solve path arrives here with already-empty
        // slots from `prepare()`; the redundant clear keeps a single
        // source of truth for "starting a solve means slots are empty."
        slots = [SlotState(rank: 1), SlotState(rank: 2), SlotState(rank: 3)]
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
                // Free users out of Dinner Solves see the paywall instead
                // of a dead-end error. Premium+ on RATE-01 = tier bump or
                // Pro upsell (see PaywallTrigger.dinnerSolveQuotaExhausted
                // subhead routing). Paywall emits paywall_viewed with
                // trigger=dinner_solve_quota_exhausted (spec §15).
                self.presentPaywall?(.dinnerSolveQuotaExhausted)
            } catch StirError.entitlementRequired(let code, let message) {
                self.phase = .error(message: message, code: code.rawValue)
                Self.emitSolveFailed(code: code.rawValue)
            } catch StirError.validation(_, let message) {
                self.phase = .error(message: message, code: "VAL-01")
                Logger.solveFeature.error("VAL-01 on dinner-solve: \(message, privacy: .public)")
                Self.emitSolveFailed(code: "VAL-01")
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
                // Spec §15 required property — the Gemini model string
                // that served the solve. Lets AI Ops dashboards split
                // cost/latency by preview vs GA model version. Literal
                // mirrors CLAUDE.md §Stack-snapshot (dinner-solve uses
                // `gemini-3-flash-preview`); backend emits the same
                // string on the paired `$ai_generation` event so the
                // two dashboards reconcile.
                "model": "gemini-3-flash-preview",
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
            writeTonightSnapshot(
                solveId: outcome.solveRequestId,
                suggestedDishIds: outcome.suggestedDishIds,
            )
        } catch {
            Logger.solveFeature.error("persist solve failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Project slots into a widget-ready snapshot and hand off to the
    /// shared App Group store. Runs after persistence so the
    /// SuggestedDish ids are authoritative; failed persistence skips
    /// this path (the previous widget snapshot stays valid).
    private func writeTonightSnapshot(solveId: UUID, suggestedDishIds: [UUID]) {
        let projections: [TonightSnapshotService.DishProjection] = slots.compactMap { slot in
            guard let d = slot.dish else { return nil }
            return TonightSnapshotService.DishProjection(
                title: d.title,
                totalTimeMin: d.totalTimeMinutes,
                ingredientCount: d.recipePlan.ingredients.count,
                ingredientNames: d.recipePlan.ingredients.map(\.displayName),
                cuisine: d.recipePlan.cuisine,
            )
        }
        TonightSnapshotService().write(
            solveId: solveId,
            suggestedDishIds: suggestedDishIds,
            dishes: projections,
        )
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

        // SCA-44: best-effort preference-memory digest. Nil on cold-
        // start (no rated meals in window) OR CoreData read failure;
        // either way the solve proceeds without feedback context.
        let feedbackSummary = preferenceMemoryService.buildDigest(for: household)

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
            feedbackSummary: feedbackSummary,
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

// MARK: - Logger

extension Logger {
    static let solveFeature = Logger(subsystem: "com.scalinity.stir", category: "SolveFeature")
}
