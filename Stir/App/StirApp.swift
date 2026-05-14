// StirApp
//
// SwiftUI application entry. Responsibilities at init:
//   1. Load Config.xcconfig-backed AppConfig.
//   2. Initialize Sentry (if DSN present) and PostHog (if key present).
//   3. Construct RootCoordinator with the loaded config.
//   4. Hand control to RootView, which drives the launch sequence.
//
// On Config load failure we intentionally don't fatal-error — the UI shows a
// ConfigurationErrorView with a retry + contact-support path so users aren't
// staring at a crashed app.

import SwiftUI
import OSLog

@main
struct StirApp: App {
    /// AppDelegate adaptor — exists solely for APNs token callbacks
    /// (SCA-316). SwiftUI's pure lifecycle has no equivalent surface.
    /// Stays thin: forwards token + failure to APNsRegistrationCoordinator.
    @UIApplicationDelegateAdaptor(StirAppDelegate.self) private var appDelegate

    private let configResult: Result<AppConfig, Error>
    @State private var coordinator: RootCoordinator?

    init() {
        let result = Result { try AppConfig.load() }
        self.configResult = result

        if case .success(let config) = result {
            if let sentryConfig = config.sentry {
                let environment: String
                #if DEBUG
                environment = "development"
                #else
                environment = "production"
                #endif
                SentryReporter.shared.initialize(
                    dsn: sentryConfig.dsn,
                    release: config.build,
                    environment: environment,
                )
            }

            if let posthogConfig = config.posthog {
                PostHogClient.shared.initialize(
                    apiKey: posthogConfig.apiKey,
                    host: posthogConfig.host,
                )
            }

            // RevenueCat SDK: configure at launch. Actor-internal guard
            // makes the call idempotent. If no key is configured (early
            // dev builds before Config.xcconfig is populated), the RC
            // service stays inert and every method returns an error the
            // paywall surfaces as PAY-01.
            if let revenueCat = config.revenueCat {
                Task {
                    await RevenueCatService.shared.configure(
                        apiKey: revenueCat.publicAPIKey,
                    )
                }
            }

            // Install the local-notification delegate so reactivation
            // delivery emits `reactivation_notification_opened` telemetry.
            StirNotificationDelegate.register()

            let rootCoordinator = RootCoordinator(config: config)
            // Step-8 APNs (SCA-316): wire the coordinator to AIDispatch so
            // device-token callbacks from StirAppDelegate can POST to
            // /v1/push/register. Configure must happen after AIDispatch is
            // built (RootCoordinator.init does that). Trigger registration
            // is done lazily — the coordinator only fires
            // `UIApplication.registerForRemoteNotifications()` when the
            // user has already granted notification permission, so first-
            // launch users see the in-app prompt before the OS prompt.
            APNsRegistrationCoordinator.shared.configure { [weak rootCoordinator] body in
                guard let dispatch = rootCoordinator?.aiDispatch else {
                    // SCA-371: RootCoordinator is documented to live for the
                    // app's full lifetime (RootCoordinator.swift:1312-1313),
                    // so this branch should be unreachable. Emit a fault-
                    // level log so OSLog dashboards surface the invariant
                    // violation if it ever fires. Throw .unknown (NET-01
                    // wire shape) — NOT .validation (VAL-01), which would
                    // pollute Sentry/PostHog dashboards that bucket by
                    // error code; this is an iOS-internal lifecycle bug,
                    // not a request-shape error.
                    struct RootCoordinatorDeallocated: Error {}
                    Logger.app.fault("apns_register_aborted reason=root_coordinator_deallocated")
                    throw StirError.unknown(underlying: RootCoordinatorDeallocated())
                }
                return try await dispatch.pushRegister(request: body)
            }
            Task { @MainActor in
                await APNsRegistrationCoordinator.shared.registerForRemoteNotificationsIfAuthorized()
            }

            _coordinator = State(wrappedValue: rootCoordinator)
            Logger.app.info("StirApp init ok build=\(config.build, privacy: .public)")
        } else if case .failure(let error) = result {
            Logger.app.error("StirApp config load failed: \(String(describing: error), privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            switch configResult {
            case .success:
                if let coordinator {
                    RootView(coordinator: coordinator)
                } else {
                    ConfigurationErrorView(
                        message: "Stir couldn't start. Please relaunch.",
                        onRetry: nil,
                    )
                }
            case .failure(let error):
                ConfigurationErrorView(
                    message: String(describing: error),
                    onRetry: nil,
                )
            }
        }
    }
}
