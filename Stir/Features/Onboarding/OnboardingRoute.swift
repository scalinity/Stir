// OnboardingRoute
//
// NavigationStack destinations for the onboarding flow + sample-path
// showcase (SCA-67).

import Foundation

enum OnboardingRoute: Hashable, Sendable {
    case setupPreferences
    case setupKitchen
    /// Transitional "setting up your kitchen" surface shown between
    /// Setup 2 "Finish setup" and the coordinator phase flip to
    /// `.ready`. Gives `onboarding_completed` a durable emission site
    /// (fires on `onAppear` before the auto-advance, so a user who
    /// kills the app during the 1.5s dwell still counts as completed).
    /// Real view + routing wiring lands in commit 2 (ui(onboarding)).
    case completionTransition
    /// SCA-67 — "See a sample" pushes the SampleShowcaseView onto the
    /// onboarding NavigationStack instead of the previous immediate-
    /// bypass-to-Tonight. SCA-293 — the showcase's "Try with your real
    /// kitchen" CTA pushes `.setupPreferences` (same destination as
    /// Welcome's "Try it now"), so the sample-path user gets the same
    /// preferences + kitchen setup as everyone else. "Back to start"
    /// pops to Welcome.
    case sampleShowcase
}
