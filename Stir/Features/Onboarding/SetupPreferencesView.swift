// SetupPreferencesView
//
// Step 1 of onboarding (mockup 02 §"Setup 1 — Preferences"). Three
// chip sections: Diet rules (merged Allergies + Diets), Dislikes
// (crimson-toned for the "avoid, not prefer" semantic), and Goals.
// All sections are optional — user can Continue with nothing selected.
//
// Visual grammar:
//   - Custom nav header with Back (ember chevron + label), two-dot
//     progress indicator, Skip affordance (wired in commit 3).
//   - Ember labelEyebrow "STEP 1 OF 2".
//   - displayLg title "A bit about how you eat."
//   - bodyMd subtitle in ink.500.
//   - Three sections, each with labelEyebrow title + bodySm subtitle +
//     chip grid below. Trailing "+ Add" affordance on Dislikes.
//   - PrimaryButton "Continue" in footer with ink.100 top border.
//
// Chip styling: inlined rather than reaching for Phase 2's Chip
// component because the mockup's "selected = checkmark in fg color"
// pattern isn't in the spec §8.2 canonical Chip states. Extending
// Chip for one screen would bloat its API; duplicating ~30 lines of
// chip layout inline keeps Phase 2 stable. If a later mockup reveals
// the checkmark-on-selected pattern as systemic, pull back into Chip.

import SwiftUI

/// One row in the onboarding diet-rules grid. The mockup interleaves
/// diets and allergen-free chips in a single visual list, but the VM
/// keeps them in separate `Set`s so DietaryRule rows preserve their
/// typed kind. This enum carries the mockup-shown label alongside the
/// underlying typed option so the chip render + toggle can stay flat.
/// `Hashable` is auto-synthesized; `ForEach` consumers can use
/// `id: \.self` instead of a hand-rolled identity that ignores the
/// label half of the case.
private enum DietRuleEntry: Hashable {
    case diet(DietOption, label: String)
    case allergen(AllergenOption, label: String)

    var label: String {
        switch self {
        case .diet(_, let label): return label
        case .allergen(_, let label): return label
        }
    }
}

struct SetupPreferencesView: View {
    @Bindable var viewModel: OnboardingViewModel
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    init(
        viewModel: OnboardingViewModel,
        onBack: @escaping () -> Void = {},
        onContinue: @escaping () -> Void,
        onSkip: @escaping () -> Void = {},
    ) {
        self.viewModel = viewModel
        self.onBack = onBack
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    var body: some View {
        VStack(spacing: 0) {
            navHeader
            scrollingBody
            footer
        }
        .background(Color.Stir.paper50)
        .navigationBarBackButtonHidden(true)
    }

    // MARK: - Sections

    private var navHeader: some View {
        HStack(alignment: .center) {
            Button(action: onBack) {
                HStack(spacing: CGFloat.Stir.space1 / 2) { // 2pt
                    Image.Stir.back
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    Text("Back")
                        .stirFont(.labelLg)
                }
                .foregroundStyle(Color.Stir.ember600)
                .frame(minHeight: 44)
                .padding(.horizontal, CGFloat.Stir.space1 + 2) // 6pt
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Back to Welcome")

            Spacer()
            OnboardingProgressDots(current: 1, total: 2)
            Spacer()

            // Skip affordance — visual in commit 2, real behavior in commit 3.
            Button(action: onSkip) {
                Text("Skip")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Skip onboarding")
        }
        .padding(.horizontal, CGFloat.Stir.space3) // 12pt
        .padding(.top, CGFloat.Stir.space2)
        .padding(.bottom, CGFloat.Stir.space3 - 2) // 10pt
    }

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5 - 2) { // 22pt
                stepHeader
                dietRulesSection
                dislikesSection
                goalsSection
            }
            .padding(.horizontal, CGFloat.Stir.screenMarginHero)
            .padding(.top, CGFloat.Stir.space2)
            .padding(.bottom, CGFloat.Stir.space5)
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
            Text("Step 1 of 2")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ember600)

            Text("A bit about how you eat.")
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.ink900)
                .accessibilityAddTraits(.isHeader)

            Text("I'll use these to filter every meal suggestion. You can change them later.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
        }
    }

    /// Curated 8-rule list rendered in mockup 02 order: 3 diets, then 3
    /// allergen-free chips, then 2 more diets. Storage remains split
    /// between `selectedDiets` / `selectedAllergens` in the VM so
    /// DietaryRule rows keep their typed kind on save.
    private static let dietRulesForOnboarding: [DietRuleEntry] = [
        .diet(.vegetarian, label: "vegetarian"),
        .diet(.vegan, label: "vegan"),
        .diet(.pescatarian, label: "pescatarian"),
        .allergen(.gluten, label: "gluten-free"),
        .allergen(.dairy, label: "dairy-free"),
        .allergen(.nut, label: "nut-free"),
        .diet(.halal, label: "halal"),
        .diet(.kosher, label: "kosher"),
    ]

    private static let dislikesForOnboarding: [DislikeOption] = [
        .cilantro, .olives, .mushrooms, .blueCheese, .anchovies,
    ]

    /// Curated 5-goal list. Each entry pairs the GoalOption (which carries
    /// the noun-phrase displayName used by `personalizedBody`) with the
    /// mockup-faithful lowercase chip label. The chip label and the
    /// body-clause label deliberately diverge for verb-phrase mockup
    /// labels — e.g. `.moreVegetables` shows "eat more vegetables" in
    /// the chip but composes "your more vegetables goals" in the body.
    private static let goalsForOnboarding: [(option: GoalOption, chipLabel: String)] = [
        (.quickWeeknights, "quicker weeknights"),
        (.lessFoodWaste,   "less food waste"),
        (.moreVegetables,  "eat more vegetables"),
        (.budget,          "spend less"),
        (.newCuisines,     "cook new cuisines"),
    ]

    private var dietRulesSection: some View {
        OnboardingSection(
            title: "Diet rules",
            subtitle: "Hard rules — I'll never break these.",
        ) {
            ChipFlowLayout(spacing: CGFloat.Stir.space2) {
                ForEach(Self.dietRulesForOnboarding, id: \.self) { entry in
                    SelectableChip(
                        label: entry.label,
                        tone: .accent,
                        isSelected: isDietRuleSelected(entry),
                        action: { toggleDietRule(entry) },
                    )
                }
            }
        }
    }

    private var dislikesSection: some View {
        OnboardingSection(
            title: "Dislikes",
            subtitle: "Strong preferences — I'll avoid unless you override.",
        ) {
            ChipFlowLayout(spacing: CGFloat.Stir.space2) {
                ForEach(Self.dislikesForOnboarding, id: \.self) { opt in
                    SelectableChip(
                        label: opt.displayName.lowercased(),
                        tone: .danger,
                        isSelected: viewModel.selectedDislikes.contains(opt),
                        action: {
                            toggle(opt, in: \.selectedDislikes)
                        },
                    )
                }
                ForEach(Array(viewModel.customDislikes).sorted(), id: \.self) { raw in
                    SelectableChip(
                        label: raw,
                        tone: .danger,
                        isSelected: true,
                        action: {
                            viewModel.customDislikes.remove(raw)
                        },
                    )
                }
                AddDislikePill(viewModel: viewModel)
            }
        }
    }

    private var goalsSection: some View {
        OnboardingSection(
            title: "Goals",
            subtitle: "I'll lean toward these when ranking options.",
        ) {
            ChipFlowLayout(spacing: CGFloat.Stir.space2) {
                ForEach(Self.goalsForOnboarding, id: \.option) { entry in
                    SelectableChip(
                        label: entry.chipLabel,
                        tone: .accent,
                        isSelected: viewModel.selectedGoals.contains(entry.option),
                        action: {
                            toggle(entry.option, in: \.selectedGoals)
                        },
                    )
                }
            }
        }
    }

    private func isDietRuleSelected(_ entry: DietRuleEntry) -> Bool {
        switch entry {
        case .diet(let opt, _):     return viewModel.selectedDiets.contains(opt)
        case .allergen(let opt, _): return viewModel.selectedAllergens.contains(opt)
        }
    }

    private func toggleDietRule(_ entry: DietRuleEntry) {
        switch entry {
        case .diet(let opt, _):     toggle(opt, in: \.selectedDiets)
        case .allergen(let opt, _): toggle(opt, in: \.selectedAllergens)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.Stir.divider)
            HStack(spacing: CGFloat.Stir.space2) {
                PrimaryButton(title: "Continue", action: onContinue)
                    .overlay(alignment: .trailing) {
                        Image.Stir.disclosure
                            .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                            .foregroundStyle(Color.Stir.paper50)
                            .padding(.trailing, CGFloat.Stir.space4)
                    }
            }
            .padding(.horizontal, CGFloat.Stir.screenMarginHero)
            .padding(.top, CGFloat.Stir.space4)
            .padding(.bottom, CGFloat.Stir.space5)
        }
    }

    // MARK: - Mutation helpers

    private func toggle<V: Hashable>(
        _ value: V,
        in keyPath: ReferenceWritableKeyPath<OnboardingViewModel, Set<V>>,
    ) {
        if viewModel[keyPath: keyPath].contains(value) {
            viewModel[keyPath: keyPath].remove(value)
        } else {
            viewModel[keyPath: keyPath].insert(value)
        }
    }
}

// MARK: - OnboardingProgressDots

/// Two-dot progress indicator — current dot is 20pt wide ember pill,
/// others are 6pt ink.100 circles. Matches mockup 02 top-of-header
/// indicator. Sized for 2 dots; trivially extensible if onboarding
/// grows to 3+ steps.
struct OnboardingProgressDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: CGFloat.Stir.space1 + 2) { // 6pt
            ForEach(1 ... total, id: \.self) { step in
                Capsule(style: .continuous)
                    .fill(step <= current
                          ? Color.Stir.ember600
                          : Color.Stir.ink100)
                    .frame(
                        width: step == current ? 20 : 6,
                        height: 6,
                    )
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

// MARK: - OnboardingSection

private struct OnboardingSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) { // 2pt
                Text(title)
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink700)
                Text(subtitle)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ink500)
            }
            content()
        }
    }
}

// MARK: - AddDislikePill

/// Dashed-border "+ Add" affordance to capture a free-text dislike.
/// Presents an inline sheet with a single InputField; on submit,
/// calls `viewModel.addCustomDislike(_:)` which normalizes + length-
/// caps + folds-to-predefined. Rejected inputs surface no error text —
/// the user sees the sheet close and no new chip appear, which the
/// trim+fold path makes unambiguous (empty → nothing added, fold →
/// the matching predefined chip toggles instead).
private struct AddDislikePill: View {
    @Bindable var viewModel: OnboardingViewModel
    @State private var isPresenting = false
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            draft = ""
            isPresenting = true
        } label: {
            HStack(spacing: CGFloat.Stir.space1 + 2) { // 6pt
                Image.Stir.plus
                    .font(.system(size: 12, weight: .semibold)) // justification: inline-plus sized to match mockup 02's "+ Add" chip glyph
                    .foregroundStyle(Color.Stir.ink500)
                Text("Add")
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.ink500)
            }
            .padding(.horizontal, CGFloat.Stir.space3 + 2) // 14pt
            .padding(.vertical, CGFloat.Stir.space2 + 1)   // 9pt
            .frame(minHeight: 44)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.Stir.ink300,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]),
                    ),
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a custom dislike")
        .sheet(isPresented: $isPresenting) {
            addSheet
                .presentationDetents([.height(200)])
                .presentationDragIndicator(.visible)
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            Text("What should I avoid?")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)

            InputField(
                placeholder: "e.g. cilantro, anchovies",
                text: $draft,
                isFocused: isFocused,
                autocapitalization: .never,
                submitLabel: .done,
                onSubmit: submit,
            )
            .focused($isFocused)

            PrimaryButton(
                title: "Add",
                isDisabled: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: submit,
            )
        }
        .padding(CGFloat.Stir.space4)
        .onAppear { isFocused = true }
    }

    private func submit() {
        // Try folding into predefined first.
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let match = DislikeOption.allCases.first(where: {
            $0.rawValue == trimmed || $0.displayName.lowercased() == trimmed
        }) {
            viewModel.selectedDislikes.insert(match)
        } else {
            viewModel.addCustomDislike(draft)
        }
        isPresenting = false
        draft = ""
    }
}

// `ChipFlowLayout` was hosted here pre-SCA-28; promoted to
// `Stir/DesignSystem/Components/ChipFlowLayout.swift` once the SCA-19
// pbxproj touch satisfied its own deferred-promotion trigger.

// Previews omitted — OnboardingViewModel requires a HouseholdProfile
// attached to a live NSPersistentCloudKitContainer, and no preview
// PersistenceController fixture exists yet. Adding one is a cross-
// cutting infra change that would touch every feature's preview
// surface; deferring to a dedicated preview-infra task rather than
// gating this turn on it. Actual screen verification is via sim run
// (xcodebuild + launch) per Q8.
