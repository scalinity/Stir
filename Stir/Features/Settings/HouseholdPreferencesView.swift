// HouseholdPreferencesView
//
// Settings → Household preferences. Edits the same three sections as
// onboarding (allergens/diets/goals + equipment + servings/units),
// rebuilt 2026-04-28 onto the custom Stir design system to match
// `SettingsRootView`'s grouped-card grammar.
//
// Pre-rebuild visual issues (see attached screenshot):
//   - Title "Household prefe…" truncated by a redundant `Done`
//     toolbar button competing for trailing space.
//   - Tapping `Done` and tapping the back chevron both `dismiss()`'d
//     after writing changes — `Done` was redundant. The persistence
//     model assumed "save once at end of onboarding," but for a
//     settings-edit reuse, iOS convention is auto-save-on-change.
//   - The `Form` body inherited iOS's grey grouped background and
//     SF Pro section headers, drifting from `SettingsRootView`'s
//     paper50 + serif principal title + `stirCard()` rows.
//
// Rebuild posture:
//   - Auto-save on every binding change. `OnboardingViewModel`'s
//     `savePreferences()` and `saveKitchen()` are both documented as
//     idempotent (repo-layer `deactivate`/`add`/`setAvailability`),
//     so calling them on each chip toggle / stepper increment is
//     safe and removes the need for an explicit `Done` commit.
//   - Drop the `Done` toolbar button entirely. The back chevron is
//     the only dismissal affordance, matching iOS Settings convention.
//   - Apply the `SettingsRootView` design system: ScrollView + grouped
//     `stirCard()` rows, principal-toolbar New York title, paper50
//     toolbar background, 64pt bottom inset for the floating tab bar.
//   - Picker sub-screens (Allergies / Diet / Goals / Equipment) get
//     the same DS treatment so the back-stack reads as one continuous
//     surface, not "Settings → Settings → iOS-default-list".

import OSLog
import SwiftUI

struct HouseholdPreferencesView: View {
    @Environment(CurrentHouseholdStore.self) private var householdStore
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: OnboardingViewModel?
    @State private var initError: String?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let viewModel {
                contentView(viewModel: viewModel)
            } else if let initError {
                // Profile wasn't available when the view appeared —
                // surfaces a Close affordance rather than a perpetual
                // spinner. Root coordinator is expected to bootstrap a
                // profile before this screen is navigable, but the
                // user-visible copy covers the unlikely race where
                // Settings opens pre-bootstrap (e.g. deeplink launch).
                // Review finding W-H W37 (CA2).
                ConfigurationErrorView(message: initError, onRetry: { dismiss() })
                    .background(Color.Stir.paper50)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.Stir.paper50)
            }
        }
        .navigationTitle("Household preferences")
        .navigationBarTitleDisplayMode(.inline)
        // Principal-item title in the Stir display serif via the lifted
        // `.stirNavigationTitle` modifier (SCA-95). Pairs with the
        // `.inline` display mode above; both are required because the
        // system bar renders the navigationTitle text and we then layer
        // a serif-styled principal item on top to match `SettingsRootView`
        // and Saved. Removing the trailing `Done` button (auto-save
        // replaces it) frees the bar's full width so this title no
        // longer truncates.
        .stirNavigationTitle("Household preferences")
        .task {
            guard viewModel == nil else { return }
            if let profile = householdStore.profile {
                viewModel = OnboardingViewModel(profile: profile)
            } else {
                initError = "Couldn't load your preferences. Please try again."
                Logger.ui.error("HouseholdPreferencesView: householdStore.profile unexpectedly nil")
                SentryReporter.shared.captureError(
                    StirError.validation(
                        fieldErrors: [FieldError(field: "household_profile", issue: "nil at HouseholdPreferencesView task")],
                        message: "HouseholdPreferencesView profile nil",
                    ),
                    context: ["screen": "household_preferences"],
                )
            }
        }
        .alert("Couldn't save", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } },
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func contentView(viewModel: OnboardingViewModel) -> some View {
        @Bindable var bindable = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                dietarySection(viewModel: viewModel)
                equipmentSection(viewModel: viewModel)
                servingsSection(viewModel: viewModel)
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            // Match `SettingsRootView` clearance for the −14pt-encroach
            // floating `StirCustomTabBar`. This view is pushed inside
            // the Settings tab's NavigationStack, so the floating bar
            // is still visible behind it.
            .padding(.bottom, CGFloat.Stir.space7 + CGFloat.Stir.space4) // 64pt
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        // Auto-save on every binding write. `savePreferences()` +
        // `saveKitchen()` are documented idempotent at the repo
        // layer (`deactivate`/`add`/`setAvailability` all guard
        // for existing state). Calling them on each change is the
        // mechanism that lets the redundant `Done` button go away.
        // `.onChange` doesn't fire on initial mount, so the hydrate-
        // from-profile assignment in `.task` doesn't trigger spurious
        // writes.
        .onChange(of: bindable.selectedAllergens) { _, _ in saveAll(viewModel) }
        .onChange(of: bindable.selectedDiets) { _, _ in saveAll(viewModel) }
        .onChange(of: bindable.selectedGoals) { _, _ in saveAll(viewModel) }
        .onChange(of: bindable.selectedEquipment) { _, _ in saveAll(viewModel) }
        .onChange(of: bindable.servingsDefault) { _, _ in saveAll(viewModel) }
        .onChange(of: bindable.preferredUnits) { _, _ in saveAll(viewModel) }
    }

    @MainActor
    private func saveAll(_ viewModel: OnboardingViewModel) {
        do {
            try viewModel.savePreferences()
            try viewModel.saveKitchen()
        } catch {
            errorMessage = ErrorPresenter.present(.sync01).message
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func dietarySection(viewModel: OnboardingViewModel) -> some View {
        // `@Bindable` must be re-declared in any scope that wants to
        // use `$projection` syntax — it doesn't propagate across
        // function boundaries (the wrappedValue would, but the
        // projection is scope-local).
        @Bindable var bindable = viewModel
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            SectionEyebrow("Dietary")
            VStack(spacing: 0) {
                navigationValueRow(
                    title: "Allergies",
                    value: countLabel(bindable.selectedAllergens.count),
                    destination: {
                        pickerScreen(
                            title: "Allergies",
                            options: AllergenOption.allCases,
                            selection: $bindable.selectedAllergens,
                            label: { $0.displayName },
                        )
                    },
                )
                StirRowDivider()
                navigationValueRow(
                    title: "Diet",
                    value: countLabel(bindable.selectedDiets.count),
                    destination: {
                        pickerScreen(
                            title: "Diet",
                            options: DietOption.allCases,
                            selection: $bindable.selectedDiets,
                            label: { $0.displayName },
                        )
                    },
                )
                StirRowDivider()
                navigationValueRow(
                    title: "Goals",
                    value: countLabel(bindable.selectedGoals.count),
                    destination: {
                        pickerScreen(
                            title: "Goals",
                            options: GoalOption.allCases,
                            selection: $bindable.selectedGoals,
                            label: { $0.displayName },
                        )
                    },
                )
            }
            .stirCard()
        }
    }

    @ViewBuilder
    private func equipmentSection(viewModel: OnboardingViewModel) -> some View {
        @Bindable var bindable = viewModel
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            SectionEyebrow("Equipment")
            navigationValueRow(
                title: "Equipment",
                value: countLabel(bindable.selectedEquipment.count),
                destination: {
                    pickerScreen(
                        title: "Equipment",
                        options: KitchenEquipment.CommonCode.allCases,
                        selection: $bindable.selectedEquipment,
                        label: { $0.displayName },
                    )
                },
            )
            .stirCard()
        }
    }

    @ViewBuilder
    private func servingsSection(viewModel: OnboardingViewModel) -> some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            SectionEyebrow("Serving")
            VStack(spacing: 0) {
                servingsStepperRow(viewModel: viewModel)
                StirRowDivider()
                unitsPickerRow(viewModel: viewModel)
            }
            .stirCard()
        }
    }

    private func servingsStepperRow(viewModel: OnboardingViewModel) -> some View {
        @Bindable var bindable = viewModel
        // SwiftUI `Stepper` renders its label on the leading edge and
        // the −/+ buttons on the trailing edge — exactly the row shape
        // mockup 14's Household stepper card asks for. We pass an
        // empty hidden label and provide our own `Text` so we control
        // the typography.
        return HStack(spacing: CGFloat.Stir.space3) {
            Text("\(bindable.servingsDefault) \(bindable.servingsDefault == 1 ? "person" : "people")")
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.textPrimary)
            Spacer(minLength: CGFloat.Stir.space2)
            Stepper("", value: $bindable.servingsDefault, in: 1...12)
                .labelsHidden()
                .accessibilityLabel("Default servings")
                .accessibilityValue("\(bindable.servingsDefault) \(bindable.servingsDefault == 1 ? "person" : "people")")
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3Half)
    }

    private func unitsPickerRow(viewModel: OnboardingViewModel) -> some View {
        @Bindable var bindable = viewModel
        return Picker("Preferred units", selection: $bindable.preferredUnits) {
            Text("Imperial").tag(HouseholdProfile.PreferredUnits.imperial)
            Text("Metric").tag(HouseholdProfile.PreferredUnits.metric)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3Half)
        .accessibilityLabel("Preferred units")
    }

    // MARK: - Picker sub-screen

    /// Multi-select picker reached by tapping any dietary / equipment
    /// row. Same paper50 + grouped-card grammar as the parent, so
    /// drilling in feels continuous rather than dropping back to
    /// iOS-default `List`.
    @ViewBuilder
    private func pickerScreen<Value: Hashable>(
        title: String,
        options: [Value],
        selection: Binding<Set<Value>>,
        label: @escaping (Value) -> String,
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                VStack(spacing: 0) {
                    ForEach(options.indices, id: \.self) { i in
                        if i > 0 { StirRowDivider() }
                        let option = options[i]
                        pickerRow(
                            label: label(option),
                            isSelected: selection.wrappedValue.contains(option),
                        ) {
                            if selection.wrappedValue.contains(option) {
                                selection.wrappedValue.remove(option)
                            } else {
                                selection.wrappedValue.insert(option)
                            }
                        }
                    }
                }
                .stirCard()
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            .padding(.bottom, CGFloat.Stir.space7 + CGFloat.Stir.space4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .stirNavigationTitle(title)
    }

    private func pickerRow(
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: CGFloat.Stir.space3) {
                Text(label)
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.textPrimary)
                Spacer(minLength: CGFloat.Stir.space2)
                if isSelected {
                    Image.Stir.check
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                        .foregroundStyle(Color.Stir.ember600)
                }
            }
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Drill-in row primitives

    /// Static value-row content for navigation-link drill-ins:
    /// title (leading) + value preview + chevron (trailing). No
    /// leading icon tile — detail-screen rows in mockup 14 are
    /// label-only, distinct from Settings home rows which have
    /// ember-tinted glyph tiles.
    private func valueRowContent(title: String, value: String) -> some View {
        HStack(spacing: CGFloat.Stir.space3) {
            Text(title)
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.textPrimary)
            Spacer(minLength: CGFloat.Stir.space2)
            Text(value)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textTertiary)
            Image.Stir.disclosure
                .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                .foregroundStyle(Color.Stir.ink300)
        }
        .padding(.horizontal, CGFloat.Stir.space3Half)
        .padding(.vertical, CGFloat.Stir.space3Half)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Wraps `valueRowContent` in a `NavigationLink` push.
    @ViewBuilder
    private func navigationValueRow<Destination: View>(
        title: String,
        value: String,
        @ViewBuilder destination: () -> Destination,
    ) -> some View {
        NavigationLink(destination: destination) {
            valueRowContent(title: title, value: value)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func countLabel(_ count: Int) -> String {
        count == 0 ? "None" : "\(count) selected"
    }
}
