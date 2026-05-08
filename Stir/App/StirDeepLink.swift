// StirDeepLink
//
// Parses `stir://` URLs emitted by StirWidgets + TimerLiveActivity.
// Widgets can't present views; they hand a URL back to the app and
// the app decides where to land.
//
// Supported URLs (mirrors widget code):
//   stir://scan/start
//   stir://solve/<solveId>
//   stir://solve/<solveId>/dish/<dishId>
//   stir://cook/timer/<timerId>
//   stir://paywall/widget
//   stir://leftovers?source=notification          (SCA-65)
//   stir://tonight?use_first=<pantryItemId>        (SCA-64)
//
// Unknown paths fall through to `.unknown` and the app opens to its
// default destination — widgets failing silently is strictly better
// than a routing crash on an unexpected path.
//
// Routing in v1 covers the two highest-intent taps (paywall → presentPaywall,
// scan → coordinator signal consumed by TonightHomeView). Solve /
// dishPreview / cookTimer land on the app's default screen for now —
// the widget tap has already foregrounded the app, so the UX
// degradation is "wrong screen" not "broken." Full in-app navigation
// lands with the step-8 router refactor.

import Foundation
import OSLog

enum StirDeepLink: Equatable {
    case scanStart
    case solve(solveID: UUID)
    case dishPreview(solveID: UUID, dishID: UUID)
    case cookTimer(timerID: UUID)
    case paywallWidget
    /// SCA-65 — leftovers followup notification tapped at +20h post-cook.
    /// `source` is the originating surface ("notification" today; future
    /// in-app entry points may add new values without breaking the parse).
    case leftoversFollowup(source: String)
    /// SCA-64 — use-soon notification tapped. Carries the optional
    /// `useFirstPantryItemId` so Tonight Home can prefill the
    /// constraints sheet with "use first this ingredient" when the
    /// item is still in the pantry.
    case useSoon(useFirstPantryItemId: UUID?)
    case unknown(raw: String)

    /// Parse a URL into a typed destination. Returns `.unknown` for
    /// anything not in the above set. Never throws — widgets can't
    /// recover from parse errors so we swallow.
    ///
    /// Uses URLComponents (not URL.host/pathComponents) so step-8 can
    /// add query-string tagging — e.g. `stir://paywall/widget?source=
    /// tonight_small_widget` — without restructuring this parse (S14).
    static func parse(_ url: URL) -> StirDeepLink {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "stir" else {
            return .unknown(raw: url.absoluteString)
        }
        let host = components.host?.lowercased() ?? ""
        // URLComponents.path is the leading-slash absolute path; split
        // on "/" and drop empties to get the segment array the match
        // below expects.
        let segments = components.path.split(separator: "/").map(String.init)

        switch (host, segments) {
        case ("scan", ["start"]):
            return .scanStart
        case ("paywall", ["widget"]):
            return .paywallWidget
        case ("leftovers", _):
            // Path-segment-agnostic: stir://leftovers OR stir://leftovers/<anything>
            // both route here. `source` lifts off the query string; defaults
            // to "notification" when absent (the only producer today).
            let source = components.queryItems?
                .first(where: { $0.name == "source" })?.value ?? "notification"
            return .leftoversFollowup(source: source)
        case ("tonight", _):
            // SCA-64: stir://tonight?use_first=<uuid> from the use-soon
            // notification. UUID parse-failure falls through to nil
            // (the user still lands on Tonight Home; just no prefill).
            let raw = components.queryItems?
                .first(where: { $0.name == "use_first" })?.value
            let id = raw.flatMap(UUID.init(uuidString:))
            return .useSoon(useFirstPantryItemId: id)
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
        case .leftoversFollowup: return "notification.leftovers_followup"
        case .useSoon:           return "notification.use_soon"
        case .unknown:         return "deeplink.unknown"
        }
    }
}

/// Router handed to RootView.onOpenURL. Parses the URL, records a
/// breadcrumb, then dispatches to the coordinator for the cases we
/// actively handle. MainActor-isolated because every downstream
/// navigation mutation lands on main-actor state.
@MainActor
enum StirDeepLinkHandler {
    static func handle(_ url: URL, coordinator: RootCoordinator) {
        let destination = StirDeepLink.parse(url)
        Logger.app.info(
            "stir deep link \(destination.breadcrumbCategory, privacy: .public) url=\(url.absoluteString, privacy: .private(mask: .hash))",
        )
        switch destination {
        case .paywallWidget:
            // Highest-intent conversion tap per spec §9 — widget shows
            // "Widgets unlock with Premium" and the user taps through.
            // PaywallTrigger.widgetsGate carries the source tag for
            // downstream funnel analysis.
            coordinator.presentPaywall(.widgetsGate)
        case .scanStart:
            // Flip the coordinator-owned signal; TonightHomeView
            // observes via .onChange and flips its local showScanFlow
            // cover. Deferred into a Task so a scenePhase .active
            // transition happening in the same runloop tick finishes
            // before the modal request lands — avoids the "cover
            // presented during active bootstrap" iOS warning.
            Task { @MainActor in
                coordinator.requestDeepLinkScan()
            }
        case .leftoversFollowup:
            // SCA-65 v1: record the action so the unactioned-streak
            // suppression math doesn't penalize a user who tapped, then
            // land on Tonight Home (the app's default screen). A future
            // refactor can add a coordinator hook that looks up the most
            // recent leftover-eligible cook and routes straight to
            // LeftoversRoot — see follow-up filed at SCA-65 close-out.
            LeftoversFollowupScheduler.shared.recordAction()
        case .useSoon:
            // SCA-64 v1: record the action and land on Tonight. The
            // ConstraintsSheet prefill from `useFirstPantryItemId` is
            // out of scope for SCA-64 — it ships alongside the Tonight
            // Home use-soon card surface (see SCA-86). Until then the
            // user sees a familiar Tonight + can manually solve.
            UseSoonScheduler.shared.recordAction()
        case .solve, .dishPreview, .cookTimer, .unknown:
            // v1: widget/Live-Activity tap foregrounds the app; the
            // user lands on their last-active screen. Specific
            // destination routing comes with the step-8 navigation
            // refactor — see StirDeepLink top-level docstring.
            break
        }
    }
}
