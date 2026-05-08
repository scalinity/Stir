// SubstitutionSheetViewModelTests
//
// Exercises view-model logic that doesn't depend on the AIDispatch
// network round-trip: canSubmit gating, accept/reject early-return when
// no event has been persisted, and the analytics+dismiss behavior on the
// "acknowledge unsafe" path.
//
// The Gemini-call paths (.requesting → .safe / .unsafe / .error) are
// covered server-side by Backend/supabase/tests/substitution_test.ts and
// would require either MockURLProtocol wiring + a SupabaseSessionClient
// or extracting AIDispatch behind a protocol — both beyond the scope of
// this incremental coverage pass per the CR3 SCOPE RULE.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SubstitutionSheetViewModelTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var recipePlan: RecipePlan!
    private var session: CookingSession!
    private var aiDispatch: AIDispatch!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        let houseRepo = HouseholdProfileRepository(controller: controller)
        household = try houseRepo.ensureHouseholdProfile(for: "install:test-\(UUID().uuidString)")
        recipePlan = try makeRecipePlan(household: household, ingredientNames: ["heavy cream", "garlic"])
        session = try CookingSessionRepository(controller: controller)
            .createSession(on: household, for: recipePlan, entryPoint: .solve)
        aiDispatch = makeAIDispatch()
    }

    // MARK: - canSubmit

    func test_canSubmit_falseWhenNoIngredientPickedAndNoFreeText() {
        let vm = makeVM()
        vm.selectedIngredientID = nil
        vm.freeTextName = ""
        XCTAssertFalse(vm.canSubmit)
    }

    func test_canSubmit_trueWhenIngredientPicked() {
        let vm = makeVM()
        let ingredient = recipePlan.ingredientArray.first
        XCTAssertNotNil(ingredient?.id)
        vm.selectedIngredientID = ingredient?.id
        vm.freeTextName = ""
        XCTAssertTrue(vm.canSubmit)
    }

    func test_canSubmit_trueWhenFreeTextProvided() {
        let vm = makeVM()
        vm.selectedIngredientID = nil
        vm.freeTextName = "my blender broke"
        XCTAssertTrue(vm.canSubmit)
    }

    func test_canSubmit_falseWhenFreeTextIsOnlyWhitespace() {
        let vm = makeVM()
        vm.selectedIngredientID = nil
        vm.freeTextName = "   "
        XCTAssertFalse(vm.canSubmit)
    }

    // MARK: - Accept / Reject early-return

    func test_accept_dismissesEarlyWhenNoSafeStateOrPersistedEvent() async {
        let expect = expectation(description: "onFinished called")
        let vm = makeVM(onFinished: { expect.fulfill() })
        // state is .idle, persistedEvent nil → accept() should just call onFinished.
        await vm.accept()
        await fulfillment(of: [expect], timeout: 1.0)
    }

    func test_reject_dismissesEarlyWhenNoPersistedEvent() async {
        let expect = expectation(description: "onFinished called")
        let vm = makeVM(onFinished: { expect.fulfill() })
        // No persistedEvent → reject() short-circuits to onFinished.
        await vm.reject()
        await fulfillment(of: [expect], timeout: 1.0)
    }

    func test_acknowledgeUnsafe_alwaysDismisses() async {
        let expect = expectation(description: "onFinished called")
        let vm = makeVM(onFinished: { expect.fulfill() })
        await vm.acknowledgeUnsafe()
        await fulfillment(of: [expect], timeout: 1.0)
    }

    // MARK: - Analytics emission (pre-dispatch)

    func test_submit_emitsSubstitutionRequestedBeforeDispatch() async {
        // 2026-04-22 prod regression: 4 substitution_accepted(unsafe_acknowledged)
        // events landed on PostHog from the sheet VM in the last hour, but
        // zero substitution_requested despite BOTH being emitted from the
        // same class, same analytics instance, same submit → unsafe → ack
        // flow. Pin the pre-dispatch emission here so a regression shows
        // up loud at CI time instead of as a funnel drop-off in prod.
        let spy = SpyPostHog()
        let vm = makeVM(analytics: spy)
        vm.freeTextName = "out of heavy cream"

        // Kick off the submit. The AI dispatch will fail against
        // test.invalid, but that's fine — substitution_requested fires
        // BEFORE the dispatch (line 97 of the VM, immediately after
        // state = .requesting and before the SubstitutionRequest is
        // even constructed). The capture should land regardless of
        // dispatch outcome.
        await vm.submit()

        let requested = spy.captures.filter { $0.event == "substitution_requested" }
        XCTAssertEqual(requested.count, 1,
                       "substitutionRequested must fire exactly once per submit — got \(requested.count)")
        let props = requested.first?.properties ?? [:]
        XCTAssertEqual(props["invocation"] as? String, "sheet")
        XCTAssertEqual(props["problem_type"] as? String, "free_text")
        XCTAssertNotNil(props["sub_event_id"] as? String,
                        "sub_event_id must be populated so the funnel joins to the paired accepted event")
    }

    // MARK: - Helpers

    private func makeVM(
        onFinished: @escaping () -> Void = {},
        analytics: PostHogClient? = nil,
    ) -> SubstitutionSheetViewModel {
        SubstitutionSheetViewModel(
            recipePlan: recipePlan,
            household: household,
            session: session,
            currentStep: nil,
            aiDispatch: aiDispatch,
            repository: SubstitutionRepository(controller: controller),
            pantryRepository: PantryItemRepository(controller: controller),
            analytics: analytics ?? .shared,
            onFinished: onFinished,
        )
    }

    private func makeAIDispatch() -> AIDispatch {
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
        return AIDispatch(session: session, config: config)
    }

    private func makeRecipePlan(household: HouseholdProfile, ingredientNames: [String]) throws -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.household = household
        plan.title = "Substitution Test"
        plan.servings = 2
        plan.estimatedMinutes = 25
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()

        for (idx, name) in ingredientNames.enumerated() {
            let ing = RecipeIngredient(context: context)
            ing.id = UUID()
            ing.recipePlan = plan
            ing.displayName = name
            ing.sortOrder = Int16(idx)
            ing.amountText = "1 cup"
            ing.isOptional = false
        }
        try controller.save()
        return plan
    }
}

private final class DismissBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func flip() { lock.lock(); _value = true; lock.unlock() }
}

/// Spy analytics subclass for asserting captures in tests. Uses the
/// `#if DEBUG` `init(testingOnly:)` protected init on PostHogClient so
/// production builds can't accidentally construct one.
private final class SpyPostHog: PostHogClient, @unchecked Sendable {
    struct Capture: Sendable {
        let event: String
        let properties: [String: Any]
    }
    private let lock = NSLock()
    private var _captures: [Capture] = []
    var captures: [Capture] {
        lock.lock(); defer { lock.unlock() }
        return _captures
    }
    init() {
        super.init(testingOnly: true)
    }
    override func capture(_ event: TelemetryEvent, properties: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        _captures.append(Capture(event: event.rawValue, properties: properties))
    }
}
