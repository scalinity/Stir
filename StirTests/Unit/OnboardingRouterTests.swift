// OnboardingRouterTests
//
// SCA-293 — pin the navigation contract for the four pure handlers
// in the onboarding flow (Welcome's two CTAs + SampleShowcase's two
// CTAs). The original SCA-293 bug was the sample-showcase primary CTA
// silently running an inline bypass (zero-selection defaults +
// immediate completeOnboarding) instead of pushing Setup 1 like
// Welcome's "Try it now" — survived initial review because no test
// touched the `.sampleShowcase` route handler. These tests close that
// gap by asserting the routing table directly.
//
// Setup-1/Setup-2 handlers spawn async Tasks that save through
// OnboardingViewModel; they're intentionally not part of the router
// seam (see the design note in `OnboardingRouter.swift`).

import XCTest
@testable import Stir

final class OnboardingRouterTests: XCTestCase {
    func test_welcomeTryIt_pushesSetupPreferences() {
        XCTAssertEqual(
            OnboardingRouter.handle(.welcomeTryIt),
            .push(.setupPreferences),
        )
    }

    func test_welcomeSeeSample_pushesSampleShowcase() {
        XCTAssertEqual(
            OnboardingRouter.handle(.welcomeSeeSample),
            .push(.sampleShowcase),
        )
    }

    /// SCA-293 regression — the sample-path commitment gesture must
    /// route through Setup 1 (parity with Welcome's "Try it now"),
    /// NOT the SCA-67 stub-replacement bypass that polluted the
    /// `setup_skipped` cohort and landed users on an empty Tonight
    /// Home with no preferences or kitchen state.
    func test_sampleShowcasePrimary_pushesSetupPreferences_notBypass() {
        XCTAssertEqual(
            OnboardingRouter.handle(.sampleShowcasePrimary),
            .push(.setupPreferences),
        )
    }

    /// "Back to start" pops one frame off the navigation stack. The
    /// host view (`OnboardingRoot.dispatch`) guards against an empty
    /// path on `.popLast`, so this command remains safe to apply
    /// unconditionally.
    func test_sampleShowcaseBack_popsLast() {
        XCTAssertEqual(
            OnboardingRouter.handle(.sampleShowcaseBack),
            .popLast,
        )
    }

}
