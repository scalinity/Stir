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
                    Button {
                        Task { await vm.reject() }
                    } label: {
                        Label("Reject", systemImage: "xmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Dismiss without using this substitute")

                    Button {
                        Task { await vm.accept() }
                    } label: {
                        Label("Accept", systemImage: "checkmark")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Use this substitute in the recipe")
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
                .accessibilityHint("Dismiss and choose a different ingredient")
                .padding(.top, 8)
            }
            .padding(20)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func errorCard(vm: SubstitutionSheetViewModel, message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    onDismiss()
                } label: {
                    Text("Close")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                Button {
                    Task { await vm.submit() }
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}
