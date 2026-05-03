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
        repository: SubstitutionRepository? = nil,
        analytics: PostHogClient = .shared,
        onFinished: @escaping () -> Void,
    ) {
        self.recipePlan = recipePlan
        self.household = household
        self.session = session
        self.currentStep = currentStep
        self.aiDispatch = aiDispatch
        self.repository = repository ?? SubstitutionRepository()
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

    private func buildHouseholdContext() -> SubstitutionRequest.HouseholdContext {
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

        // Step 4 doesn't hold a structured pantry snapshot for Cook Mode
        // (not needed for most substitutions). Pass the household's
        // remembered pantry items as the snapshot so the model can prefer
        // pantry options.
        let pantry: [SubstitutionRequest.HouseholdContext.PantrySnapshotItem] =
            (household.pantryItems as? Set<PantryItem>)?.compactMap { item in
                guard let name = item.displayName, !name.isEmpty else { return nil }
                return SubstitutionRequest.HouseholdContext.PantrySnapshotItem(
                    displayName: name,
                    canonicalSlug: item.canonicalIngredientSlug,
                )
            } ?? []

        return SubstitutionRequest.HouseholdContext(
            dietaryRules: rules,
            availableEquipment: equipment,
            pantrySnapshot: pantry,
        )
    }

    private func buildRecipeContext() -> SubstitutionRequest.RecipeContext {
        let remaining: [SubstitutionRequest.RecipeContext.RemainingIngredient] =
            recipePlan.ingredientArray.compactMap { ing in
                guard let name = ing.displayName else { return nil }
                return SubstitutionRequest.RecipeContext.RemainingIngredient(
                    displayName: name,
                    canonicalSlug: ing.canonicalIngredientSlug,
                )
            }
        return SubstitutionRequest.RecipeContext(
            title: recipePlan.title ?? "",
            currentStepNumber: Int(currentStep?.stepNumber ?? 0),
            totalSteps: recipePlan.stepArray.count,
            remainingIngredients: remaining,
        )
    }
}

extension SubstitutionSheetViewModel.ViewState {
    var isSafe: Bool {
        if case .safe = self { return true }
        return false
    }
}
