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

/// SCA-379: `@MainActor` so the AppDelegate callbacks land synchronously
/// on the main actor (UIKit documents AppDelegate methods as main-thread
/// callers anyway). Pre-SCA-379 each callback wrapped its forward in a
/// `Task { @MainActor in ... }` hop, which (a) added an unnecessary
/// runloop tick between the OS handing us the token and the coordinator
/// noticing it, and (b) made test setup harder — the `Task` ran AFTER
/// the test method returned, so coverage had to poll
/// `currentTokenHex` instead of asserting synchronously after the
/// callback. With the class isolated, both forwards are direct
/// synchronous calls.
@MainActor
final class StirAppDelegate: NSObject, UIApplicationDelegate {
    nonisolated func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data,
    ) {
        // `nonisolated` so Obj-C dispatch can invoke it from any
        // actor; `MainActor.assumeIsolated` upgrades to main isolation
        // synchronously since UIKit guarantees this entry point is
        // already on the main thread (same pattern SCA-375 applied
        // to UN delegate callbacks).
        MainActor.assumeIsolated {
            APNsRegistrationCoordinator.shared.handleDeviceToken(deviceToken)
        }
    }

    nonisolated func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: any Error,
    ) {
        MainActor.assumeIsolated {
            APNsRegistrationCoordinator.shared.handleRegistrationFailure(error)
        }
    }
}
