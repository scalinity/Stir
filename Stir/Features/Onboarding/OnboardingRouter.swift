// OnboardingRouter
//
// Pure-function routing seam for the navigation handlers that don't
// spawn async work — Welcome's two CTAs + SampleShowcase's two CTAs.
// Each `Action` produced by a button tap maps to a single `Command`
// that the host view (`OnboardingRoot`) applies to its navigation
// `path`. The setup-1/setup-2 handlers stay imperative in
// `OnboardingRoot` because they spawn async Tasks that save through
// `OnboardingViewModel` and surface VAL/SYNC errors via an alert; a
// router seam there would force a model dependency on the router
// and isn't what's needed for the regression coverage that motivated
// this extraction (SCA-293).
//
// The seam exists so the navigation contract — "Welcome 'Try it now'
// pushes Setup 1; sample-showcase 'Try with your real kitchen' also
// pushes Setup 1, NOT the SCA-67 immediate-bypass that SCA-293
// retired" — is unit-testable without spinning up the SwiftUI view.
// Pre-SCA-293 the sample-path bypass was an inline closure body
// inside the `.sampleShowcase` `navigationDestination` arm, so a
// regression test would have required either a UITest or a SwiftUI
// snapshot harness; this routing-table alternative is cheaper and
// more direct.

import Foundation

enum OnboardingRouter {
    /// User gestures that produce a synchronous routing decision.
    /// Setup 1 / Setup 2 actions are intentionally absent — they
    /// require async save coordination with `OnboardingViewModel`
    /// and live in `OnboardingRoot` directly.
    enum Action: Sendable, Equatable {
        case welcomeTryIt
        case welcomeSeeSample
        case sampleShowcasePrimary
        case sampleShowcaseBack
    }

    /// Side-effect to apply to the host's NavigationStack `path`.
    /// `popLast` is safe to dispatch unconditionally because
    /// `OnboardingRoot.dispatch` empty-path-guards before calling
    /// `path.removeLast()` — `Array.removeLast()` traps on empty,
    /// so the guard is load-bearing, not defensive.
    enum Command: Sendable, Equatable {
        case push(OnboardingRoute)
        case popLast
    }

    static func handle(_ action: Action) -> Command {
        switch action {
        case .welcomeTryIt:
            return .push(.setupPreferences)
        case .welcomeSeeSample:
            return .push(.sampleShowcase)
        case .sampleShowcasePrimary:
            // SCA-293 contract: parity with `.welcomeTryIt`. The
            // sample-path commitment gesture routes through Setup
            // 1/2 just like the direct "Try it now" path. Pre-
            // SCA-293 this branch ran the SCA-67 stub-replacement
            // bypass (zero-selection defaults + recordSkip for both
            // setups + immediate completeOnboarding), which polluted
            // the setup_skipped cohort and landed the user on an
            // empty Tonight Home. The regression test in
            // OnboardingRouterTests pins the post-SCA-293 wire
            // contract so the next refactor can't silently re-
            // introduce the bypass.
            return .push(.setupPreferences)
        case .sampleShowcaseBack:
            return .popLast
        }
    }
}
