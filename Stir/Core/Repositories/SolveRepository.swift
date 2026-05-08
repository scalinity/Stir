// SolveRepository
//
// Persists a complete MealSolveRequest with its SuggestedDish[] and
// the RecipePlan (+ RecipeIngredient[] + RecipeStep[]) each dish references.
//
// Step-3 scope: write-only. Read + replay of past solves comes in step 4
// when Tonight Home's "Recent" section lands for real.
//
// Everything commits in ONE viewContext save so a partially-persisted
// solve never surfaces (e.g. MealSolveRequest without its dishes).

import CoreData
import Foundation
import OSLog

@MainActor
final class SolveRepository {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    // MARK: - Input shapes (from SolveViewModel's streaming accumulator)

    struct DishInput: Sendable {
        let rank: Int
        let title: String
        let summary: String
        let totalTimeMinutes: Int
        let fitLabelPrimary: SuggestedDish.FitLabel
        let fitLabelSecondary: SuggestedDish.FitLabel?
        let missingIngredientCount: Int
        let hardConstraintPass: Bool
        let reasoningSummary: String
        let confidence: Double
        let recipePlan: RecipePlanInput
    }

    struct RecipePlanInput: Sendable {
        let title: String
        let summary: String
        let servings: Int
        let difficulty: Int
        let estimatedMinutes: Int
        let cuisine: String?
        let aiVersion: String
        let ingredients: [IngredientInput]
        let steps: [StepInput]
    }

    struct IngredientInput: Sendable {
        let displayName: String
        let canonicalSlug: String?
        let amountText: String
        let isOptional: Bool
    }

    struct StepInput: Sendable {
        let stepNumber: Int
        let instructionText: String
        let timerSeconds: Int?
        let cautionTags: [String]
    }

    struct SolveOutcome: Sendable {
        let solveRequestId: UUID
        let suggestedDishIds: [UUID]
    }

    // MARK: - Create

    /// Persist an AI dinner-solve outcome. Returns identifiers for in-memory
    /// routing (DishPreview deep-link) while the NSManagedObjects live in
    /// viewContext.
    @discardableResult
    func createSolveWithDishes(
        on household: HouseholdProfile,
        constraints: MealSolveRequest.Constraints?,
        pantrySnapshot: MealSolveRequest.PantrySnapshot,
        dishes: [DishInput],
        aiRequestId: String?,
    ) throws -> SolveOutcome {
        let context = controller.viewContext
        let now = Date()

        let solve = MealSolveRequest(context: context)
        solve.id = UUID()
        solve.household = household
        solve.requestedAt = now
        solve.completedAt = dishes.isEmpty ? nil : now
        solve.typedStatus = dishes.isEmpty ? .failed : .completed
        solve.aiRequestId = aiRequestId
        solve.typedConstraints = constraints
        solve.typedPantrySnapshot = pantrySnapshot

        var dishIds: [UUID] = []

        for dish in dishes.sorted(by: { $0.rank < $1.rank }) {
            let recipe = RecipePlan(context: context)
            recipe.id = UUID()
            recipe.household = household
            recipe.title = dish.recipePlan.title
            recipe.summary = dish.recipePlan.summary
            recipe.servings = Int16(clamping: dish.recipePlan.servings)
            recipe.difficulty = Int16(clamping: dish.recipePlan.difficulty)
            recipe.estimatedMinutes = Int16(clamping: dish.recipePlan.estimatedMinutes)
            recipe.cuisine = dish.recipePlan.cuisine
            recipe.aiVersion = dish.recipePlan.aiVersion
            recipe.typedOrigin = .ai
            recipe.isFavorite = false
            recipe.isSaved = false
            recipe.createdAt = now
            recipe.updatedAt = now

            for (idx, ing) in dish.recipePlan.ingredients.enumerated() {
                let row = RecipeIngredient(context: context)
                row.id = UUID()
                row.recipePlan = recipe
                row.displayName = ing.displayName
                row.canonicalIngredientSlug = ing.canonicalSlug
                row.amountText = ing.amountText
                // Persisted schema defaults ambiguous (nil from wire)
                // to `false` = required. Matches prior behavior before
                // isOptional was made nullable on the wire.
                row.isOptional = ing.isOptional ?? false
                row.sortOrder = Int16(clamping: idx)
                row.typedSource = .ai
            }

            for step in dish.recipePlan.steps {
                let row = RecipeStep(context: context)
                row.id = UUID()
                row.recipePlan = recipe
                row.stepNumber = Int16(clamping: step.stepNumber)
                row.sortOrder = Int16(clamping: step.stepNumber)
                row.instructionText = step.instructionText
                row.timerSeconds = Int32(clamping: step.timerSeconds ?? 0)
                row.cautionTagsArray = step.cautionTags
            }

            let suggested = SuggestedDish(context: context)
            let dishId = UUID()
            dishIds.append(dishId)
            suggested.id = dishId
            suggested.solveRequest = solve
            suggested.recipePlan = recipe
            suggested.rank = Int16(clamping: dish.rank)
            suggested.title = dish.title
            suggested.summary = dish.summary
            suggested.estimatedMinutes = Int16(clamping: dish.totalTimeMinutes)
            suggested.typedFitLabelPrimary = dish.fitLabelPrimary
            suggested.typedFitLabelSecondary = dish.fitLabelSecondary
            suggested.missingIngredientCount = Int16(clamping: dish.missingIngredientCount)
            suggested.hardConstraintPass = dish.hardConstraintPass
            suggested.reasoningSummary = dish.reasoningSummary
            suggested.confidence = dish.confidence
        }

        try controller.save()
        Logger.coreData.info("SolveRepository persisted \(dishes.count, privacy: .public)-dish solve")
        // solve.id was assigned unconditionally at the top of this function;
        // force-unwrap surfaces an invariant violation loudly if Core Data
        // ever nils it (should never happen) instead of silently generating
        // a different UUID the persistent store doesn't know about.
        guard let solveID = solve.id else {
            throw StirError.coreData(underlying: NSError(
                domain: "SolveRepository",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "post-save solve.id is nil"],
            ))
        }
        return SolveOutcome(solveRequestId: solveID, suggestedDishIds: dishIds)
    }

    /// Persist a leftovers-mode solve outcome: ONE picked dish, no pantry
    /// snapshot, no constraints, linked back to the meal that produced the
    /// leftovers via `MealSolveRequest.sourceRecipePlanId`. Returns the
    /// persisted `RecipePlan` so the caller can route it (typically letting
    /// `latestTonightPick` surface it as the next Tonight hero card per the
    /// LeftoversSolveView helper text "adds it to tomorrow's Tonight").
    ///
    /// Distinct from `createSolveWithDishes` because the leftovers shape
    /// (single dish, sourced from a prior recipe, no pantry) doesn't fit
    /// cleanly as overloaded nullable parameters — see SCA-55 spec D4.
    ///
    /// Field-mapping note (SCA-56 S5): `dish.whyItFits` here plays the
    /// same role as `DishInput.summary` on `createSolveWithDishes` —
    /// it's the one-line user-facing rationale persisted on both
    /// `RecipePlan.summary` and `SuggestedDish.summary`. Wire-name
    /// divergence on `DishCard` vs `DishInput` only; no semantic
    /// difference.
    @discardableResult
    func createLeftoversSolveWithDish(
        on household: HouseholdProfile,
        from sourceRecipePlan: RecipePlan,
        dish: DishCard,
        aiRequestId: String?,
        promptVersion: String?,
    ) throws -> RecipePlan {
        let context = controller.viewContext
        let now = Date()

        let solve = MealSolveRequest(context: context)
        solve.id = UUID()
        solve.household = household
        solve.requestedAt = now
        solve.completedAt = now
        solve.typedStatus = .completed
        solve.aiRequestId = aiRequestId
        solve.sourceRecipePlanId = sourceRecipePlan.id
        // Intentionally NOT set: typedConstraints, typedPantrySnapshot —
        // leftovers solves skip both per LeftoversSessionViewModel:
        // pantry-skip is line 187 (`ingredients: []`); constraints aren't
        // collected on the leftovers prompt.
        //
        // SCA-56 S4 — `sourceRecipePlanId` is intentionally a bare UUID,
        // NOT a Core Data relationship. Orphan acceptance: if the source
        // RecipePlan is later soft- or hard-deleted, the leftovers solve
        // carries a dangling pointer with no cascade. This is acceptable
        // because (1) no UI consumes the field today; it's analytics-only,
        // (2) joining via UUID at query time tolerates absent rows, and
        // (3) flipping to a relationship later requires an inverse on
        // RecipePlan and a lightweight migration. Revisit if a UI surface
        // ever depends on the link being live.

        let recipe = RecipePlan(context: context)
        recipe.id = UUID()
        recipe.household = household
        recipe.title = dish.title
        recipe.summary = dish.whyItFits
        recipe.servings = Int16(clamping: dish.recipePlan.servings)
        recipe.difficulty = Int16(clamping: dish.recipePlan.difficulty)
        recipe.estimatedMinutes = Int16(clamping: dish.totalTimeMinutes)
        recipe.cuisine = dish.recipePlan.cuisine
        // SCA-56 S2: thread the actual backend prompt version through
        // (captured by LeftoversSessionViewModel on the dinner-solve
        // `done` event) instead of a magic "leftovers" tag. The
        // "unknown" fallback only fires when the stream errored before
        // emitting a done event — matches the telemetry fallback shape
        // on `leftovers_dish_selected.prompt_version`.
        recipe.aiVersion = promptVersion ?? "unknown"
        recipe.typedOrigin = .ai
        recipe.isFavorite = false
        recipe.isSaved = false
        recipe.createdAt = now
        recipe.updatedAt = now

        for (idx, ing) in dish.recipePlan.ingredients.enumerated() {
            let row = RecipeIngredient(context: context)
            row.id = UUID()
            row.recipePlan = recipe
            row.displayName = ing.displayName
            row.canonicalIngredientSlug = ing.canonicalSlug
            row.amountText = ing.amountText
            row.isOptional = ing.isOptional ?? false
            row.sortOrder = Int16(clamping: idx)
            row.typedSource = .ai
        }

        // SCA-56 (DB1 #8): pre-sort by stepNumber so sortOrder is
        // monotonic regardless of any wire-ordering quirks. Ingredients
        // use enumerated() for sortOrder (insertion order wins); steps
        // tie sortOrder to the semantic stepNumber for safety.
        for step in dish.recipePlan.steps.sorted(by: { $0.stepNumber < $1.stepNumber }) {
            let row = RecipeStep(context: context)
            row.id = UUID()
            row.recipePlan = recipe
            row.stepNumber = Int16(clamping: step.stepNumber)
            row.sortOrder = Int16(clamping: step.stepNumber)
            row.instructionText = step.instructionText
            row.timerSeconds = Int32(clamping: step.timerSeconds ?? 0)
            row.cautionTagsArray = step.cautionTags ?? []
        }

        let suggested = SuggestedDish(context: context)
        let suggestedID = UUID()
        suggested.id = suggestedID
        suggested.solveRequest = solve
        suggested.recipePlan = recipe
        suggested.rank = Int16(clamping: dish.rank)
        suggested.title = dish.title
        suggested.summary = dish.whyItFits
        suggested.estimatedMinutes = Int16(clamping: dish.totalTimeMinutes)
        suggested.typedFitLabelPrimary = SuggestedDish.FitLabel(rawValue: dish.fitLabelPrimary) ?? .bestFit
        suggested.typedFitLabelSecondary = dish.fitLabelSecondary.flatMap(SuggestedDish.FitLabel.init(rawValue:))
        suggested.missingIngredientCount = Int16(clamping: dish.missingIngredientCount)
        suggested.hardConstraintPass = dish.hardConstraintPass
        suggested.reasoningSummary = dish.reasoningSummary
        // SCA-56 S3: leftovers solves don't surface a model confidence
        // value (DishCard doesn't carry one — the wire DishCard ships
        // with `hardConstraintPass` but no scalar confidence). Persist
        // 0 explicitly so downstream consumers can detect the
        // "no-confidence-from-leftovers" case rather than reading a
        // synthesized magic number.
        suggested.confidence = 0
        // Mark selected on the solve immediately — the user has already
        // committed by tapping the leftovers card; there's no separate
        // selection step downstream the way the dinner-solve flow has.
        // SCA-56 (DB1 #5): use the local UUID we just minted rather
        // than re-reading `suggested.id` post-assignment, mirroring
        // the defensive guard at the bottom of `createSolveWithDishes`.
        // Avoids any post-save nil edge case from impacting the pick.
        suggested.selectedAt = now
        solve.selectedSuggestedDishId = suggestedID

        try controller.save()
        Logger.coreData.info("SolveRepository persisted 1-dish leftovers solve")
        return recipe
    }

    /// Mark a SuggestedDish as selected by the user. Used by DishPreview's
    /// Start Cooking CTA (step 4 replaces the disabled stub).
    func markSelected(
        _ dish: SuggestedDish,
        on solve: MealSolveRequest,
    ) throws {
        dish.selectedAt = Date()
        solve.selectedSuggestedDishId = dish.id
        try controller.save()
    }

    /// Fetch the RecipePlan linked to a previously-persisted
    /// SuggestedDish. Used by DishPreview when presenting Cook Mode.
    /// Returns nil if the dish row was deleted or the relationship
    /// was nullified (e.g. RecipePlan hard-delete).
    func fetchRecipePlan(forSuggestedDishId id: UUID) -> RecipePlan? {
        let request = NSFetchRequest<SuggestedDish>(entityName: "SuggestedDish")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        request.relationshipKeyPathsForPrefetching = ["recipePlan"]
        return (try? controller.viewContext.fetch(request).first)?.recipePlan
    }

    // MARK: - Read

    /// Value-type projection of "the dish Tonight Home should hero-card".
    /// Strictly value-only (UUID / Date / Int / String / [String]) so the
    /// view never carries a live `NSManagedObject` reference across
    /// renders — that would race against Core Data soft-deletes and
    /// CloudKit conflict resolutions, leaving SwiftUI with a faulted
    /// or invalidated `RecipePlan`. The dish id is the stable handle;
    /// `fetchRecipePlan(forSuggestedDishId:)` resolves to the current
    /// plan at tap time, where a soft-delete check can still bail
    /// gracefully. `Sendable` is honest now: every stored property is
    /// itself Sendable.
    struct TonightPick: Sendable, Equatable {
        let suggestedDishId: UUID
        let title: String
        let solvedAt: Date
        let confidence: Double
        let estimatedMinutes: Int
        let servings: Int
        /// Display-name strings for the dish chips (e.g. ["pescatarian",
        /// "nut-free", "quick"]). Derived from the household's dietary
        /// rule values plus a synthetic "quick" tag when the dish is
        /// ≤30 min. Capped at 3 entries — mockup 03 shows three chips.
        let chips: [String]
        /// SCA-70 visibility fix: true when the underlying
        /// `MealSolveRequest.sourceRecipePlanId != nil` — i.e., this
        /// pick was promoted from a Leftovers handoff rather than a
        /// regular dinner-solve. TonightHomeView surfaces a "From your
        /// leftovers" eyebrow on the hero card so the user understands
        /// what they're looking at; the "Solve again" affordance below
        /// the hero is the documented escape hatch (LeftoversSolveView
        /// helper text "Solve again to re-roll").
        let isFromLeftovers: Bool
    }

    /// Latest dish to surface as the Tonight hero card. Picks the user-
    /// selected SuggestedDish from the most-recent completed solve when
    /// one exists; otherwise the rank-0 (top-ranked) dish. Returns nil
    /// when the household has no completed solves yet (first-use empty
    /// state).
    ///
    /// Selection precedence matters: once the user has picked a dish,
    /// re-rendering Tonight should keep showing THEIR pick rather than
    /// flipping back to the AI's rank-0 — the act of selecting is a
    /// commitment we shouldn't quietly override on the next render.
    /// Fetch the most recent completed (non-deleted) MealSolveRequest for
    /// `household` with relationships warmed for hero-card + chip rendering.
    /// CA3-M2/M3 fix: factored from `latestTonightPick` /
    /// `latestPantryIngredients` so a Tonight render + a Solve-again tap
    /// don't issue two identical queries; `household.dietaryRules` is now
    /// in the prefetch list so `derivedChips` doesn't lazy-fault per chip.
    private func latestCompletedSolve(for household: HouseholdProfile) -> MealSolveRequest? {
        let request = NSFetchRequest<MealSolveRequest>(entityName: "MealSolveRequest")
        request.predicate = NSPredicate(
            format: "household == %@ AND status == %@ AND deletedAt == nil",
            household,
            MealSolveRequest.Status.completed.rawValue,
        )
        request.sortDescriptors = [NSSortDescriptor(key: "completedAt", ascending: false)]
        request.fetchLimit = 1
        request.relationshipKeyPathsForPrefetching = [
            "suggestedDishes",
            "suggestedDishes.recipePlan",
            "household.dietaryRules",
        ]
        return try? controller.viewContext.fetch(request).first
    }

    func latestTonightPick(for household: HouseholdProfile) -> TonightPick? {
        guard
            let solve = latestCompletedSolve(for: household),
            let solvedAt = solve.completedAt
        else { return nil }

        let dishes = solve.suggestedDishArray
        let chosen: SuggestedDish? = {
            if let selectedId = solve.selectedSuggestedDishId,
               let match = dishes.first(where: { $0.id == selectedId }) {
                return match
            }
            return dishes.first
        }()
        guard
            let dish = chosen,
            let dishId = dish.id,
            let plan = dish.recipePlan,
            // Soft-deleted plan: user swipe-deleted from Saved tab.
            // Bail to nil so Tonight returns to its empty/first-use
            // state until a new solve runs, rather than ghosting a
            // tombstoned recipe in the hero card.
            plan.deletedAt == nil,
            let title = (dish.title?.isEmpty == false ? dish.title : plan.title)
        else { return nil }

        let chips = derivedChips(for: dish, plan: plan, household: household)
        return TonightPick(
            suggestedDishId: dishId,
            title: title,
            solvedAt: solvedAt,
            confidence: dish.confidence,
            estimatedMinutes: Int(dish.estimatedMinutes),
            servings: Int(plan.servings),
            chips: chips,
            isFromLeftovers: solve.sourceRecipePlanId != nil,
        )
    }

    /// Value-type projection of an alternate dish from the same solve as
    /// the current Tonight pick — the OTHER 1–2 dishes the user might
    /// swap to. Mirrors `TonightPick`'s "no live NSManagedObject in view
    /// state" rule: the dish id is the stable handle, and tap-time
    /// resolution goes through `fetchRecipePlan(forSuggestedDishId:)` so
    /// soft-deletes / CloudKit conflict resolution can bail gracefully.
    struct OtherOption: Sendable, Equatable, Identifiable {
        let suggestedDishId: UUID
        let rank: Int
        let title: String
        let totalTimeMinutes: Int
        /// One-line "why it fits" summary. Drives `DishOptionCard`'s
        /// body copy. Falls back to RecipePlan.summary if SuggestedDish
        /// has none persisted.
        let whyItFits: String
        let missingIngredientCount: Int
        let isHighMatch: Bool
        var id: UUID { suggestedDishId }
    }

    /// The OTHER dishes from the most recent completed solve — the
    /// alts the user can swap into when they tap "Other options" on
    /// Tonight Home. Excludes the current hero pick (id passed in).
    /// Returns empty when the latest solve has only one dish or every
    /// other dish is unresolvable (recipePlan nil / soft-deleted) —
    /// callers surface an empty state rather than crash.
    func latestOtherOptions(
        excluding currentPickSuggestedDishId: UUID,
        for household: HouseholdProfile,
    ) -> [OtherOption] {
        guard let solve = latestCompletedSolve(for: household) else { return [] }
        return solve.suggestedDishArray
            .filter { $0.id != currentPickSuggestedDishId }
            .compactMap(projectOtherOption(from:))
            .sorted { $0.rank < $1.rank }
    }

    /// Shared `SuggestedDish` → `OtherOption` projection. Extracted so
    /// `latestOtherOptions` and `latestOtherOptionsWithCards` produce
    /// byte-identical OtherOption shapes; drift in the fallback chain
    /// (title, why-it-fits, minutes) would otherwise be a hazard.
    ///
    /// Source-of-truth note: persistence stores wire `whyItFits` in
    /// `SuggestedDish.summary` (see `createSolveWithDishes`:
    /// `suggested.summary = dish.summary` where DishInput.summary is
    /// fed by `d.whyItFits`). `dish.reasoningSummary` is the AI's
    /// longer rationale and is a DIFFERENT field — using it here
    /// would cause DishPreviewView to render reasoningSummary twice
    /// (in both the whyItFits and reasoningSummary slots). The trim
    /// guard filters whitespace-only persisted values.
    private func projectOtherOption(from dish: SuggestedDish) -> OtherOption? {
        guard
            let dishId = dish.id,
            let plan = dish.recipePlan,
            plan.deletedAt == nil,
            let title = (dish.title?.isEmpty == false ? dish.title : plan.title)
        else { return nil }
        let why: String = {
            if let s = dish.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return s }
            return plan.summary ?? ""
        }()
        let minutes = Int(
            dish.estimatedMinutes > 0 ? dish.estimatedMinutes : plan.estimatedMinutes,
        )
        return OtherOption(
            suggestedDishId: dishId,
            rank: Int(dish.rank),
            title: title,
            totalTimeMinutes: minutes,
            whyItFits: why,
            missingIngredientCount: Int(dish.missingIngredientCount),
            isHighMatch: dish.confidence >= 0.7,
        )
    }

    /// One-shot variant of `latestOtherOptions` that ALSO returns each
    /// alt's rehydrated `DishCard` from the same Core Data fetch.
    /// Callers reaching for both the `OtherOption` projection AND the
    /// DishCard for `DishPreviewView` reuse should prefer this over the
    /// 2-step `latestOtherOptions(...)` + per-alt `rehydrateDishCard(...)`
    /// path — saves N+1 viewContext fetches.
    func latestOtherOptionsWithCards(
        excluding currentPickSuggestedDishId: UUID,
        for household: HouseholdProfile,
    ) -> [(option: OtherOption, card: DishCard)] {
        guard let solve = latestCompletedSolve(for: household) else { return [] }
        return solve.suggestedDishArray
            .filter { $0.id != currentPickSuggestedDishId }
            .compactMap { dish -> (option: OtherOption, card: DishCard)? in
                guard let option = projectOtherOption(from: dish) else { return nil }
                guard let card = projectDishCard(from: dish) else { return nil }
                return (option, card)
            }
            .sorted { $0.option.rank < $1.option.rank }
    }

    /// Reconstruct the wire-shape `DishCard` from a persisted
    /// `SuggestedDish` so the existing `DishPreviewView` (which reads
    /// all display data from a `DishCard`) can render an alt without
    /// any UI duplication. Returns nil if the dish row is gone or the
    /// linked RecipePlan was soft-deleted.
    ///
    /// Wire-shape coupling: `DishCard` / `RecipePlanWire` evolve
    /// together with the dinner-solve SSE contract; this rehydrator
    /// keeps in lockstep. Persisted columns are a near-1:1 superset of
    /// the wire shape (we drop `confidence` and `hardConstraintPass`
    /// from the rehydrated card — they're inputs to display fit-label,
    /// not fields DishPreviewView reads directly).
    func rehydrateDishCard(forSuggestedDishId id: UUID) -> DishCard? {
        let request = NSFetchRequest<SuggestedDish>(entityName: "SuggestedDish")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        request.relationshipKeyPathsForPrefetching = [
            "recipePlan",
            "recipePlan.ingredients",
            "recipePlan.steps",
        ]
        guard let dish = try? controller.viewContext.fetch(request).first else {
            return nil
        }
        return projectDishCard(from: dish)
    }

    /// Shared `SuggestedDish` → `DishCard` projection. Extracted so
    /// `rehydrateDishCard(forSuggestedDishId:)` and the bulk variant
    /// `latestOtherOptionsWithCards(...)` produce identical DishCards
    /// from the same source row. Returns nil when the linked RecipePlan
    /// is gone, soft-deleted, or the title resolves to empty.
    private func projectDishCard(from dish: SuggestedDish) -> DishCard? {
        guard
            let plan = dish.recipePlan,
            plan.deletedAt == nil,
            let title = (dish.title?.isEmpty == false ? dish.title : plan.title)
        else { return nil }
        let ingredients: [DishCard.RecipePlanWire.IngredientWire] = plan.ingredientArray.map { ing in
            DishCard.RecipePlanWire.IngredientWire(
                displayName: ing.displayName ?? "",
                canonicalSlug: ing.canonicalIngredientSlug,
                amountText: ing.amountText ?? "",
                isOptional: ing.isOptional,
            )
        }
        let steps: [DishCard.RecipePlanWire.StepWire] = plan.stepArray.map { step in
            DishCard.RecipePlanWire.StepWire(
                stepNumber: Int(step.stepNumber),
                instructionText: step.instructionText ?? "",
                timerSeconds: step.timerSeconds > 0 ? Int(step.timerSeconds) : nil,
                cautionTags: step.cautionTagsArray,
            )
        }
        let totalMinutes = Int(
            dish.estimatedMinutes > 0 ? dish.estimatedMinutes : plan.estimatedMinutes,
        )
        // whyItFits + reasoningSummary are DISTINCT persisted fields:
        // `SuggestedDish.summary` holds the wire `whyItFits` (one-line
        // user-facing rationale) and `SuggestedDish.reasoningSummary`
        // holds the longer AI rationale. Earlier drafts pulled
        // `whyItFits` from `dish.reasoningSummary`, which caused
        // DishPreviewView to render the same paragraph twice (once
        // in the bodyLg slot and once in the bodySm slot). Reading
        // the correct backing field restores the two-tier display.
        //
        // Trim guards mirror `projectOtherOption` — a persisted
        // whitespace-only value should fall through to the next
        // fallback rather than surface as visible blank body copy.
        let whyItFits: String = {
            if let s = dish.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return s }
            return plan.summary ?? ""
        }()
        let reasoningSummary: String = {
            if let s = dish.reasoningSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty { return s }
            return ""
        }()
        return DishCard(
            rank: Int(dish.rank),
            title: title,
            totalTimeMinutes: totalMinutes,
            whyItFits: whyItFits,
            missingIngredientCount: Int(dish.missingIngredientCount),
            fitLabelPrimary: dish.typedFitLabelPrimary.rawValue,
            fitLabelSecondary: dish.typedFitLabelSecondary?.rawValue,
            hardConstraintPass: dish.hardConstraintPass,
            recipePlan: DishCard.RecipePlanWire(
                servings: Int(plan.servings),
                difficulty: Int(plan.difficulty),
                cuisine: plan.cuisine,
                ingredients: ingredients,
                steps: steps,
            ),
            reasoningSummary: reasoningSummary,
        )
    }

    /// Latest pantry snapshot, projected to the IngredientLite shape
    /// the `/v1/ai/dinner-solve` endpoint expects. Used by Tonight's
    /// "Solve again" tile so a re-solve from the existing pantry
    /// doesn't require re-scanning. Returns nil when the household
    /// has no completed solves yet (Solve again has nothing to solve
    /// from in that case — Tonight surfaces the first-use empty state
    /// instead).
    ///
    /// We read from the last `MealSolveRequest.typedPantrySnapshot`
    /// rather than re-querying live `PantryItem` rows because (a) the
    /// snapshot is already the exact shape the endpoint wants, and
    /// (b) there's no `fetchAll` on `PantryItemRepository` today.
    /// The trade-off: if the user edited pantry items between the
    /// last solve and tapping Solve again, the edits aren't reflected.
    /// In practice users either re-scan (full refresh) or solve again
    /// (re-roll on the existing pantry) — manual pantry edits between
    /// solves aren't a v1 user path. Promote to a live `PantryItem`
    /// query if telemetry shows manual-edit-then-solve-again traffic.
    func latestPantryIngredients(
        for household: HouseholdProfile,
    ) -> [DinnerSolveRequest.IngredientLite]? {
        guard
            let solve = latestCompletedSolve(for: household),
            let snapshot = solve.typedPantrySnapshot
        else { return nil }
        let ingredients = snapshot.ingredients.map { ing in
            DinnerSolveRequest.IngredientLite(
                displayName: ing.displayName,
                canonicalSlug: ing.canonicalSlug,
                amountText: ing.amountText,
            )
        }
        return ingredients.isEmpty ? nil : ingredients
    }

    /// Build the up-to-three chip labels shown under the hero title.
    /// Pulls dietary-rule values for `.diet` rules verbatim and
    /// reformats `.allergy` rules into "X-free" form (matches mockup-03
    /// grammar — e.g. "peanuts" allergy → "peanut-free" chip). Other
    /// rule kinds (`.dislike`, `.goal`) are too verbose for a hero chip
    /// and are skipped. A synthetic "quick" tag appends when the dish
    /// runs ≤30 min.
    ///
    /// Defensive scrubbing per chip via `scrubChip(_:)`: lowercase +
    /// trim + length cap + strict `[a-z0-9 -]` allowlist. This filters
    /// underscored enum codes, accidental punctuation, and overlong
    /// values that would betray the data pipeline to the user. Order
    /// is stable (rules first by createdAt, "quick" last) so consecutive
    /// renders don't shuffle. Caps at 3 entries.
    private func derivedChips(
        for dish: SuggestedDish,
        plan: RecipePlan,
        household: HouseholdProfile,
    ) -> [String] {
        var chips: [String] = []
        for rule in household.dietaryRuleArray {
            switch rule.typedKind {
            case .diet:
                if let scrubbed = scrubChip(rule.value) {
                    chips.append(scrubbed)
                }
            case .allergy:
                // Trim a trailing 's' for the singular stem before
                // suffixing "-free" — "peanuts" → "peanut-free",
                // "nuts" → "nut-free". Re-scrub the formatted value
                // so the resulting chip still satisfies the allowlist
                // (a length spike from suffixing legitimately rejects).
                if let scrubbed = scrubChip(rule.value) {
                    let stem = scrubbed.hasSuffix("s") ? String(scrubbed.dropLast()) : scrubbed
                    if let formatted = scrubChip("\(stem)-free") {
                        chips.append(formatted)
                    }
                }
            case .dislike, .goal, .none:
                continue
            }
            if chips.count == 2 { break }
        }
        let totalMinutes = Int(dish.estimatedMinutes > 0 ? dish.estimatedMinutes : plan.estimatedMinutes)
        if totalMinutes > 0 && totalMinutes <= 30 {
            chips.append("quick")
        }
        return Array(chips.prefix(3))
    }

    /// Lowercase, trim, and validate a chip value against a strict allow
    /// pattern. Returns nil for any failure so callers can `if let` a
    /// single guard rather than re-checking each rule. The allowlist is
    /// `[a-z0-9 -]` plus a 20-char cap; underscored enum codes
    /// (`diet_pescatarian`), accidental punctuation, and overlong values
    /// fail closed — the chip just doesn't render.
    private func scrubChip(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 20 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789 -")
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    /// Soft-delete a RecipePlan (sets `deletedAt`, bumps `updatedAt`).
    /// Backs swipe-to-delete on the Saved tab. Soft- not hard-delete so
    /// CloudKit can replicate the tombstone and the related cooking-
    /// session history isn't orphaned. Returns `false` on Core Data
    /// save failure (rollback applied) so the caller can restore its
    /// optimistic UI; not `@discardableResult` because the optimistic
    /// pattern depends on observing the failure.
    func softDelete(_ plan: RecipePlan) -> Bool {
        let context = controller.viewContext
        let now = Date()
        plan.deletedAt = now
        plan.updatedAt = now
        do {
            try context.save()
            return true
        } catch {
            Logger.coreData.warning(
                "softDelete plan failed: \(error.localizedDescription, privacy: .public)",
            )
            context.rollback()
            return false
        }
    }

    /// Persist a change to `RecipePlan.isFavorite`. Called from DishPreviewView
    /// and SavedMealsView when the user toggles the star icon. Optimistic in
    /// the UI; this catches up storage. Bumps `updatedAt` so CloudKit sync
    /// propagates the change to other devices.
    ///
    /// Also flips `isSaved = true` (sticky — unfavoriting does NOT clear
    /// it). Any interaction with the favorite star is treated as the
    /// explicit "save this dish" signal, so a meal favorited via Tonight
    /// Save-for-later doesn't disappear from Saved when the user later
    /// unstars it (SCA-10). Soft-delete remains the only path that
    /// removes a plan from Saved.
    ///
    /// Silent on failure: returns without raising. Core Data saves here fail
    /// only on disk full / corruption; the UI optimistic state will desync
    /// but user-perceptible breakage is limited. Logged at warning level
    /// for Sentry.
    @discardableResult
    func setFavorite(_ isFavorite: Bool, on plan: RecipePlan) -> Bool {
        let context = controller.viewContext
        plan.isFavorite = isFavorite
        plan.isSaved = true
        plan.updatedAt = Date()
        do {
            try context.save()
            return true
        } catch {
            Logger.coreData.warning(
                "setFavorite save failed: \(error.localizedDescription, privacy: .public)",
            )
            context.rollback()
            return false
        }
    }
}
