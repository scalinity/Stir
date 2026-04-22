// StirWidgetsBundle
//
// @main entry point for the widget extension. Hosts every widget +
// live activity surface Stir ships:
//
//   - TonightWidget — Home Screen widget (small/medium/large) showing
//     the latest SuggestedDish trio. Premium+ gated via the cached
//     tier in SharedStorage.
//   - TimerLiveActivity — ActivityKit widget fired whenever a
//     CookTimer transitions to `.running`. Lock Screen + Dynamic Island
//     views. Not entitlement-gated at the widget layer (Cook Mode is
//     universally available; only the voice affordance is Premium+).
//
// No network calls. Everything reads from SharedStorage or from the
// activity's ContentState. Main-app-driven reload via
// `WidgetCenter.shared.reloadAllTimelines()` keeps the cache fresh.

import SwiftUI
import WidgetKit

@main
struct StirWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TonightWidget()
        TimerLiveActivity()
    }
}
