// SubstitutionSheetView
//
// Text-based mid-cook rescue UI. Tier-agnostic per spec §9 — every tier
// gets the Sheet; only voice invocation is Premium+ (step 6).
//
// Flow:
//   idle           — picker + problem text + Submit
//   requesting     — Gemini call in flight; spinner + "Thinking…"
//   safe(result)   — white card with substitution + Accept / Reject
//   unsafe(result) — red warning card with canned safety copy (no Accept)
//   error          — NET-01 / AI-01 surface via ErrorPresenter
//
// Accept / Reject both dismiss the sheet; Accept persists the
// SubstitutionEvent with accepted=true + acceptedAlternativeText =
// the model's suggestion, Reject persists accepted=false.
//
// CLAUDE.md §Invariants: this sheet runs through the SAME server
// handler and hard-rule validator that the (future) Live function-call
// round-trip will hit. Keep the constraint_safe branching logic
// centralized in AIDispatch.SubstitutionResult so step 6 reuses it.

import OSLog
import SwiftUI

struct SubstitutionSheetView: View {
    let recipePlan: RecipePlan
    let household: HouseholdProfile
    let session: CookingSession
    let currentStep: RecipeStep?
    let aiDispatch: AIDispatch
    let onDismiss: () -> Void

    @State private var viewModel: SubstitutionSheetViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    content(vm: vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Substitute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onDismiss)
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = SubstitutionSheetViewModel(
                    recipePlan: recipePlan,
                    household: household,
                    session: session,
                    currentStep: currentStep,
                    aiDispatch: aiDispatch,
                    onFinished: onDismiss,
                )
            }
        }
    }

    @ViewBuilder
    private func content(vm: SubstitutionSheetViewModel) -> some View {
        switch vm.state {
        case .idle:
            idleForm(vm: vm)
        case .requesting:
            requestingIndicator
        case let .safe(text, amountConversion, reasoning, _, _):
            safeResultCard(
                vm: vm,
                text: text,
                amountConversion: amountConversion,
                reasoning: reasoning,
            )
        case let .unsafe(message, reason, _):
            unsafeResultCard(vm: vm, message: message, reason: reason)
        case let .error(message):
            errorCard(vm: vm, message: message)
        }
    }

    // MARK: - Idle form

    private func idleForm(vm: SubstitutionSheetViewModel) -> some View {
        Form {
            Section("What's missing?") {
                Picker("Ingredient", selection: Binding(
                    get: { vm.selectedIngredientID },
                    set: { vm.selectedIngredientID = $0 },
                )) {
                    Text("Something else…").tag(Optional<UUID>.none)
                    ForEach(recipePlan.ingredientArray, id: \.id) { ing in
                        if let id = ing.id {
                            Text(ing.displayName ?? "")
                                .tag(Optional(id))
                        }
                    }
                }
                .pickerStyle(.menu)

                if vm.selectedIngredientID == nil {
                    TextField("e.g. I don't have a blender", text: Binding(
                        get: { vm.freeTextName },
                        set: { vm.freeTextName = $0 },
                    ))
                    .textInputAutocapitalization(.sentences)
                }
            }

            Section("Tell me what's going on (optional)") {
                TextField(
                    "e.g. out of heavy cream, only have milk",
                    text: Binding(
                        get: { vm.userProblem },
                        set: { vm.userProblem = $0 },
                    ),
                    axis: .vertical,
                )
                .textInputAutocapitalization(.sentences)
                .lineLimit(2...5)
            }

            Section {
                Button {
                    Task { await vm.submit() }
                } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Find a swap")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canSubmit)
            }
        }
    }

    private var requestingIndicator: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Checking for a safe swap…")
                .font(.headline)
            Text("We cross-reference your household's dietary rules to avoid anything unsafe.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(40)
    }

    // MARK: - Results

    private func safeResultCard(
        vm: SubstitutionSheetViewModel,
        text: String,
        amountConversion: String?,
        reasoning: String,
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Suggested swap", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)

                Text(text)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)

                if let conversion = amountConversion, !conversion.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Amount")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(conversion)
                            .font(.body.monospacedDigit())
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Why this works")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(reasoning)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button(role: .destructive) {
                        Task { await vm.reject() }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await vm.accept() }
                    } label: {
                        Label("Accept", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private func unsafeResultCard(
        vm: SubstitutionSheetViewModel,
        message: String,
        reason: String,
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Can't swap safely", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)

                Text(message)
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Why")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await vm.acknowledgeUnsafe() }
                } label: {
                    Text("OK, I'll pick another option")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
            .padding(20)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(20)
        }
    }

    private func errorCard(vm: SubstitutionSheetViewModel, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
            HStack {
                Button("Close", action: onDismiss)
                    .buttonStyle(.bordered)
                Button {
                    Task { await vm.submit() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}

// MARK: - View model

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
        state = .requesting
        subEventID = UUID()
        persistedEvent = nil

        let missingIngredient = resolveMissingIngredient()
        let pickedIngredient = selectedIngredientID.flatMap(findIngredient)
        let problemText = userProblem.trimmingCharacters(in: .whitespaces)

        analytics.capture(.substitutionRequested, properties: [
            "problem_type": pickedIngredient == nil ? "free_text" : "picker",
            "invocation": "sheet",
        ])

        let body = SubstitutionRequest(
            subEventID: subEventID,
            cookingSessionID: session.id ?? UUID(),
            recipePlanID: recipePlan.id ?? UUID(),
            missingIngredient: missingIngredient,
            userProblem: problemText.isEmpty ? "Need a substitute" : problemText,
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

    // MARK: - Accept / Reject

    func accept() async {
        guard case let .safe(text, _, _, _, _) = state, let event = persistedEvent else {
            onFinished()
            return
        }
        do {
            try repository.recordDecision(event, accepted: true, acceptedAlternativeText: text)
        } catch {
            Logger.coreData.error("accept substitution failed: \(error.localizedDescription, privacy: .public)")
        }
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": true,
            "constraint_safe": true,
        ])
        onFinished()
    }

    func reject() async {
        guard let event = persistedEvent else { onFinished(); return }
        do {
            try repository.recordDecision(event, accepted: false, acceptedAlternativeText: nil)
        } catch {
            Logger.coreData.error("reject substitution failed: \(error.localizedDescription, privacy: .public)")
        }
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": false,
            "constraint_safe": state.isSafe,
        ])
        onFinished()
    }

    func acknowledgeUnsafe() async {
        // Unsafe results persist as accepted=nil (pending) since the user
        // didn't pick a swap. Just dismiss.
        analytics.capture(.substitutionAccepted, properties: [
            "accepted": false,
            "constraint_safe": false,
        ])
        onFinished()
    }

    // MARK: - Private

    private func applyResult(
        _ result: SubstitutionResult,
        pickedIngredient: RecipeIngredient?,
        freeTextLabel: String,
    ) async {
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
            } catch {
                Logger.coreData.error("persist SubstitutionEvent (safe) failed: \(error.localizedDescription, privacy: .public)")
            }
            state = .safe(
                text: text,
                amountConversion: amountConversion,
                reasoning: reasoning,
                confidence: confidence.rawValue,
                promptVersion: promptVersion,
            )

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
            } catch {
                Logger.coreData.error("persist SubstitutionEvent (unsafe) failed: \(error.localizedDescription, privacy: .public)")
            }
            state = .unsafe(message: message, reason: reason, promptVersion: promptVersion)
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

private extension SubstitutionSheetViewModel.ViewState {
    var isSafe: Bool {
        if case .safe = self { return true }
        return false
    }
}
