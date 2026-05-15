// StirTopBar
//
// Custom top bar that replaces the system `NavigationStack` toolbar on
// any screen that needs interactive buttons in the navigation chrome.
// Applied via the `.stirTopBar(...)` view extension which bundles
// `.toolbar(.hidden, for: .navigationBar)` (removes the system bar) +
// `.safeAreaInset(edge: .top)` (renders this view as the new bar).
//
// Why we own the chrome (SCA-436 → SCA-455 → SCA-457):
//
// iOS 26 applies its Liquid Glass material at the `ToolbarItem` layer,
// not at the button content layer. That means:
//   - `.buttonStyle(.plain)` does NOT suppress the glass capsule.
//   - Even a fully-custom `StirCircleIconButton` content gets wrapped
//     in a frosted pill when it lives inside `.toolbar { ToolbarItem }`.
//   - There's no per-item / per-toolbar SwiftUI knob to opt out.
//
// The only reliable escape is to hide the system bar and render our
// own in `.safeAreaInset(.top)`. This component is that bar.
//
// Visual grammar (mirrors mockup 06 `_cook_mode_tap.html`, mockup 11
// `_settings.html` chrome rules):
//   - 56pt minimum height with 12pt horizontal + 8pt vertical padding
//   - paper.50 fill (screen background) with a 1pt divider hairline at
//     the bottom edge — same hairline grammar as the bottom action bar
//     used in OutcomeFeedbackView / Cook Mode / DishPreview's Start
//     Cooking bar
//   - serif `displaySm` title, centered when both flanks are present,
//     leading-aligned otherwise (matches what `stirNavigationTitle`
//     does for principal-only screens, but without the toolbar)
//   - Leading / trailing slots are ViewBuilder so callers can drop in
//     `StirCircleIconButton`, plain text buttons, or stacks of either
//
// Title centering rules:
//   - centered (default) when both leading AND trailing are provided
//   - leading-aligned when only one side has content (matches iOS
//     navigation bar behaviour when the title can't fit between
//     unbalanced flanks)
//
// Not used by:
//   - `SavedMealsView` — uses its own `.safeAreaInset(.top)` header
//     with a search bar embedded, which is its own grammar
//   - `DishPreviewView` / `PaywallView` — already use bespoke
//     safeAreaInset headers built ahead of this component; they'll
//     migrate to `.stirTopBar` in a follow-up cleanup

import SwiftUI

struct StirTopBar<Leading: View, Trailing: View>: View {
    let title: String?
    let leading: Leading
    let trailing: Trailing

    init(
        title: String? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing,
    ) {
        self.title = title
        self.leading = leading()
        self.trailing = trailing()
    }

    private var hasLeading: Bool { Leading.self != EmptyView.self }
    private var hasTrailing: Bool { Trailing.self != EmptyView.self }

    var body: some View {
        HStack(alignment: .center, spacing: CGFloat.Stir.space2) {
            leading

            if let title {
                Text(title)
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: hasLeading && hasTrailing ? .center : .leading)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Spacer(minLength: 0)
            }

            trailing
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space2)
        .frame(minHeight: 56)
        .background(Color.Stir.paper50)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.Stir.divider)
                .frame(height: 1)
        }
    }
}

// MARK: - View extension

extension View {
    /// Hide the iOS-26 system navigation bar and render a custom
    /// Stir top bar via `.safeAreaInset(.top)`. The reliable way to
    /// avoid Liquid Glass on toolbar Buttons.
    func stirTopBar<Leading: View, Trailing: View>(
        title: String? = nil,
        @ViewBuilder leading: () -> Leading = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
    ) -> some View {
        let bar = StirTopBar(title: title, leading: leading, trailing: trailing)
        return self
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { bar }
    }
}

// MARK: - Button helper

/// Text-style toolbar action. Standard Stir styling for "Cancel" / "Done" /
/// "Save" / "Close" buttons that previously sat inside `.topBarLeading` /
/// `.topBarTrailing` toolbar items. The bold weight + ember tint signals
/// the button is interactive without relying on the system's Liquid Glass
/// pill background.
///
/// Use the `prominent` variant for the primary confirm-action ("Save",
/// "Add", "Import") on the trailing edge — semibold + labelLg matches
/// the call-site styling that several pre-SCA-457 toolbars used.
struct StirTopBarTextButton: View {
    enum Emphasis {
        case standard
        case prominent
    }

    let title: String
    let emphasis: Emphasis
    let isEnabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        emphasis: Emphasis = .standard,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
    ) {
        self.title = title
        self.emphasis = emphasis
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .stirFont(emphasis == .prominent ? .labelLg : .bodyMd)
                .fontWeight(emphasis == .prominent ? .semibold : .regular)
                .foregroundStyle(isEnabled ? Color.Stir.ember600 : Color.Stir.ink300)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Previews

#Preview("StirTopBar — title only") {
    StirTopBar(title: "Tonight's constraints", leading: { EmptyView() }, trailing: { EmptyView() })
        .background(Color.Stir.paper50)
}

#Preview("StirTopBar — Cancel + title + Save") {
    StirTopBar(
        title: "Edit item",
        leading: { StirTopBarTextButton("Cancel") {} },
        trailing: { StirTopBarTextButton("Save", emphasis: .prominent) {} },
    )
    .background(Color.Stir.paper50)
}

#Preview("StirTopBar — title + Done") {
    StirTopBar(
        title: "Compare plans",
        leading: { EmptyView() },
        trailing: { StirTopBarTextButton("Done") {} },
    )
    .background(Color.Stir.paper50)
}

#Preview("StirTopBar — Back + title + cart + star") {
    StirTopBar(
        title: "Grilled Salmon with Pesto Penne",
        leading: {
            StirCircleIconButton(
                icon: Image(systemName: "chevron.left"),
                accessibilityLabel: "Back",
                action: {},
            )
        },
        trailing: {
            HStack(spacing: CGFloat.Stir.space1) {
                StirCircleIconButton(icon: Image.Stir.cart, accessibilityLabel: "Cart", action: {})
                StirCircleIconButton(icon: Image(systemName: "star"), accessibilityLabel: "Favorite", action: {})
            }
        },
    )
    .background(Color.Stir.paper50)
}
