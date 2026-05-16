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
//
// View model lives in SubstitutionSheetViewModel.swift (one VM per file
// — matches CookModeViewModel / SolveViewModel / ScanViewModel).

import OSLog
import SwiftUI

struct SubstitutionSheetView: View {
    let recipePlan: RecipePlan
    let household: HouseholdProfile
    let session: CookingSession
    let currentStep: RecipeStep?
    let aiDispatch: AIDispatch
    let onDismiss: () -> Void

    @State private var viewModel: SubstitutionSheetViewModel

    init(
        recipePlan: RecipePlan,
        household: HouseholdProfile,
        session: CookingSession,
        currentStep: RecipeStep?,
        aiDispatch: AIDispatch,
        substitutionRepository: SubstitutionRepository,
        pantryRepository: PantryItemRepository,
        onDismiss: @escaping () -> Void,
        onStepRewritten: @escaping () -> Void = {},
    ) {
        self.recipePlan = recipePlan
        self.household = household
        self.session = session
        self.currentStep = currentStep
        self.aiDispatch = aiDispatch
        self.onDismiss = onDismiss
        // Construct the VM eagerly so the sheet opens directly into the
        // idle form — the prior `.task { if nil { ... } }` pattern
        // produced a ProgressView flash on every presentation because
        // .task runs after the first body eval. Matches ScanFlowRoot.
        // Review finding W-D W20 (CA2).
        //
        // SCA-189 (review-CR2-C1): repository + pantryRepository are
        // threaded from the caller (CookModeRoot) so the VM doesn't
        // fall back to .shared. Closes the substitution surface of
        // the SCA-179 footgun.
        _viewModel = State(initialValue: SubstitutionSheetViewModel(
            recipePlan: recipePlan,
            household: household,
            session: session,
            currentStep: currentStep,
            aiDispatch: aiDispatch,
            repository: substitutionRepository,
            pantryRepository: pantryRepository,
            onFinished: onDismiss,
            onStepRewritten: onStepRewritten,
        ))
    }

    var body: some View {
        NavigationStack {
            content(vm: viewModel)
                // Keep `.navigationTitle` for the implicit back-chevron
                // label any deeper pushed screen reads, plus VoiceOver —
                // visible chrome is `.stirTopBar` below.
                .navigationTitle("Substitute")
                .navigationBarTitleDisplayMode(.inline)
                // SCA-457: custom top bar escapes iOS 26 Liquid Glass.
                .stirTopBar(
                    title: "Substitute",
                    leading: {
                        StirTopBarCloseButton(action: onDismiss)
                    },
                )
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
        case .rewriting:
            rewritingIndicator
        }
    }

    // MARK: - Idle form

    /// Rebuilt from stock SwiftUI Form chrome to a tokenized VStack +
    /// SelectableChip + InputField pattern. Ingredient selection
    /// becomes a horizontal chip row (one chip per recipe ingredient
    /// + a trailing "Something else" chip); "tell me what's going
    /// on" uses the InputField component so the sheet matches the
    /// rest of the app's grammar instead of reading as a Settings
    /// form. Review finding W-G W30 (FD1).
    private func idleForm(vm: SubstitutionSheetViewModel) -> some View {
        let ingredients = recipePlan.ingredientArray.compactMap { ing -> (UUID, String)? in
            guard let id = ing.id, let name = ing.displayName, !name.isEmpty else { return nil }
            return (id, name)
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                ingredientSection(vm: vm, ingredients: ingredients)
                freeTextSection(vm: vm)
                problemSection(vm: vm)
                Spacer(minLength: CGFloat.Stir.space3)
                PrimaryButton(
                    title: "Find a swap",
                    isDisabled: !vm.canSubmit,
                    action: { Task { await vm.submit() } },
                )
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.vertical, CGFloat.Stir.space4)
        }
        .background(Color.Stir.paper50)
    }

    private func ingredientSection(
        vm: SubstitutionSheetViewModel,
        ingredients: [(UUID, String)],
    ) -> some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("What's missing?")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CGFloat.Stir.space2) {
                    ForEach(ingredients, id: \.0) { id, name in
                        SelectableChip(
                            label: name,
                            tone: .accent,
                            isSelected: vm.selectedIngredientID == id,
                            action: { vm.selectedIngredientID = id },
                        )
                    }
                    SelectableChip(
                        label: "Something else…",
                        tone: .accent,
                        isSelected: vm.selectedIngredientID == nil,
                        action: { vm.selectedIngredientID = nil },
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func freeTextSection(vm: SubstitutionSheetViewModel) -> some View {
        if vm.selectedIngredientID == nil {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                Text("Describe it")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink500)
                InputField(
                    placeholder: "e.g. I don't have a blender",
                    text: Binding(
                        get: { vm.freeTextName },
                        set: { vm.freeTextName = $0 },
                    ),
                    autocapitalization: .sentences,
                )
            }
        }
    }

    private func problemSection(vm: SubstitutionSheetViewModel) -> some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Tell me what's going on (optional)")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ink500)
            InputField(
                placeholder: "e.g. out of heavy cream, only have milk",
                text: Binding(
                    get: { vm.userProblem },
                    set: { vm.userProblem = $0 },
                ),
                autocapitalization: .sentences,
            )
        }
    }

    private var rewritingIndicator: some View {
        VStack(spacing: CGFloat.Stir.space4) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.Stir.ember600)
            Text("Rewriting step…")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
            Text("Updating the instructions to use your substitute.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CGFloat.Stir.space7 - 8) // 40pt
        }
        .padding(CGFloat.Stir.space7 - 8) // 40pt
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
    }

    private var requestingIndicator: some View {
        VStack(spacing: CGFloat.Stir.space4) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.Stir.ember600)
            Text("Checking for a safe swap…")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.ink900)
            Text("We cross-reference your household's dietary rules to avoid anything unsafe.")
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.center)
                .padding(.horizontal, CGFloat.Stir.space7 - 8) // 40pt
        }
        .padding(CGFloat.Stir.space7 - 8) // 40pt
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
    }

    // MARK: - Results

    private func safeResultCard(
        vm: SubstitutionSheetViewModel,
        text: String,
        amountConversion: String?,
        reasoning: String,
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5 - 6) { // 18pt
                HStack(spacing: CGFloat.Stir.space1 + 2) {
                    Image.Stir.success
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    Text("Suggested swap")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(Color.Stir.sage600)

                Text(text)
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                    .fixedSize(horizontal: false, vertical: true)

                if let conversion = amountConversion, !conversion.isEmpty {
                    VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                        Text("Amount")
                            .stirFont(.labelEyebrow)
                            .foregroundStyle(Color.Stir.ink500)
                        Text(conversion)
                            .stirFont(.monoMd)
                            .foregroundStyle(Color.Stir.ink900)
                    }
                }

                VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                    Text("Why this works")
                        .stirFont(.labelEyebrow)
                        .foregroundStyle(Color.Stir.ink500)
                    Text(reasoning)
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink700)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: CGFloat.Stir.space3) {
                    SecondaryButton(title: "Reject") {
                        Task { await vm.reject() }
                    }
                    .accessibilityHint("Dismiss without using this substitute")

                    PrimaryButton(title: "Accept") {
                        Task { await vm.accept() }
                    }
                    .accessibilityHint("Use this substitute in the recipe")
                }
                .padding(.top, CGFloat.Stir.space2)
            }
            .padding(CGFloat.Stir.space5)
        }
        .background(Color.Stir.paper50)
    }

    private func unsafeResultCard(
        vm: SubstitutionSheetViewModel,
        message: String,
        reason: String,
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5 - 6) {
                HStack(spacing: CGFloat.Stir.space1 + 2) {
                    Image.Stir.allergen
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    Text("Can't swap safely")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(Color.Stir.crimson600)

                Text(message)
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                    Text("Why")
                        .stirFont(.labelEyebrow)
                        .foregroundStyle(Color.Stir.ink500)
                    Text(reason)
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink700)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PrimaryButton(title: "OK, I'll pick another option") {
                    Task { await vm.acknowledgeUnsafe() }
                }
                .accessibilityHint("Dismiss and choose a different ingredient")
                .padding(.top, CGFloat.Stir.space2)
            }
            .padding(CGFloat.Stir.space5)
            .stirCard(fill: Color.Stir.crimson100, borderColor: nil)
            .padding(.horizontal, CGFloat.Stir.space5)
            .padding(.vertical, CGFloat.Stir.space4)
        }
        .background(Color.Stir.paper50)
    }

    private func errorCard(vm: SubstitutionSheetViewModel, message: String) -> some View {
        VStack(spacing: CGFloat.Stir.space4) {
            Image.Stir.softError
                .font(.system(size: 34, weight: .regular)) // justification: large-title hero error glyph — one-off per §4.1
                .foregroundStyle(Color.Stir.rust600)
                .accessibilityHidden(true)
            Text(message)
                .stirFont(.bodyLg)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.center)
            HStack(spacing: CGFloat.Stir.space3) {
                SecondaryButton(title: "Close", action: onDismiss)
                PrimaryButton(title: "Try again") {
                    Task { await vm.submit() }
                }
            }
        }
        .padding(CGFloat.Stir.space7 - 8) // 40pt
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
    }
}
