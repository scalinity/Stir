// OutcomeFeedbackViewIntentTests
//
// SCA-55 — pin the PostSubmitIntent decision matrix in the OutcomeFeedback
// gate. The decision lives in `static OutcomeFeedbackView.postSubmitIntent`
// (refactored from a default-nil-arg overload to a pure static per
// SCA-56 CR1 S8). Branches:
//
//   leftoverCount=0, any tier               → .dismiss
//   leftoverCount>0, no entitlements        → .dismiss (test-fallback)
//   leftoverCount>0, free                   → .openPaywall(.leftoversGate)
//   leftoverCount>0, premium active         → .openLeftovers
//   leftoverCount>0, premium grace          → .openLeftovers
//   leftoverCount>0, premium expired        → .openPaywall(.leftoversGate)
//
// SCA-56 critical-3 telemetry: `leftovers_eligible_free` reads
// `effectiveTier`, not raw `tier`, so an expired-Premium user who hits
// the paywall logs as eligible_free=true (matches the gate decision).
// Locked in by `test_eligibleFreeTelemetry_includesExpiredPremium`.
//
// SCA-56 (CR1 S19) note: `test_leftoverCountPositive_noEntitlementsInjected_*`
// pins a TEST-ERGONOMICS fallback (production always passes a non-nil
// EntitlementService via the host's init), NOT a product behavior. The
// fallback exists so unit tests that don't care about the gate can omit
// it; do not interpret as documenting an intentional Free path.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class OutcomeFeedbackViewIntentTests: XCTestCase {
    private var controller: PersistenceController!
    private var householdRepo: HouseholdProfileRepository!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        householdRepo = HouseholdProfileRepository(controller: controller)
    }

    override func tearDown() async throws {
        controller = nil
        householdRepo = nil
        try await super.tearDown()
    }

    // MARK: - Intent matrix

    func test_leftoverCountZero_returnsDismiss_evenForPremium() {
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        XCTAssertEqual(
            OutcomeFeedbackView.postSubmitIntent(
                leftoverCount: 0,
                rating: 0,
                recipePlan: nil,
                entitlements: entitlements,
                repeatCandidateSuppression: makeFreshSuppressionStore(),
            ),
            .dismiss,
        )
    }

    func test_leftoverCountZero_returnsDismiss_forFree() {
        let entitlements = makeEntitlements(tier: .free, billingState: .none)
        XCTAssertEqual(
            OutcomeFeedbackView.postSubmitIntent(
                leftoverCount: 0,
                rating: 0,
                recipePlan: nil,
                entitlements: entitlements,
                repeatCandidateSuppression: makeFreshSuppressionStore(),
            ),
            .dismiss,
        )
    }

    func test_leftoverCountPositive_freeUser_returnsPaywall() {
        let entitlements = makeEntitlements(tier: .free, billingState: .none)
        XCTAssertEqual(
            OutcomeFeedbackView.postSubmitIntent(
                leftoverCount: 2,
                rating: 0,
                recipePlan: nil,
                entitlements: entitlements,
                repeatCandidateSuppression: makeFreshSuppressionStore(),
            ),
            .openPaywall(.leftoversGate),
        )
    }

    func test_leftoverCountPositive_premiumActive_returnsOpenLeftovers() {
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        XCTAssertEqual(
            OutcomeFeedbackView.postSubmitIntent(
                leftoverCount: 2,
                rating: 0,
                recipePlan: nil,
                entitlements: entitlements,
                repeatCandidateSuppression: makeFreshSuppressionStore(),
            ),
            .openLeftovers,
        )
    }

    func test_leftoverCountPositive_premiumGrace_returnsOpenLeftovers() {
        // Grace = billing-retry — user retains paid access while Apple
        // recovers payment. Leftovers must continue to work.
        let entitlements = makeEntitlements(tier: .premium, billingState: .grace)
        XCTAssertEqual(
            OutcomeFeedbackView.postSubmitIntent(
                leftoverCount: 2,
                rating: 0,
                recipePlan: nil,
                entitlements: entitlements,
                repeatCandidateSuppression: makeFreshSuppressionStore(),
            ),
            .openLeftovers,
        )
    }

    func test_leftoverCountPositive_premiumExpired_returnsPaywall() {
        // Expired demotes to Free per EntitlementService:165 ("demote to
        // free for `expired` AND `none`"). Leftovers must paywall.
        let entitlements = makeEntitlements(tier: .premium, billingState: .expired)
        XCTAssertEqual(
            OutcomeFeedbackView.postSubmitIntent(
                leftoverCount: 2,
                rating: 0,
                recipePlan: nil,
                entitlements: entitlements,
                repeatCandidateSuppression: makeFreshSuppressionStore(),
            ),
            .openPaywall(.leftoversGate),
        )
    }

    func test_leftoverCountPositive_noEntitlementsInjected_returnsDismiss() {
        // Test-ergonomics fallback (NOT a product contract) — see file
        // header. Production always injects a non-nil EntitlementService
        // via the host's init. This case exists so callers who don't
        // care about the gate can omit it without forcing every test to
        // instantiate a service.
        XCTAssertEqual(
            OutcomeFeedbackView.postSubmitIntent(
                leftoverCount: 2,
                rating: 0,
                recipePlan: nil,
                entitlements: nil,
                repeatCandidateSuppression: makeFreshSuppressionStore(),
            ),
            .dismiss,
        )
    }

    // MARK: - SCA-66: rating ≥ 4 on un-saved recipe → suggestSave

    func test_suggestSave_premium_ratingFourUnsaved_returnsSuggestSave() throws {
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let plan = makeRecipePlan(isFavorite: false)
        let suppression = makeFreshSuppressionStore()
        let intent = OutcomeFeedbackView.postSubmitIntent(
            leftoverCount: 0,
            rating: 4,
            recipePlan: plan,
            entitlements: entitlements,
            repeatCandidateSuppression: suppression,
        )
        let planId = try XCTUnwrap(plan.id)
        XCTAssertEqual(intent, .suggestSave(recipePlanId: planId))
    }

    func test_suggestSave_freeTier_ratingFiveUnsaved_returnsSuggestSave() throws {
        // Free still gets the card — the card itself routes "Yes" to
        // the savedFavoritesGate paywall.
        let entitlements = makeEntitlements(tier: .free, billingState: .none)
        let plan = makeRecipePlan(isFavorite: false)
        let suppression = makeFreshSuppressionStore()
        let intent = OutcomeFeedbackView.postSubmitIntent(
            leftoverCount: 0,
            rating: 5,
            recipePlan: plan,
            entitlements: entitlements,
            repeatCandidateSuppression: suppression,
        )
        let planId = try XCTUnwrap(plan.id)
        XCTAssertEqual(intent, .suggestSave(recipePlanId: planId))
    }

    func test_suggestSave_ratingThree_returnsDismiss() {
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let plan = makeRecipePlan(isFavorite: false)
        let suppression = makeFreshSuppressionStore()
        let intent = OutcomeFeedbackView.postSubmitIntent(
            leftoverCount: 0,
            rating: 3,
            recipePlan: plan,
            entitlements: entitlements,
            repeatCandidateSuppression: suppression,
        )
        XCTAssertEqual(intent, .dismiss)
    }

    func test_suggestSave_alreadyFavorited_returnsDismiss() {
        // SCA-109: gate reads `isFavorite`, NOT `isSaved`. A user who's
        // already favorited the recipe shouldn't be re-prompted to save.
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let plan = makeRecipePlan(isFavorite: true)
        let suppression = makeFreshSuppressionStore()
        let intent = OutcomeFeedbackView.postSubmitIntent(
            leftoverCount: 0,
            rating: 5,
            recipePlan: plan,
            entitlements: entitlements,
            repeatCandidateSuppression: suppression,
        )
        XCTAssertEqual(intent, .dismiss)
    }

    /// SCA-109 regression: `CookingSessionRepository.markCompleted()`
    /// flips `isSaved=true` synchronously before OutcomeFeedback presents.
    /// The pre-fix gate read `isSaved`, which made the entire suggestSave
    /// branch dead code in production. Verify the post-fix gate
    /// (`isFavorite`) correctly routes to suggestSave when ONLY isSaved
    /// is true (the real production state) and isFavorite is still false.
    func test_suggestSave_isSavedTrueButNotFavorited_stillReturnsSuggestSave() throws {
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        // Simulate the real production state right before OutcomeFeedback
        // submit() runs: markCompleted has set isSaved=true, but the
        // user has NOT explicitly favorited via setFavorite, so
        // isFavorite is still false. The card MUST surface here.
        let plan = makeRecipePlan(isFavorite: false, isSaved: true)
        let suppression = makeFreshSuppressionStore()
        let intent = OutcomeFeedbackView.postSubmitIntent(
            leftoverCount: 0,
            rating: 5,
            recipePlan: plan,
            entitlements: entitlements,
            repeatCandidateSuppression: suppression,
        )
        let planId = try XCTUnwrap(plan.id)
        XCTAssertEqual(intent, .suggestSave(recipePlanId: planId))
    }

    func test_suggestSave_suppressed_returnsDismiss() {
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let plan = makeRecipePlan(isFavorite: false)
        let suppression = makeFreshSuppressionStore()
        suppression.suppress(recipePlanId: plan.id!)
        let intent = OutcomeFeedbackView.postSubmitIntent(
            leftoverCount: 0,
            rating: 5,
            recipePlan: plan,
            entitlements: entitlements,
            repeatCandidateSuppression: suppression,
        )
        XCTAssertEqual(intent, .dismiss)
    }

    func test_suggestSave_leftoversWins_returnsOpenLeftovers() {
        // Conflict matrix: when both leftovers AND high-rating fire,
        // leftovers wins (more actionable; spec implicit).
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        let plan = makeRecipePlan(isFavorite: false)
        let suppression = makeFreshSuppressionStore()
        let intent = OutcomeFeedbackView.postSubmitIntent(
            leftoverCount: 2,
            rating: 5,
            recipePlan: plan,
            entitlements: entitlements,
            repeatCandidateSuppression: suppression,
        )
        XCTAssertEqual(intent, .openLeftovers)
    }

    // MARK: - SCA-56 critical-3: leftovers_eligible_free uses effectiveTier

    func test_eligibleFreeTelemetry_trueForRawFreeUser() {
        let entitlements = makeEntitlements(tier: .free, billingState: .none)
        XCTAssertEqual(entitlements.effectiveTier, .free)
    }

    func test_eligibleFreeTelemetry_trueForExpiredPremium() {
        // The bug fixed in SCA-56: previously `meal_rated.leftovers_eligible_free`
        // read raw `tier` (= .premium) and miscounted this cohort as
        // ineligible. After the fix, `effectiveTier` is .free and the
        // funnel correctly sizes them as a conversion opportunity.
        let entitlements = makeEntitlements(tier: .premium, billingState: .expired)
        XCTAssertEqual(entitlements.effectiveTier, .free)
        XCTAssertNotEqual(entitlements.tier, .free, "raw tier stays .premium even when billing expired")
    }

    func test_eligibleFreeTelemetry_falseForPremiumActive() {
        let entitlements = makeEntitlements(tier: .premium, billingState: .active)
        XCTAssertNotEqual(entitlements.effectiveTier, .free)
    }

    func test_eligibleFreeTelemetry_falseForPremiumGrace() {
        // Grace retains paid access — must NOT count as eligible_free
        // (the user IS paying, Apple is just retrying their card).
        let entitlements = makeEntitlements(tier: .premium, billingState: .grace)
        XCTAssertNotEqual(entitlements.effectiveTier, .free)
    }

    // MARK: - Helpers

    /// SCA-109: helper now exposes `isFavorite` (the gate's actual bit)
    /// AND `isSaved` (still surfaced because some integration tests want
    /// to seed the post-`markCompleted` state). `isSaved` defaults to
    /// `isFavorite`'s value to match `SolveRepository.setFavorite`'s
    /// sticky behavior — a real Core Data row would have both bits flip
    /// together. Callers that need to test the divergent state
    /// (`isSaved=true, isFavorite=false`, i.e. "the cook session marked
    /// it complete but the user hasn't explicitly favorited") pass
    /// explicit values for both.
    private func makeRecipePlan(isFavorite: Bool, isSaved: Bool? = nil) -> RecipePlan {
        let context = controller.viewContext
        let plan = RecipePlan(context: context)
        plan.id = UUID()
        plan.title = "Miso-Glazed Salmon"
        plan.isFavorite = isFavorite
        plan.isSaved = isSaved ?? isFavorite
        plan.origin = "ai"
        return plan
    }

    private func makeFreshSuppressionStore() -> RepeatCandidateSuppressionStore {
        let suite = "test.repeat_candidate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return RepeatCandidateSuppressionStore(defaults: defaults)
    }

    private func makeEntitlements(
        tier: Tier,
        billingState: BillingState,
    ) -> EntitlementService {
        let service = EntitlementService(keychain: MockKeychain())
        service.hydrate(from: BootstrapResponse.Entitlements(
            tier: tier,
            billingState: billingState,
            isTrial: false,
            expiresAt: nil,
            voiceEnabled: tier != .free,
            billingRetryBanner: false,
            quotas: [],
        ))
        return service
    }
}
