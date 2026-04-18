// OnboardingViewModelTests
//
// Covers:
//   - servingsDefault validation (can't complete with 0 or >12)
//   - resume-where-you-left-off on second instantiation
//   - savePreferences + saveKitchen + completeOnboarding persistence

import CoreData
import XCTest
@testable import Stir

@MainActor
final class OnboardingViewModelTests: XCTestCase {
    private var controller: PersistenceController!
    private var profile: HouseholdProfile!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        profile = try repo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
    }

    func test_defaultServings_isValid() async throws {
        let vm = OnboardingViewModel(
            profile: profile,
            dietaryRepo: DietaryRuleRepository(controller: controller),
            equipmentRepo: KitchenEquipmentRepository(controller: controller),
            profileRepo: HouseholdProfileRepository(controller: controller),
        )
        XCTAssertEqual(vm.servingsDefault, 2)
        XCTAssertTrue(vm.canCompleteKitchenStep)
    }

    func test_zeroServings_blocksCompletion() async throws {
        let vm = makeVM()
        vm.servingsDefault = 0
        XCTAssertFalse(vm.canCompleteKitchenStep)
    }

    func test_thirteenServings_blocksCompletion() async throws {
        let vm = makeVM()
        vm.servingsDefault = 13
        XCTAssertFalse(vm.canCompleteKitchenStep)
    }

    func test_savePreferences_persistsAllergenAsDietaryRule() async throws {
        let vm = makeVM()
        vm.selectedAllergens = [.peanut, .dairy]
        try vm.savePreferences()

        let rules = profile.dietaryRuleArray.filter { $0.isActive }
        let allergyRules = rules.filter { $0.typedKind == .allergy }
        XCTAssertEqual(allergyRules.count, 2)
        XCTAssertTrue(allergyRules.allSatisfy { $0.typedSeverity == .hard })
    }

    func test_savePreferences_deactivatesDeselectedRules() async throws {
        // First pass: select peanut.
        let firstVM = makeVM()
        firstVM.selectedAllergens = [.peanut]
        try firstVM.savePreferences()

        // Second pass: deselect peanut, select dairy.
        let secondVM = makeVM()
        XCTAssertEqual(secondVM.selectedAllergens, [.peanut]) // resumed state
        secondVM.selectedAllergens = [.dairy]
        try secondVM.savePreferences()

        let active = profile.dietaryRuleArray.filter { $0.isActive && $0.typedKind == .allergy }
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.value, "dairy")
    }

    func test_saveKitchen_persistsEquipmentAndServings() async throws {
        let vm = makeVM()
        vm.selectedEquipment = [.oven, .instantPot, .airFryer]
        vm.servingsDefault = 4
        vm.preferredUnits = .metric
        try vm.saveKitchen()

        XCTAssertEqual(profile.servingsDefault, 4)
        XCTAssertEqual(profile.typedPreferredUnits, .metric)

        let active = profile.kitchenEquipmentArray.filter { $0.isAvailable }
        XCTAssertEqual(active.count, 3)
        let codes = Set(active.compactMap { $0.typedCode })
        XCTAssertEqual(codes, [.oven, .instantPot, .airFryer])
    }

    func test_completeOnboarding_setsFlag() async throws {
        let vm = makeVM()
        try vm.completeOnboarding()
        XCTAssertTrue(profile.onboardingCompleted)
    }

    // MARK: - Helpers

    private func makeVM() -> OnboardingViewModel {
        OnboardingViewModel(
            profile: profile,
            dietaryRepo: DietaryRuleRepository(controller: controller),
            equipmentRepo: KitchenEquipmentRepository(controller: controller),
            profileRepo: HouseholdProfileRepository(controller: controller),
        )
    }
}
