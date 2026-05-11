// StirAppDelegate
//
// Step-8 APNs registration callbacks (SCA-316). Wired via
// `@UIApplicationDelegateAdaptor` in `StirApp`. SwiftUI's pure
// lifecycle doesn't expose APNs token callbacks; AppDelegate is the
// only seam.
//
// Only two responsibilities:
//   - `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
//     → forward to APNsRegistrationCoordinator for hex-encode + POST.
//   - `application(_:didFailToRegisterForRemoteNotificationsWithError:)`
//     → forward for logging.
//
// Everything else (UN delegate install, prefs flush, idempotency cache)
// lives in APNsRegistrationCoordinator. This file stays thin so the
// AppDelegate-as-god-object anti-pattern doesn't take root.

import UIKit

final class StirAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        Task { @MainActor in
            APNsRegistrationCoordinator.shared.handleDeviceToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error,
    ) {
        Task { @MainActor in
            APNsRegistrationCoordinator.shared.handleRegistrationFailure(error)
        }
    }
}
