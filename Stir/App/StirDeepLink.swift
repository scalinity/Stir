// StirDeepLink
//
// Parses `stir://` URLs emitted by StirWidgets + TimerLiveActivity.
// Widgets can't present views; they hand a URL back to the app and
// the app decides where to land. For v1 the handler just categorizes
// the destination and logs; full routing (navigating to a specific
// DishPreview, scrolling to a solve, opening the paywall with widget
// trigger) arrives with the step-8 router refactor.
//
// Supported URLs (mirrors widget code):
//   stir://scan/start
//   stir://solve/<solveId>
//   stir://solve/<solveId>/dish/<dishId>
//   stir://cook/timer/<timerId>
//   stir://paywall/widget
//
// Unknown paths fall through to `.unknown` and the app opens to its
// default destination — widgets failing silently is strictly better
// than a routing crash on an unexpected path.

import Foundation
import OSLog

enum StirDeepLink: Equatable {
    case scanStart
    case solve(solveID: UUID)
    case dishPreview(solveID: UUID, dishID: UUID)
    case cookTimer(timerID: UUID)
    case paywallWidget
    case unknown(raw: String)

    /// Parse a URL into a typed destination. Returns `.unknown` for
    /// anything not in the above set. Never throws — widgets can't
    /// recover from parse errors so we swallow.
    static func parse(_ url: URL) -> StirDeepLink {
        guard url.scheme?.lowercased() == "stir" else {
            return .unknown(raw: url.absoluteString)
        }
        // URLComponents splits host + path differently than URL for
        // custom schemes; use a simple component split.
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        switch (host, segments) {
        case ("scan", ["start"]):
            return .scanStart
        case ("paywall", ["widget"]):
            return .paywallWidget
        case ("solve", let parts) where parts.count == 1:
            guard let solveID = UUID(uuidString: parts[0]) else {
                return .unknown(raw: url.absoluteString)
            }
            return .solve(solveID: solveID)
        case ("solve", let parts) where parts.count == 3 && parts[1] == "dish":
            guard let solveID = UUID(uuidString: parts[0]),
                  let dishID = UUID(uuidString: parts[2]) else {
                return .unknown(raw: url.absoluteString)
            }
            return .dishPreview(solveID: solveID, dishID: dishID)
        case ("cook", let parts) where parts.count == 2 && parts[0] == "timer":
            guard let timerID = UUID(uuidString: parts[1]) else {
                return .unknown(raw: url.absoluteString)
            }
            return .cookTimer(timerID: timerID)
        default:
            return .unknown(raw: url.absoluteString)
        }
    }

    /// Sentry breadcrumb label — used by the routing handler to tag
    /// widget-origin opens so step-8 analytics can split widget-tap
    /// activation from cold-launch activation.
    var breadcrumbCategory: String {
        switch self {
        case .scanStart:       return "widget.scan"
        case .solve:           return "widget.solve"
        case .dishPreview:     return "widget.dish"
        case .cookTimer:       return "liveactivity.timer"
        case .paywallWidget:   return "widget.paywall"
        case .unknown:         return "deeplink.unknown"
        }
    }
}

/// Minimal router handed to RootView.onOpenURL. Parses the URL,
/// records a breadcrumb, and — for v1 — relies on scene state to
/// settle. Widgets already open the app; the default launch
/// destination (Tonight Home or the user's last state) is acceptable
/// until step-8 routes to specific screens.
@MainActor
enum StirDeepLinkHandler {
    static func handle(_ url: URL) {
        let destination = StirDeepLink.parse(url)
        Logger.app.info(
            "stir deep link \(destination.breadcrumbCategory, privacy: .public) url=\(url.absoluteString, privacy: .public)",
        )
        // Step-8 TODO: route to specific destination. For v1 the
        // widget tap has already brought the app to the foreground —
        // users land on their last-active screen, which covers the
        // "glance at tonight's dish" job. Specific destinations
        // (DishPreview, paywall with widget source, Cook-mode-resume
        // focused on a specific timer) come with the router refactor.
    }
}
