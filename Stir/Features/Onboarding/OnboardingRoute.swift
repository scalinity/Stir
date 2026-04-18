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
}
