// SubstitutionSheetViewModel
//
// Drives SubstitutionSheetView through idle → requesting → safe / unsafe /
// error. Holds the picker selection + free-text + user-problem strings,
// builds the SubstitutionRequest from household + recipe context, dispatches
// to AIDispatch, and persists the SubstitutionEvent (accepted=nil at first,
// accepted=true/false on the user's decision).
//
// Extracted from SubstitutionSheetView.swift so the file follows the rest
// of the codebase's one-VM-per-file convention (CookModeViewModel,
// SolveViewModel, ScanViewModel) and so future tests can target the VM
// without dragging the SwiftUI view in.

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SubstitutionSheetViewModel {
    enum ViewState {
        case idle
        case requesting
        case safe(text: String, amountConversion: String?, reasoning: String, confidence: String, promptVersion: String)
        case unsafe(message: String, reason: String, promptVersion: String)
        case error(message: String)
        /// SCA-432: brief in-sheet state shown after Accept while the
        /// recipe-step-rewrite call is in flight (~1s). Distinct from
        /// `.requesting` so the copy reads "Rewriting step…" instead
        /// of "Checking for a safe swap…". On both success and failure
        /// the sheet dismisses; the step card carries the rewrite (or
        /// the original prose if dispatch failed).
        case rewriting
    }

    private(set) var state: ViewState = .idle

    /// Nil means "free-text" path; iOS client sets missingIngredientDisplayName
    /// on the persisted SubstitutionEvent. A non-nil UUID resolves to the
    /// recipe's RecipeIngredient.
    var selectedIngredientID: UUID?
    var freeTextName: String = ""
    var userProblem: String = ""

    private let recipePlan: RecipePlan
    private let household: HouseholdProfile
    private let session: CookingSession
    private let currentStep: RecipeStep?
    private let aiDispatch: AIDispatch
    private let repository: SubstitutionRepository
    /// SCA-24: bump pantry lastSeenAt for the substitute-IN ingredient
    /// on accept. Recency feeds the voice-prompt prioritization on
    /// the up-to-1000-item walk in RealtimeSession.
    private let pantryRepository: PantryItemRepository
    private let analytics: PostHogClient
    private let onFinished: () -> Void

    private var subEventID: UUID = UUID()
    private var persistedEvent: SubstitutionEvent?

    init(
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        session: CookingSession,
        currentStep: RecipeStep?,
        aiDispatch: AIDispatch,
        repository: SubstitutionRepository,
        pantryRepository: PantryItemRepository,
        analytics: PostHogClient = .shared,
        onFinished: @escaping () -> Void,
    ) {
        self.recipePlan = recipePlan
        self.household = household
        self.session = session
        self.currentStep = currentStep
        self.aiDispatch = aiDispatch
        // SCA-189 (review-CR2-C1): repos are required, no `.shared`
        // fallback. A caller that omits either now fails to compile —
        // closes the SCA-179 footgun on the substitution surface.
        self.repository = repository
        self.pantryRepository = pantryRepository
        self.analytics = analytics
        self.onFinished = onFinished
    }

    var canSubmit: Bool {
        if selectedIngredientID != nil { return true }
        return !freeTextName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Submit

    func submit() async {
        guard canSubmit else { return }
        let trimmed = userProblem.trimmingCharacters(in: .whitespaces)
        let baseProblem = trimmed.isEmpty ? "Need a substitute" : trimmed
        await dispatch(problemText: baseProblem)
    }

    // MARK: - Accept / Reject

    func accept() async {
        guard case let .safe(text, amountConversion, _, _, _) = state,
              let event = persistedEvent
        else {
            onFinished()
            return
        }
        // Snapshot the original ingredient label BEFORE applyAcceptedSwap
        // mutates the linked RecipeIngredient.displayName — the rewrite
        // call needs the pre-swap name to locate references in the prose.
        // `missingLabel` reads `missingIngredientDisplayName` (snapshotted
        // at persist time) so this is safe to read before OR after the
        // swap, but we capture it here to keep the data-flow obvious.
        let originalIngredient = event.missingLabel
        // Order matters: record the decision BEFORE mutating the recipe so
        // an applyAcceptedSwap failure (Core Data save) leaves a recorded
        // accept=true with acceptedAlternativeText for telemetry/audit even
        // if the in-place ingredient mutation fails. The user sees the
        // sheet close either way; downstream consumers (picker, voice
        // context) only see the swapped name when applyAcceptedSwap also
        // succeeded.
        do {
            try repository.recordDecision(event, accepted: true, acceptedAlternativeText: text)
        } catch {
            Logger.coreData.error("accept substitution failed: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try repository.applyAcceptedSwap(
                event,
                substitutionText: text,
                amountConversion: amountConversion,
            )
        } catch {
            Logger.coreData.error(
                "applyAcceptedSwap failed: \(error.localizedDescription, privacy: .public)",
            )
        }
        // SCA-432: rewrite the current step's prose so it references the
        // substitute instead of the original ingredient. Replaces the
        // pre-SCA-432 swap-badge banner. Failure modes are non-fatal:
        // - no currentStep: nothing to rewrite (free-text substitution
        //   on a step-less surface — shouldn't happen from Cook Mode
        //   but the sheet is callable from other invocation paths)
        // - empty step prose: nothing to rewrite
        // - empty originalIngredient: rewrite would have no anchor
        // - dispatch throws: log + continue; step stays as-is. The user
        //   has already accepted; the swap is recorded; the ingredient
        //   list is mutated. Only the prose update is lost.
        await rewriteCurrentStep(
            originalIngredient: originalIngredient,
            substituteText: text,
            amountConversion: amountConversion,
        )
        // SCA-24: signal pantry that the swap-in ingredient was just
        // used. Recency improves voice-prompt prioritization. Failure-
        // tolerant: substitution acceptance is the user's primary
        // action; a flaky bump shouldn't block the sheet's close. The
        // substitute-OUT ingredient is intentionally NOT touched —
        // the user's choice not to use it doesn't prove absence.
        let trimmedSwap = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSwap.isEmpty {
            do {
                try pantryRepository.bumpLastSeenAt(
                    displayName: trimmedSwap,
                    on: household,
                )
            } catch {
                Logger.coreData.error(
                    "pantry bumpLastSeenAt failed for swap=\(trimmedSwap, privacy: .public): \(error.localizedDescription, privacy: .public)",
                )
            }
        }
        // `invocation` + `sub_event_id` on accepted lets the rescue-usage
        // funnel join requested → accepted pairs by sub_event_id AND
        // slice by invocation (sheet vs realtime_function_call). Without
        // `invocation`, dashboards can't tell voice-driven vs manual
        // substitutions apart on the accepted side. Spec §15 amended in
        // this change to include both fields.
        let subEventIDString = subEventID.uuidString
        Logger.telemetry.info(
            "substitution_accepted invocation=sheet sub_event_id=\(subEventIDString, privacy: .public) accepted=true constraint_safe=true",
        )
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": true,
            "constraint_safe": true,
            "invocation": "sheet",
            "sub_event_id": subEventIDString,
            "reason": "user_accepted",
        ])
        onFinished()
    }

    func reject() async {
        // Reject is a re-prompt, not a dismissal: the user is saying "this
        // particular swap doesn't work, give me another one." We record the
        // rejection on the existing event for telemetry/history, then
        // re-invoke the dispatcher with `userProblem` augmented to instruct
        // the model to avoid the rejected suggestion. A fresh sub_event_id
        // is minted by `dispatch` so the server's 10-min idempotency cache
        // doesn't replay the rejected response.
        guard case let .safe(rejectedText, _, _, _, _) = state,
              let event = persistedEvent
        else {
            onFinished()
            return
        }
        do {
            try repository.recordDecision(event, accepted: false, acceptedAlternativeText: nil)
        } catch {
            Logger.coreData.error("reject substitution failed: \(error.localizedDescription, privacy: .public)")
        }
        let priorSubEventIDString = subEventID.uuidString
        Logger.telemetry.info(
            "substitution_accepted invocation=sheet sub_event_id=\(priorSubEventIDString, privacy: .public) accepted=false constraint_safe=true",
        )
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": false,
            "constraint_safe": true,
            "invocation": "sheet",
            "sub_event_id": priorSubEventIDString,
            "reason": "user_rejected",
        ])

        // Build the avoid-hint problem text. Zod caps `user_problem` at 500
        // chars (Backend/_shared/validation.ts SubstitutionRequest); the
        // base problem is already user-controlled and not enforced for
        // length on the iOS side, so we truncate the COMBINED string to
        // stay under the wire limit. The avoid clause goes LAST so a
        // truncation drops it (the prior rejection still helps via the
        // user's original problem context); a truncation that drops the
        // base would lose the user's intent.
        let trimmed = userProblem.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? "Need a substitute" : trimmed
        let augmented = "\(base); avoid \(rejectedText)"
        let truncated = augmented.count > 500 ? String(augmented.prefix(500)) : augmented
        await dispatch(problemText: truncated)
    }

    func acknowledgeUnsafe() async {
        // Unsafe results persist as accepted=nil (pending) since the user
        // didn't pick a swap. Just dismiss.
        let subEventIDString = subEventID.uuidString
        Logger.telemetry.info(
            "substitution_accepted invocation=sheet sub_event_id=\(subEventIDString, privacy: .public) accepted=false constraint_safe=false reason=unsafe_acknowledged",
        )
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": false,
            "constraint_safe": false,
            "invocation": "sheet",
            "sub_event_id": subEventIDString,
            "reason": "unsafe_acknowledged",
        ])
        onFinished()
    }

    // MARK: - Private

    /// Drives the AI round-trip for both the initial submit and the reject
    /// re-prompt. Mints a fresh `subEventID` (so the server idempotency
    /// cache treats this as a new request), captures the picker selection
    /// snapshot, fires the requested telemetry, dispatches, and routes the
    /// result through `applyResult`. The caller owns building the
    /// `problemText` — `submit()` passes the user's typed text, `reject()`
    /// passes that text augmented with an "avoid <prior>" hint.
    private func dispatch(problemText: String) async {
        state = .requesting
        subEventID = UUID()
        persistedEvent = nil

        let missingIngredient = resolveMissingIngredient()
        let pickedIngredient = selectedIngredientID.flatMap(findIngredient)

        // `sub_event_id` so the requested → accepted pair can be joined
        // in PostHog via a single join key rather than needing to match
        // on distinct_id + timestamp heuristics. ADR 0009's
        // dashboard-join contract pairs AI calls by `$ai_span_id`; this
        // event is a product event, not an AI call, but the same pairing
        // discipline applies.
        let subEventIDString = subEventID.uuidString
        Logger.telemetry.info(
            "substitution_requested invocation=sheet sub_event_id=\(subEventIDString, privacy: .public) problem_type=\(pickedIngredient == nil ? "free_text" : "picker", privacy: .public)",
        )
        analytics.capture(.substitutionRequested, properties: [
            "problem_type": pickedIngredient == nil ? "free_text" : "picker",
            "invocation": "sheet",
            "sub_event_id": subEventIDString,
        ])

        let body = SubstitutionRequest(
            subEventID: subEventID,
            cookingSessionID: session.id ?? UUID(),
            recipePlanID: recipePlan.id ?? UUID(),
            missingIngredient: missingIngredient,
            userProblem: problemText,
            householdContext: buildHouseholdContext(),
            recipeContext: buildRecipeContext(),
        )

        do {
            let result = try await aiDispatch.substitution(request: body)
            await applyResult(result, pickedIngredient: pickedIngredient, freeTextLabel: missingIngredient.displayName)
        } catch {
            Logger.aiDispatch.error("substitution dispatch failed: \(error.localizedDescription, privacy: .public)")
            let stirError = (error as? StirError) ?? .networkUnreachable(underlying: error)
            state = .error(message: ErrorPresenter.present(stirError).message)
        }
    }

    private func applyResult(
        _ result: SubstitutionResult,
        pickedIngredient: RecipeIngredient?,
        freeTextLabel: String,
    ) async {
        // If the local persist fails, surface `.error` rather than moving
        // to `.safe` — otherwise Accept/Reject no-ops silently because
        // `persistedEvent` is nil, leaving the user with a rendered
        // substitution that never records a decision (CA2-R3). The Gemini
        // response is cached server-side by sub_event_id for 10 minutes,
        // so a retry via "Try again" is cheap (local-only re-persist on
        // the next submit with the same body).
        switch result {
        case let .safe(subEventID, text, amountConversion, reasoning, confidence, promptVersion):
            do {
                let event = try repository.persist(SubstitutionRepository.PersistInput(
                    subEventId: subEventID,
                    session: session,
                    ingredient: pickedIngredient,
                    freeTextName: pickedIngredient == nil ? freeTextLabel : nil,
                    step: currentStep,
                    userProblemText: userProblem,
                    modelSuggestionText: text,
                    hardConstraintCheckPassed: true,
                ))
                persistedEvent = event
                state = .safe(
                    text: text,
                    amountConversion: amountConversion,
                    reasoning: reasoning,
                    confidence: confidence.rawValue,
                    promptVersion: promptVersion,
                )
            } catch {
                Logger.coreData.error("persist SubstitutionEvent (safe) failed: \(error.localizedDescription, privacy: .public)")
                state = .error(message: ErrorPresenter.present(.val01).message)
            }

        case let .unsafe(subEventID, reason, message, promptVersion):
            do {
                let event = try repository.persist(SubstitutionRepository.PersistInput(
                    subEventId: subEventID,
                    session: session,
                    ingredient: pickedIngredient,
                    freeTextName: pickedIngredient == nil ? freeTextLabel : nil,
                    step: currentStep,
                    userProblemText: userProblem,
                    modelSuggestionText: message,
                    hardConstraintCheckPassed: false,
                ))
                persistedEvent = event
                state = .unsafe(message: message, reason: reason, promptVersion: promptVersion)
            } catch {
                Logger.coreData.error("persist SubstitutionEvent (unsafe) failed: \(error.localizedDescription, privacy: .public)")
                // Unsafe results still matter for user safety — render the
                // copy even if we couldn't persist, but log the divergence.
                state = .unsafe(message: message, reason: reason, promptVersion: promptVersion)
            }
        }
    }

    private func resolveMissingIngredient() -> SubstitutionRequest.MissingIngredient {
        if let id = selectedIngredientID, let ing = findIngredient(id) {
            return SubstitutionRequest.MissingIngredient(
                displayName: ing.displayName ?? "",
                canonicalSlug: ing.canonicalIngredientSlug,
                amountText: ing.amountText,
            )
        }
        return SubstitutionRequest.MissingIngredient(
            displayName: freeTextName.trimmingCharacters(in: .whitespaces),
            canonicalSlug: nil,
            amountText: nil,
        )
    }

    private func findIngredient(_ id: UUID) -> RecipeIngredient? {
        recipePlan.ingredientArray.first { $0.id == id }
    }

    /// Internal (not `private`) so SubstitutionSheetViewModelTests can
    /// assert the SCA-424 pantry filter directly. The pantry array is
    /// the only field worth pinning at this granularity; the dispatch
    /// path is exercised end-to-end by the Backend deno tests.
    func buildHouseholdContext() -> SubstitutionRequest.HouseholdContext {
        let rules: [DinnerSolveRequest.DietaryRuleLite] = household.dietaryRuleArray
            .filter { $0.isActive }
            .compactMap { rule in
                guard let kind = rule.kind, let value = rule.value else { return nil }
                return DinnerSolveRequest.DietaryRuleLite(
                    kind: kind,
                    value: value,
                    severity: rule.severity ?? "soft",
                )
            }
        let equipment = household.kitchenEquipmentArray.filter { $0.isAvailable }.compactMap { $0.code }

        // SCA-424 / SCA-431: consume the canonical pantry filter
        // (`deletedAt == nil && userConfirmed`) from
        // `HouseholdProfile.confirmedActivePantry()`. Pre-SCA-431 this
        // site had its own inline `.filter` and drifted from the voice
        // path; centralising prevents the same drift class recurring.
        let pantry: [SubstitutionRequest.HouseholdContext.PantrySnapshotItem] =
            household.confirmedActivePantry()
                .compactMap { item in
                    guard let name = item.displayName, !name.isEmpty else { return nil }
                    return SubstitutionRequest.HouseholdContext.PantrySnapshotItem(
                        displayName: name,
                        canonicalSlug: item.canonicalIngredientSlug,
                    )
                }

        return SubstitutionRequest.HouseholdContext(
            dietaryRules: rules,
            availableEquipment: equipment,
            pantrySnapshot: pantry,
        )
    }

    /// Internal so SubstitutionSheetViewModelTests can assert the
    /// SCA-425 recipe-step projection.
    func buildRecipeContext() -> SubstitutionRequest.RecipeContext {
        let remaining: [SubstitutionRequest.RecipeContext.RemainingIngredient] =
            recipePlan.ingredientArray.compactMap { ing in
                guard let name = ing.displayName else { return nil }
                return SubstitutionRequest.RecipeContext.RemainingIngredient(
                    displayName: name,
                    canonicalSlug: ing.canonicalIngredientSlug,
                )
            }
        // SCA-425 / SCA-431: consume the shared projection on
        // `RecipePlan.substitutionRecipeSteps()` so this site can't
        // drift from the voice-path dispatch in RealtimeSessionTransport.
        // The voice path had the original step-aware shape via
        // RealtimeRecipeContext.all_steps; pre-SCA-425 the sheet path
        // had no step content at all, which is how "make your own bread
        // from flour" suggestions could slip through a recipe that
        // already has a sub-recipe doing exactly that.
        return SubstitutionRequest.RecipeContext(
            title: recipePlan.title ?? "",
            currentStepNumber: Int(currentStep?.stepNumber ?? 0),
            totalSteps: recipePlan.stepArray.count,
            remainingIngredients: remaining,
            recipeSteps: recipePlan.substitutionRecipeSteps(),
        )
    }

    // MARK: - Step rewrite (SCA-432)

    /// Calls `/v1/ai/recipe-step-rewrite` with the current step's prose and
    /// persists the rewrite on success. Non-fatal: any failure (missing
    /// step / empty prose / dispatch throw) is logged and the method
    /// returns without changing state. Caller is responsible for the
    /// rest of the accept flow (pantry bump, telemetry, dismiss).
    ///
    /// Reuses the upstream `subEventID` so the server-side idempotency
    /// cache collapses a fast double-tap into one Gemini call.
    private func rewriteCurrentStep(
        originalIngredient: String,
        substituteText: String,
        amountConversion: String?,
    ) async {
        guard let step = currentStep else { return }
        let stepText = (step.instructionText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOriginal = originalIngredient.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSubstitute = substituteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stepText.isEmpty, !trimmedOriginal.isEmpty, !trimmedSubstitute.isEmpty else {
            return
        }
        // Transition to the rewriting state so the sheet shows the
        // "Rewriting step…" indicator. The sheet dismisses after this
        // method returns, regardless of outcome.
        state = .rewriting

        let request = RecipeStepRewriteRequest(
            subEventID: subEventID,
            stepInstructionText: stepText,
            originalIngredient: trimmedOriginal,
            substituteIngredient: trimmedSubstitute,
            amountConversion: amountConversion,
            recipeTitle: recipePlan.title,
        )
        do {
            let response = try await aiDispatch.recipeStepRewrite(request: request)
            do {
                try repository.applyStepRewrite(step: step, rewrittenText: response.rewrittenText)
            } catch {
                Logger.coreData.error(
                    "applyStepRewrite failed: \(error.localizedDescription, privacy: .public)",
                )
            }
        } catch {
            Logger.aiDispatch.error(
                "recipe_step_rewrite dispatch failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}

extension SubstitutionSheetViewModel.ViewState {
    var isSafe: Bool {
        if case .safe = self { return true }
        return false
    }
}

#if DEBUG
extension SubstitutionSheetViewModel {
    /// Test seam (SCA-432): seed the view model into `.safe` state with
    /// an already-persisted SubstitutionEvent so unit tests can exercise
    /// `accept()` without driving a full AIDispatch round-trip. Mirrors
    /// the protected `PostHogClient(testingOnly:)` pattern — DEBUG-only
    /// surface, production builds can't reach it. Underscore prefix
    /// marks it as not-for-production.
    func _testingSeedSafeState(
        event: SubstitutionEvent,
        text: String,
        amountConversion: String?,
        reasoning: String = "",
        confidence: String = "high",
        promptVersion: String = "test-1.0.0",
    ) {
        persistedEvent = event
        state = .safe(
            text: text,
            amountConversion: amountConversion,
            reasoning: reasoning,
            confidence: confidence,
            promptVersion: promptVersion,
        )
    }
}
#endif
