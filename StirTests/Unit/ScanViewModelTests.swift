// ScanViewModelTests
//
// Exercises the synchronous review-phase state transitions without
// spinning up AIDispatch:
//   - editIngredient flips confidence to confirmed
//   - deleteIngredient removes by id
//   - addIngredientManually appends a confirmed item
//   - resetToPrimer clears state
//
// Parse-phase tests that actually call AIDispatch require a mock
// server and are gated behind STIR_RUN_AI_INTEGRATION_TESTS in the
// backend tests; ViewModel-side parse paths are not retested here.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class ScanViewModelTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let repo = HouseholdProfileRepository(controller: controller)
        household = try repo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
    }

    private func makeVM(
        tier: Tier = .free,
        presentPaywall: (@MainActor (PaywallTrigger) -> Void)? = nil,
    ) -> ScanViewModel {
        // Use a placeholder AppConfig-free AIDispatch by wiring through a
        // real SupabaseSessionClient. None of the tests below call the
        // network path; we only need a non-nil reference.
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil,
            sentry: nil,
            revenueCat: nil,
            build: "1.0.0 (1)",
            osVersion: "17.5",
        )
        let session = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: .shared,
            sentry: NoOpSentryReporter(),
        )
        let ai = AIDispatch(session: session, config: config)
        let store = CurrentHouseholdStore()
        store.set(household)
        let entitlements = EntitlementService(keychain: MockKeychain())
        if tier != .free {
            entitlements.hydrate(from: BootstrapResponse.Entitlements(
                tier: tier,
                billingState: .active,
                isTrial: false,
                expiresAt: nil,
                voiceEnabled: tier != .free,
                billingRetryBanner: false,
                standingPantryCap: nil,
                quotas: [],
            ))
        }
        return ScanViewModel(
            aiDispatch: ai,
            pantryRepo: PantryItemRepository(controller: controller),
            householdStore: store,
            entitlements: entitlements,
            presentPaywall: presentPaywall,
        )
    }

    func test_editIngredient_flipsConfidenceToConfirmed() {
        let vm = makeVM()
        let id = UUID()
        vm.__injectForTests(ingredients: [
            .init(id: id, displayName: "tomato", confidence: .needsReview),
        ])
        vm.editIngredient(id: id, newName: "Roma tomato")
        XCTAssertEqual(vm.ingredients.first?.displayName, "Roma tomato")
        XCTAssertEqual(vm.ingredients.first?.confidence, .confirmed)
    }

    func test_deleteIngredient_removesById() {
        let vm = makeVM()
        let a = UUID()
        let b = UUID()
        vm.__injectForTests(ingredients: [
            .init(id: a, displayName: "tomato", confidence: .confirmed),
            .init(id: b, displayName: "basil", confidence: .confirmed),
        ])
        vm.deleteIngredient(id: a)
        XCTAssertEqual(vm.ingredients.count, 1)
        XCTAssertEqual(vm.ingredients.first?.displayName, "basil")
    }

    func test_addIngredientManually_appendsConfirmed() {
        let vm = makeVM()
        vm.addIngredientManually("olive oil")
        XCTAssertEqual(vm.ingredients.count, 1)
        XCTAssertEqual(vm.ingredients.first?.displayName, "olive oil")
        XCTAssertEqual(vm.ingredients.first?.confidence, .confirmed)
    }

    func test_addIngredientManually_ignoresWhitespaceOnlyName() {
        let vm = makeVM()
        vm.addIngredientManually("   ")
        XCTAssertEqual(vm.ingredients.count, 0)
    }

    func test_resetToPrimer_clearsState() {
        let vm = makeVM()
        vm.__injectForTests(ingredients: [
            .init(id: UUID(), displayName: "x", confidence: .confirmed),
        ])
        vm.resetToPrimer()
        XCTAssertEqual(vm.ingredients.count, 0)
        XCTAssertEqual(vm.phase, .idle)
        XCTAssertNil(vm.parseID)
    }

    // MARK: - SCA-35 multi-image accumulator

    /// Synthetic JPEG bytes — magic bytes only, plus filler. Real
    /// validation happens server-side; the VM doesn't decode these.
    private func fakeJPEG(byte: UInt8 = 0xAA) -> Data {
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF]
        bytes.append(contentsOf: Array(repeating: byte, count: 256))
        return Data(bytes)
    }

    func test_appendCapturedImage_firstShotAppendsForFreeTier() {
        let vm = makeVM(tier: .free)
        let result = vm.appendCapturedImage(fakeJPEG(), mimeType: "image/jpeg")
        XCTAssertEqual(result, .appended)
        XCTAssertEqual(vm.capturedImages.count, 1)
    }

    func test_appendCapturedImage_secondShotBlockedForFreeTier_firesPaywall() {
        var paywallTriggers: [PaywallTrigger] = []
        let vm = makeVM(tier: .free, presentPaywall: { trigger in
            paywallTriggers.append(trigger)
        })
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0xAA), mimeType: "image/jpeg")
        let result = vm.appendCapturedImage(fakeJPEG(byte: 0xBB), mimeType: "image/jpeg")
        XCTAssertEqual(result, .blockedByEntitlement)
        XCTAssertEqual(vm.capturedImages.count, 1, "blocked append should not mutate the buffer")
        XCTAssertEqual(paywallTriggers, [.multiImageScanGate])
    }

    func test_appendCapturedImage_paywallFiresPerTap_notDebounced() {
        // SCA-36 W15: pin the "every 2nd-shot tap fires a fresh paywall
        // trigger" semantic. The capture-view's pre-shutter gate
        // (canAppendCapturedImage) makes rapid taps unlikely in
        // practice — the paywall presentation itself blocks the camera —
        // but the VM-level invariant is that each call to
        // appendCapturedImage is a distinct user intent and gets its
        // own trigger emit. Changing this to "fire once per session"
        // would require explicit debounce state and should land via a
        // deliberate spec change.
        var paywallTriggers: [PaywallTrigger] = []
        let vm = makeVM(tier: .free, presentPaywall: { trigger in
            paywallTriggers.append(trigger)
        })
        _ = vm.appendCapturedImage(fakeJPEG(), mimeType: "image/jpeg")
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x11), mimeType: "image/jpeg")
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x22), mimeType: "image/jpeg")
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x33), mimeType: "image/jpeg")
        XCTAssertEqual(
            paywallTriggers,
            [.multiImageScanGate, .multiImageScanGate, .multiImageScanGate],
            "3 blocked taps should produce 3 paywall presentations",
        )
        XCTAssertEqual(vm.capturedImages.count, 1)
    }

    func test_canAppendCapturedImage_doesNotMutateOrFirePaywall() {
        // SCA-36 W5: pre-shutter probe is non-mutating and does NOT
        // fire the paywall — the capture view fires it explicitly via
        // firePaywallForMultiImageGate() on the shutter path, BEFORE
        // running the camera through stop+freeze+restart.
        var paywallTriggers: [PaywallTrigger] = []
        let vm = makeVM(tier: .free, presentPaywall: { trigger in
            paywallTriggers.append(trigger)
        })
        _ = vm.appendCapturedImage(fakeJPEG(), mimeType: "image/jpeg")
        let pre = vm.canAppendCapturedImage()
        XCTAssertEqual(pre, .blockedByEntitlement)
        XCTAssertEqual(vm.capturedImages.count, 1, "probe must not mutate the buffer")
        XCTAssertTrue(paywallTriggers.isEmpty, "probe must not fire the paywall")
    }

    func test_firePaywallForMultiImageGate_emitsTrigger() {
        var paywallTriggers: [PaywallTrigger] = []
        let vm = makeVM(tier: .pro, presentPaywall: { trigger in
            paywallTriggers.append(trigger)
        })
        vm.firePaywallForMultiImageGate()
        XCTAssertEqual(paywallTriggers, [.multiImageScanGate])
    }

    func test_clearCapturedImages_emptiesBufferWithoutTouchingParse() {
        // SCA-36 C2: capture-view's .task re-entry calls this to start
        // a fresh scan without wiping prior parse output (which the
        // user might still want surfaced if they navigate forward
        // again).
        let vm = makeVM(tier: .pro)
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x11), mimeType: "image/jpeg")
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x22), mimeType: "image/jpeg")
        vm.__injectForTests(ingredients: [
            .init(id: UUID(), displayName: "tomato", confidence: .confirmed),
        ])
        vm.clearCapturedImages()
        XCTAssertTrue(vm.capturedImages.isEmpty)
        XCTAssertEqual(vm.ingredients.count, 1, "clearCapturedImages must not touch parse output")
    }

    func test_appendCapturedImage_secondShotBlockedForPremiumTier() {
        var paywallTriggers: [PaywallTrigger] = []
        let vm = makeVM(tier: .premium, presentPaywall: { trigger in
            paywallTriggers.append(trigger)
        })
        _ = vm.appendCapturedImage(fakeJPEG(), mimeType: "image/jpeg")
        let result = vm.appendCapturedImage(fakeJPEG(byte: 0xBB), mimeType: "image/jpeg")
        XCTAssertEqual(result, .blockedByEntitlement)
        XCTAssertEqual(paywallTriggers, [.multiImageScanGate])
    }

    func test_appendCapturedImage_proTierAppendsUpToMax() {
        let vm = makeVM(tier: .pro)
        for i in 0 ..< ScanViewModel.maxImagesPerScan {
            let result = vm.appendCapturedImage(fakeJPEG(byte: UInt8(i)), mimeType: "image/jpeg")
            XCTAssertEqual(result, .appended, "shot \(i + 1) should append")
        }
        XCTAssertEqual(vm.capturedImages.count, ScanViewModel.maxImagesPerScan)
    }

    func test_appendCapturedImage_proTierCappedAtMax() {
        let vm = makeVM(tier: .pro)
        for _ in 0 ..< ScanViewModel.maxImagesPerScan {
            _ = vm.appendCapturedImage(fakeJPEG(), mimeType: "image/jpeg")
        }
        let result = vm.appendCapturedImage(fakeJPEG(byte: 0xFF), mimeType: "image/jpeg")
        XCTAssertEqual(result, .capped)
        XCTAssertEqual(vm.capturedImages.count, ScanViewModel.maxImagesPerScan)
    }

    func test_removeCapturedImage_removesById() {
        let vm = makeVM(tier: .pro)
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x11), mimeType: "image/jpeg")
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x22), mimeType: "image/jpeg")
        let secondID = vm.capturedImages[1].id
        vm.removeCapturedImage(id: secondID)
        XCTAssertEqual(vm.capturedImages.count, 1)
        XCTAssertNotEqual(vm.capturedImages.first?.id, secondID)
    }

    func test_resetToPrimer_clearsCapturedImages() {
        let vm = makeVM(tier: .pro)
        _ = vm.appendCapturedImage(fakeJPEG(), mimeType: "image/jpeg")
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0xBB), mimeType: "image/jpeg")
        vm.resetToPrimer()
        XCTAssertTrue(vm.capturedImages.isEmpty)
        XCTAssertNil(vm.primaryCapturedImageData)
    }

    func test_primaryCapturedImageData_returnsFirstAppendedImage() {
        let vm = makeVM(tier: .pro)
        let firstData = fakeJPEG(byte: 0x11)
        _ = vm.appendCapturedImage(firstData, mimeType: "image/jpeg")
        _ = vm.appendCapturedImage(fakeJPEG(byte: 0x22), mimeType: "image/jpeg")
        XCTAssertEqual(vm.primaryCapturedImageData, firstData)
    }

    // MARK: - Confirm

    func test_confirmFromReview_persistsPantryItemsAndReturnsLite() async throws {
        let vm = makeVM()
        vm.__injectForTests(ingredients: [
            .init(id: UUID(), displayName: "tomato", canonicalSlug: "tomato", confidence: .confirmed),
            .init(id: UUID(), displayName: "basil", confidence: .confirmed),
        ])
        let result = await vm.confirmFromReview()
        XCTAssertEqual(result.ingredients.count, 2)
        XCTAssertEqual(result.ingredients.first?.displayName, "tomato")
        XCTAssertEqual(vm.phase, .confirmed)

        // Verify persistence into Core Data.
        let request = NSFetchRequest<PantryItem>(entityName: "PantryItem")
        let saved = try controller.viewContext.fetch(request)
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(saved.allSatisfy { $0.userConfirmed })
        XCTAssertTrue(saved.allSatisfy { $0.typedSource == .scan })
    }
}

// MARK: - Test-only injection hook on ScanViewModel

extension ScanViewModel {
    /// Internal test hook — directly seed the ingredient array. Avoids a
    /// round trip through AIDispatch that would need network mocking.
    func __injectForTests(ingredients: [Ingredient]) {
        // Mirrors submitCapturedImage's success-path tail.
        self.__setIngredientsForTests(ingredients)
    }
}
