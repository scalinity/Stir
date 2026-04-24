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

    // MARK: - Custom dislike normalization (W-B W8 + W9)

    func test_normalizeCustomDislike_trimsAndLowercases() throws {
        let vm = makeVM()
        // Deliberately NOT a curated DislikeOption so the fold branch
        // doesn't short-circuit the result.
        XCTAssertEqual(vm.normalizeCustomDislike("  RutaBaga  "), "rutabaga")
    }

    func test_normalizeCustomDislike_rejectsEmpty() throws {
        let vm = makeVM()
        XCTAssertNil(vm.normalizeCustomDislike(""))
        XCTAssertNil(vm.normalizeCustomDislike("   "))
        XCTAssertNil(vm.normalizeCustomDislike("\n\t "))
    }

    func test_normalizeCustomDislike_stripsUnicodeHazards() throws {
        let vm = makeVM()
        // Zero-width space + bidi RLE — both should be stripped and
        // the underlying text preserved. Picks a non-curated label so
        // the fold-to-curated branch doesn't short-circuit.
        let input = "ok\u{200B}r\u{202A}a"
        XCTAssertEqual(vm.normalizeCustomDislike(input), "okra")
    }

    func test_normalizeCustomDislike_rejectsAllHazardInput() throws {
        let vm = makeVM()
        let pureHazards = "\u{200B}\u{202A}\u{202E}\u{FEFF}"
        // After strip, nothing remains — should fall through to empty-nil.
        XCTAssertNil(vm.normalizeCustomDislike(pureHazards))
    }

    func test_normalizeCustomDislike_enforcesGraphemeCap() throws {
        let vm = makeVM()
        let tooLong = String(repeating: "a", count: 33) // 33 > customDislikeMaxLength=32
        XCTAssertNil(vm.normalizeCustomDislike(tooLong))
        let atCap = String(repeating: "a", count: 32)
        XCTAssertEqual(vm.normalizeCustomDislike(atCap), atCap)
    }

    func test_normalizeCustomDislike_enforcesByteCap() throws {
        let vm = makeVM()
        // 22 CJK ideographs = 66 bytes (UTF-8), which exceeds the
        // 64-byte cap even though grapheme count is well under 32.
        let cjkOverByteCap = String(repeating: "字", count: 22)
        XCTAssertEqual(cjkOverByteCap.count, 22)
        XCTAssertGreaterThan(cjkOverByteCap.utf8.count, 64)
        XCTAssertNil(vm.normalizeCustomDislike(cjkOverByteCap))
    }

    func test_normalizeCustomDislike_foldsToCuratedOption() throws {
        let vm = makeVM()
        // "cilantro" is a curated DislikeOption rawValue — normalizer
        // returns nil so the caller can insert selectedDislikes directly.
        XCTAssertNil(vm.normalizeCustomDislike("Cilantro"))
    }

    // MARK: - addCustomDislike

    func test_addCustomDislike_acceptsAndStoresNormalized() throws {
        let vm = makeVM()
        XCTAssertTrue(vm.addCustomDislike("  OKRA  "))
        XCTAssertTrue(vm.customDislikes.contains("okra"))
    }

    func test_addCustomDislike_rejectsInvalid() throws {
        let vm = makeVM()
        XCTAssertFalse(vm.addCustomDislike(""))
        XCTAssertFalse(vm.addCustomDislike(String(repeating: "x", count: 33)))
        XCTAssertFalse(vm.addCustomDislike("Cilantro")) // folds to curated
        XCTAssertTrue(vm.customDislikes.isEmpty)
    }

    func test_addCustomDislike_capsSetCardinality() throws {
        let vm = makeVM()
        // Fill to exactly the cap.
        for i in 0 ..< OnboardingViewModel.customDislikesMaxCount {
            XCTAssertTrue(vm.addCustomDislike("item\(i)"))
        }
        XCTAssertEqual(vm.customDislikes.count, OnboardingViewModel.customDislikesMaxCount)
        // One past cap — refused.
        XCTAssertFalse(vm.addCustomDislike("item-overflow"))
        // Re-adding an existing member is still true (set insert is a no-op).
        XCTAssertTrue(vm.addCustomDislike("item0"))
    }

    // MARK: - Dislike hydration (W-B W11)

    func test_dislikeHydration_caseInsensitivelyFoldsToCuratedOption() async throws {
        let firstVM = makeVM()
        // Simulate a legacy row written with uppercase rawValue. Add via
        // savePreferences + direct write of a custom uppercase string.
        firstVM.customDislikes = ["CILANTRO"]
        try firstVM.savePreferences()

        // Re-instantiate — hydration should recognize "CILANTRO" as
        // curated and route it into `selectedDislikes`, not customs.
        let secondVM = makeVM()
        XCTAssertTrue(secondVM.selectedDislikes.contains(.cilantro))
        XCTAssertFalse(secondVM.customDislikes.contains("CILANTRO"))
        XCTAssertFalse(secondVM.customDislikes.contains("cilantro"))
    }

    // MARK: - recordSkip idempotency

    func test_recordSkip_isIdempotent() throws {
        let vm = makeVM()
        vm.recordSkip(over: "setup_kitchen")
        vm.recordSkip(over: "setup_kitchen") // should be a no-op
        vm.recordSkip(over: "setup_preferences")
        // Order preserved; duplicate kitchen entry suppressed.
        XCTAssertEqual(vm.skippedSteps, ["setup_kitchen", "setup_preferences"])
    }

    // MARK: - fireOnboardingCompletedEvent idempotency (W-A W7)

    func test_fireOnboardingCompletedEvent_isIdempotent() throws {
        let vm = makeVM()
        XCTAssertFalse(vm.hasFiredCompletedEvent)
        vm.fireOnboardingCompletedEvent()
        XCTAssertTrue(vm.hasFiredCompletedEvent)
        // Second call early-returns — flag stays true, nothing explodes.
        vm.fireOnboardingCompletedEvent()
        XCTAssertTrue(vm.hasFiredCompletedEvent)
    }

    // MARK: - personalizedBody clause composition (W-A W6)

    func test_personalizedBody_allEmpty_usesGenericFallback() throws {
        let vm = makeVM()
        let body = vm.personalizedBody
        XCTAssertTrue(body.contains("sensible defaults"))
    }

    func test_personalizedBody_dietsOnly() throws {
        let vm = makeVM()
        vm.selectedDiets = [.vegetarian]
        let body = vm.personalizedBody
        XCTAssertTrue(body.contains("vegetarian diet"))
        XCTAssertFalse(body.contains("keeping"))
        XCTAssertFalse(body.contains("avoiding"))
    }

    func test_personalizedBody_fourAxisCompose() throws {
        let vm = makeVM()
        vm.selectedDiets = [.vegetarian]
        vm.selectedAllergens = [.peanut]
        vm.selectedDislikes = [.cilantro]
        vm.selectedGoals = [.highProtein]
        let body = vm.personalizedBody
        // All four clauses present.
        XCTAssertTrue(body.contains("vegetarian diet"))
        XCTAssertTrue(body.contains("keeping peanut out"))
        XCTAssertTrue(body.contains("avoiding cilantro"))
        XCTAssertTrue(body.contains("high protein goals"))
        // 4-part "..., ..., ..., and ..." grammar.
        XCTAssertTrue(body.contains(", and "))
    }

    func test_personalizedBody_allergensLabeledDistinctFromDiets() throws {
        let vm = makeVM()
        vm.selectedAllergens = [.dairy]
        let body = vm.personalizedBody
        // Dairy should NOT be described as "your dairy diet" — allergens
        // have a distinct "keeping ... out" framing. W-A W6.
        XCTAssertFalse(body.contains("dairy diet"))
        XCTAssertTrue(body.contains("keeping dairy out"))
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
