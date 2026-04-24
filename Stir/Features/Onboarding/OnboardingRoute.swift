// OnboardingRoute
//
// NavigationStack destinations for the three-step onboarding flow.
// Kept narrow — sample-path "See a sample" in Welcome is a no-op stub
// routed through RootCoordinator (commit 9) rather than an onboarding
// route because it bypasses setup entirely.

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
}
