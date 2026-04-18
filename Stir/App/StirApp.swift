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

            _coordinator = State(wrappedValue: RootCoordinator(config: config))
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
