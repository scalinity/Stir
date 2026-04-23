// SolveViewModelPaywallTests
//
// Pins the Dinner-Solve-quota → paywall wiring. Pre-2026-04-22, RATE-01
// on dinner-solve set `phase = .error` but never presented the paywall
// — which meant `PaywallTrigger.dinnerSolveQuotaExhausted` was never
// observed in prod (confirmed via a 48h PostHog probe showing only 2 of
// 5 spec-declared trigger values firing). SolveViewModel now takes a
// `presentPaywall` callback and invokes it from the RATE-01 catch; this
// test asserts that wiring end-to-end via MockURLProtocol returning 429.
//
// Shape: fakes an HTTP 429 for the dinner-solve stream, constructs a
// SolveViewModel with a spy callback, calls startSolve, and awaits the
// async stream's RATE-01 resolution. The phase transitions to .error
// AND the spy is called with `.dinnerSolveQuotaExhausted`.

import CoreData
import XCTest
@testable import Stir

@MainActor
final class SolveViewModelPaywallTests: XCTestCase {
    private var controller: PersistenceController!
    private var household: HouseholdProfile!
    private var householdStore: CurrentHouseholdStore!

    override func setUp() async throws {
        try await super.setUp()
        controller = PersistenceController(inMemory: true)
        household = try HouseholdProfileRepository(controller: controller)
            .ensureHouseholdProfile(for: "install:solve-paywall-\(UUID().uuidString)")
        householdStore = CurrentHouseholdStore()
        householdStore.set(household)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - RATE-01 routes to paywall

    /// Regression guard: when dinner-solve returns 429 (RATE-01 quota
    /// exhaustion), SolveViewModel must (1) set phase=.error and (2)
    /// invoke `presentPaywall` with `.dinnerSolveQuotaExhausted`.
    /// Prior to 2026-04-22, only (1) happened — users hit a dead-end
    /// error screen and the `paywall_viewed` funnel carried no
    /// `trigger=dinner_solve_quota_exhausted` events.
    func test_rateLimited_presentsDinnerSolveQuotaExhaustedPaywall() async throws {
        // Arrange — MockURLProtocol returns 429 with a spec-shaped body.
        MockURLProtocol.handler = { request in
            // SSE path — backend wraps RATE-01 in the same 429 shape as
            // non-streaming endpoints. SupabaseSessionClient maps 429
            // → StirError.rateLimited which AIDispatch.dinnerSolve
            // propagates through the stream.
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!
            let body = #"{"error":"RATE-01","message":"You're out of Dinner Solves for this month."}"#
            return (response, Data(body.utf8))
        }

        // Arrange — ViewModel with paywall spy.
        let vm = makeViewModel()
        var capturedTriggers: [PaywallTrigger] = []
        let vmWithSpy = makeViewModel(presentPaywall: { trigger in
            capturedTriggers.append(trigger)
        })
        // Prep both so the `vm` doesn't leak into compile warnings.
        _ = vm

        vmWithSpy.prepare(with: [
            DinnerSolveRequest.IngredientLite(displayName: "onion", canonicalSlug: nil, amountText: nil),
        ])

        // Act — startSolve spawns streamTask; await its completion.
        vmWithSpy.startSolve()
        await waitForErrorPhase(vm: vmWithSpy, timeoutSec: 3.0)

        // Assert — phase transitioned to error AND paywall was invoked.
        if case .error(_, let code) = vmWithSpy.phase {
            XCTAssertEqual(code, "RATE-01", "phase must carry the RATE-01 code")
        } else {
            XCTFail("phase must transition to .error on RATE-01; got \(vmWithSpy.phase)")
        }
        XCTAssertEqual(
            capturedTriggers,
            [.dinnerSolveQuotaExhausted],
            "presentPaywall must fire exactly once with dinner_solve_quota_exhausted on RATE-01",
        )
    }

    /// Pins that the paywall wiring is OPTIONAL — a SolveViewModel built
    /// without a presentPaywall callback (production never does this,
    /// but older tests might) must not crash on RATE-01.
    func test_rateLimited_withoutPresentPaywallCallback_doesNotCrash() async throws {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )!
            return (response, Data(#"{"error":"RATE-01","message":"quota"}"#.utf8))
        }

        let vm = makeViewModel(presentPaywall: nil)
        vm.prepare(with: [
            DinnerSolveRequest.IngredientLite(displayName: "onion", canonicalSlug: nil, amountText: nil),
        ])
        vm.startSolve()
        await waitForErrorPhase(vm: vm, timeoutSec: 3.0)

        if case .error(_, let code) = vm.phase {
            XCTAssertEqual(code, "RATE-01")
        } else {
            XCTFail("phase must still transition to .error even without a paywall callback")
        }
    }

    // MARK: - Helpers

    private func makeViewModel(
        presentPaywall: ((PaywallTrigger) -> Void)? = nil,
    ) -> SolveViewModel {
        let config = AppConfig(
            supabase: AppConfig.Supabase(url: URL(string: "https://test.invalid")!, anonKey: "x"),
            posthog: nil, sentry: nil, revenueCat: nil,
            build: "1.0.0 (1)", osVersion: "17.5",
        )
        let sessionClient = SupabaseSessionClient(
            config: config,
            keychain: MockKeychain(),
            urlSession: MockURLProtocol.stubSession(),
            sentry: NoOpSentryReporter(),
        )
        let aiDispatch = AIDispatch(session: sessionClient, config: config)
        let solveRepo = SolveRepository(controller: controller)
        return SolveViewModel(
            aiDispatch: aiDispatch,
            solveRepo: solveRepo,
            householdStore: householdStore,
            presentPaywall: presentPaywall,
        )
    }

    /// Polls vm.phase until it reaches .error or the timeout expires.
    /// Simple polling is appropriate here — streamTask runs on MainActor
    /// and its catch block updates `phase` synchronously, so the value
    /// transitions within a few event-loop hops after startSolve().
    private func waitForErrorPhase(vm: SolveViewModel, timeoutSec: Double) async {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            if case .error = vm.phase { return }
            try? await Task.sleep(nanoseconds: 20_000_000)  // 20ms
        }
    }
}
