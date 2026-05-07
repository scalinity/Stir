// OutcomeFeedbackViewIntentTests
//
// SCA-55 — pin the PostSubmitIntent decision matrix in the OutcomeFeedback
// gate. The decision lives in `postSubmitIntent(forLeftoverCount:)` so we
// test it directly rather than driving the full Core Data submit() path
// for a 3-line decision function. Branches:
//
//   leftoverCount=0, any tier               → .dismiss
//   leftoverCount>0, no entitlements        → .dismiss (test-fallback)
//   leftoverCount>0, free                   → .openPaywall(.leftoversGate)
//   leftoverCount>0, premium active         → .openLeftovers
//   leftoverCount>0, premium grace          → .openLeftovers
//   leftoverCount>0, premium expired        → .openPaywall(.leftoversGate)
//
// CoreData fixtures use the in-memory PersistenceController so a
// CookingSession can be passed to the view init. Test-scoped
// install:test:<uuid> per CLAUDE.md "Integration test DB strategy."

import CoreData
import XCTest
@testable import Stir

@MainActor
final class OutcomeFeedbackViewIntentTests: XCTestCase {
    private var controller: PersistenceController!
    private var householdRepo: HouseholdProfileRepository!
    private var session: CookingSession!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        householdRepo = HouseholdProfileRepository(controller: controller)
        let household = try householdRepo.ensureHouseholdProfile(
            for: "install:test:\(UUID().uuidString)",
        )
        // Bare CookingSession — postSubmitIntent only reads
        // leftoverCount + entitlements, never the session, so we don't
        // need a fully-populated row. CookingSessionRepository's
        // create path requires a recipePlan, so we skip it and build
        // the row manually.
        let plan = RecipePlan(context: controller.viewContext)
        plan.id = UUID()
        plan.household = household
        plan.title = "stub"
        plan.summary = "stub"
        plan.servings = 2
        plan.aiVersion = "1.0.0"
        plan.typedOrigin = .ai
        plan.createdAt = Date()
        plan.updatedAt = Date()
        let s = CookingSession(context: controller.viewContext)
        s.id = UUID()
        s.household = household
        s.recipePlan = plan
        s.startedAt = Date()
        try controller.viewContext.save()
        self.session = s
    }

    override func tearDown() async throws {
        controller = nil
        householdRepo = nil
        session = nil
        try await super.tearDown()
    }

    // MARK: - Intent matrix

    func test_leftoverCountZero_returnsDismiss_evenForPremium() {
        let view = makeView(entitlements: makeEntitlements(tier: .premium, billingState: .active))
        XCTAssertEqual(view.postSubmitIntent(forLeftoverCount: 0), .dismiss)
    }

    func test_leftoverCountZero_returnsDismiss_forFree() {
        let view = makeView(entitlements: makeEntitlements(tier: .free, billingState: .none))
        XCTAssertEqual(view.postSubmitIntent(forLeftoverCount: 0), .dismiss)
    }

    func test_leftoverCountPositive_freeUser_returnsPaywall() {
        let view = makeView(entitlements: makeEntitlements(tier: .free, billingState: .none))
        XCTAssertEqual(
            view.postSubmitIntent(forLeftoverCount: 2),
            .openPaywall(.leftoversGate),
        )
    }

    func test_leftoverCountPositive_premiumActive_returnsOpenLeftovers() {
        let view = makeView(entitlements: makeEntitlements(tier: .premium, billingState: .active))
        XCTAssertEqual(view.postSubmitIntent(forLeftoverCount: 2), .openLeftovers)
    }

    func test_leftoverCountPositive_premiumGrace_returnsOpenLeftovers() {
        // Grace = billing-retry — user retains paid access while Apple
        // recovers payment. Leftovers must continue to work.
        let view = makeView(entitlements: makeEntitlements(tier: .premium, billingState: .grace))
        XCTAssertEqual(view.postSubmitIntent(forLeftoverCount: 2), .openLeftovers)
    }

    func test_leftoverCountPositive_premiumExpired_returnsPaywall() {
        // Expired demotes to Free per EntitlementService:165 ("demote to
        // free for `expired` AND `none`"). Leftovers must paywall.
        let view = makeView(entitlements: makeEntitlements(tier: .premium, billingState: .expired))
        XCTAssertEqual(
            view.postSubmitIntent(forLeftoverCount: 2),
            .openPaywall(.leftoversGate),
        )
    }

    func test_leftoverCountPositive_noEntitlementsInjected_returnsDismiss() {
        // Defensive fallback so unit tests that don't care about the
        // gate (and tests of skipAndDismiss(), etc.) don't accidentally
        // open Leftovers. Server-side ENT-LEFTOVERS-01 remains the
        // authoritative gate in production.
        let view = makeView(entitlements: nil)
        XCTAssertEqual(view.postSubmitIntent(forLeftoverCount: 2), .dismiss)
    }

    // MARK: - Helpers

    private func makeView(entitlements: EntitlementService?) -> OutcomeFeedbackView {
        OutcomeFeedbackView(
            session: session,
            onSubmitted: { _ in },
            entitlements: entitlements,
        )
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
