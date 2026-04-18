// OnboardingViewModel
//
// Step-2 onboarding VM. Backed by an already-created `HouseholdProfile`
// (pre-created at app launch by RootCoordinator; see commit 9 + the
// Round-1 Q4 decision). Buffers user toggles in-memory; writes to
// Core Data happen only on `savePreferences()` / `saveKitchen()` /
// `completeOnboarding()`.

import Foundation
import Observation

@MainActor
@Observable
final class OnboardingViewModel {
    // MARK: - Dependencies

    let profile: HouseholdProfile
    private let dietaryRepo: DietaryRuleRepository
    private let equipmentRepo: KitchenEquipmentRepository
    private let profileRepo: HouseholdProfileRepository

    // MARK: - Setup 1 state (preferences)

    var selectedAllergens: Set<AllergenOption> = []
    var selectedDiets: Set<DietOption> = []
    var selectedGoals: Set<GoalOption> = []

    // MARK: - Setup 2 state (kitchen + servings)

    var selectedEquipment: Set<KitchenEquipment.CommonCode> = []
    var servingsDefault: Int16 = 2
    var preferredUnits: HouseholdProfile.PreferredUnits = .imperial

    // MARK: - Error surface

    var errorMessage: String?

    // MARK: - Init

    init(
        profile: HouseholdProfile,
        dietaryRepo: DietaryRuleRepository = DietaryRuleRepository(),
        equipmentRepo: KitchenEquipmentRepository = KitchenEquipmentRepository(),
        profileRepo: HouseholdProfileRepository = HouseholdProfileRepository(),
    ) {
        self.profile = profile
        self.dietaryRepo = dietaryRepo
        self.equipmentRepo = equipmentRepo
        self.profileRepo = profileRepo

        // Hydrate setup 2 defaults from existing profile (in case user is
        // re-running onboarding after a mid-flow kill).
        self.servingsDefault = profile.servingsDefault > 0 ? profile.servingsDefault : 2
        self.preferredUnits = profile.typedPreferredUnits

        // Hydrate setup 1 selections from already-saved DietaryRules
        // (same "resume where left off" motivation).
        for rule in profile.dietaryRuleArray where rule.isActive {
            switch rule.typedKind {
            case .allergy:
                if let raw = rule.value, let opt = AllergenOption(rawValue: raw) {
                    selectedAllergens.insert(opt)
                }
            case .diet:
                if let raw = rule.value, let opt = DietOption(rawValue: raw) {
                    selectedDiets.insert(opt)
                }
            case .goal:
                if let raw = rule.value, let opt = GoalOption(rawValue: raw) {
                    selectedGoals.insert(opt)
                }
            case .dislike, .none:
                break
            }
        }

        // Hydrate equipment selection.
        for equipment in profile.kitchenEquipmentArray where equipment.isAvailable {
            if let typed = equipment.typedCode {
                selectedEquipment.insert(typed)
            }
        }
    }

    // MARK: - Validation

    /// Setup 2 requires servingsDefault ≥ 1 (guard against users clearing it).
    var canCompleteKitchenStep: Bool {
        servingsDefault >= 1 && servingsDefault <= 12
    }

    // MARK: - Writes

    /// Commit preferences (allergens/diets/goals) to Core Data.
    /// Idempotent — re-runs on back-then-forward are safe.
    func savePreferences() throws {
        // Deactivate any existing rules that are no longer selected.
        for rule in profile.dietaryRuleArray where rule.isActive {
            let stillSelected: Bool
            switch rule.typedKind {
            case .allergy:
                stillSelected = rule.value.flatMap(AllergenOption.init(rawValue:))
                    .map(selectedAllergens.contains) ?? false
            case .diet:
                stillSelected = rule.value.flatMap(DietOption.init(rawValue:))
                    .map(selectedDiets.contains) ?? false
            case .goal:
                stillSelected = rule.value.flatMap(GoalOption.init(rawValue:))
                    .map(selectedGoals.contains) ?? false
            case .dislike, .none:
                stillSelected = false
            }
            if !stillSelected {
                try dietaryRepo.deactivate(rule)
            }
        }

        // Add newly-selected rules.
        for opt in selectedAllergens {
            try dietaryRepo.add(
                to: profile, kind: .allergy, value: opt.rawValue, severity: .hard,
            )
        }
        for opt in selectedDiets {
            try dietaryRepo.add(
                to: profile, kind: .diet, value: opt.rawValue, severity: .hard,
            )
        }
        for opt in selectedGoals {
            try dietaryRepo.add(
                to: profile, kind: .goal, value: opt.rawValue, severity: .soft,
            )
        }
    }

    /// Commit kitchen + servings to Core Data.
    func saveKitchen() throws {
        // Flip each kitchen code's availability based on current selection.
        // setAvailability() is idempotent.
        for code in KitchenEquipment.CommonCode.allCases {
            try equipmentRepo.setAvailability(
                selectedEquipment.contains(code), code: code, on: profile,
            )
        }

        try profileRepo.update(
            profile,
            servingsDefault: servingsDefault,
            preferredUnits: preferredUnits,
        )
    }

    /// Final step: mark onboardingCompleted = true. Caller (usually the
    /// Setup 2 Continue handler) saves preferences + kitchen first.
    func completeOnboarding() throws {
        try profileRepo.markOnboardingComplete(profile)
    }
}
