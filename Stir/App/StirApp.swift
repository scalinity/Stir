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

    /// True when this process is the host app for the `StirTests` unit-test
    /// bundle (`TEST_HOST` in project.yml), not a real launch.
    ///
    /// Why it matters: XCTest boots the full app before injecting the test
    /// bundle, so without this guard every `xcodebuild test` run (including
    /// the pre-push hook) started the live Sentry + PostHog SDKs, ran the
    /// real RootCoordinator bootstrap against the configured backend, and
    /// shared `PersistenceController.shared` with the tests. Sentry then
    /// recorded the tests' stubbed 5xx responses (test.supabase.co /
    /// test.invalid hosts) as HTTPClientError issues, tests that block the
    /// main thread as App Hangs, the runner's teardown kill as a Fatal App
    /// Hang, and launch-path Core Data failures from the shared store, all
    /// under the `development` environment as if a user hit them (Sentry
    /// STIR-G, STIR-J, STIR-K, STIR-F and the 18 s STIR-H event, all
    /// lining up with test runs on Nov 6 2026).
    ///
    /// DEBUG-only so a Release build can never take the inert path. UI
    /// tests are unaffected: XCUIApplication launches the app as a normal
    /// process without the XCTest configuration environment.
    static var isHostingUnitTests: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
        #else
        return false
        #endif
    }

    init() {
        let result = Result { try AppConfig.load() }
        self.configResult = result

        // Unit-test host: stay inert. Tests build every dependency they
        // need themselves (in-memory PersistenceController, StubSentry,
        // MockURLProtocol sessions), so nothing below should run here.
        if Self.isHostingUnitTests {
            Logger.app.info("StirApp init skipped: hosting unit tests")
            return
        }

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
                    // SCA-409: shared marker type defined in
                    // APNsRegistrationCoordinator.swift so the classifier
                    // can `is`-check it without string-typed reflection.
                    Logger.app.fault("apns_register_aborted reason=root_coordinator_deallocated")
                    throw StirError.unknown(underlying: RootCoordinatorDeallocatedMarker())
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
            if Self.isHostingUnitTests {
                Color.clear
            } else {
                rootContent
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
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
