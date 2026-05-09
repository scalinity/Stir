// StirNavigationTitle
//
// View modifier that renders a screen title in the Stir display serif via
// a `.principal` ToolbarItem, plus the matching paper50 toolbar background.
// Lifted from four feature-local copies (SCA-95: Settings root, Household
// preferences, Notifications, OutcomeFeedback) so the cross-tab nav-bar
// rhythm stays locked.
//
// Why principal-item over `navigationTitle`: the system `navigationTitle`
// chrome falls back to SF Pro and breaks the visual rhythm with Saved /
// Settings (Saved bypasses the bar entirely with `.safeAreaInset(.top)`,
// so principal-item is the only path that keeps the serif-headed
// surfaces in step). See `SavedMealsView` for the bypass pattern; it's
// intentionally not unified into this modifier.
//
// Pairs with `.navigationBarTitleDisplayMode(.inline)` at the call site.
// Callers retain that line because some screens (e.g. Settings root)
// also keep their own `.navigationTitle("…")` for VoiceOver / system
// back-button labelling, which this modifier doesn't override.

import SwiftUI

struct StirNavigationTitleModifier: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.textPrimary)
                }
            }
            .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

extension View {
    /// Renders `title` as a `.principal` ToolbarItem in the Stir display
    /// serif, with the paper50 toolbar background pinned visible. Pair
    /// with `.navigationBarTitleDisplayMode(.inline)` at the call site.
    func stirNavigationTitle(_ title: String) -> some View {
        modifier(StirNavigationTitleModifier(title: title))
    }
}
