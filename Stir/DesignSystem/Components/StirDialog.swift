// StirDialog
//
// Centered-modal alert/confirmation in the Stir design grammar. Replaces
// the native `.alert(...)` and `.confirmationDialog(...)` primitives in
// any feature that wants the popup to look like part of the app rather
// than the system action sheet. SCA-427.
//
// Visual grammar (Specs/Design-System.md §5.5 "centered modal"):
//   - paper.100 card surface on a 40% black scrim (dim backdrop)
//   - radius.xl (22pt) — the centered-modal radius token
//   - .modal shadow (the deepest elevation in the system)
//   - displaySm serif title, bodyMd message body
//   - Vertically stacked buttons sized to match PrimaryButton/SecondaryButton
//     (52pt height, radius.md, semibold .labelLg)
//   - Fade+scale entry via .stirAnimation(.Stir.standard) — Reduce Motion
//     downgrades to instant
//
// Why a custom centered overlay (not `.alert`, `.confirmationDialog`,
// `.sheet`, or `.fullScreenCover`):
//   - `.alert` / `.confirmationDialog` route through UIAlertController
//     which can't be themed; they always render with system fonts +
//     system blue accent.
//   - `.sheet` with detents (the SCA-50 `PantryDeleteAllConfirmationSheet`
//     pattern) gives a bottom-sheet feel — appropriate for irreversible
//     bulk actions but mismatched with the centered "alert" reading
//     expected by Cook Mode exit, error alerts, and inline edit prompts.
//   - `.fullScreenCover` has a fixed slide-up presentation animation
//     and presents on its own NSWindow which fights tap-outside-to-dismiss.
//   - Overlay ZStack on the host view lets us own the backdrop, the
//     animation curve, and the dismiss gesture in ~80 lines of SwiftUI.
//
// API mirrors SwiftUI's `.alert` shape:
//
//     .stirDialog(
//         isPresented: $showingExit,
//         title: "Leave Cook Mode?",
//         message: "Your progress is saved. You can resume from Tonight Home.",
//         buttons: [
//             .secondary("Pause and resume later") { /* … */ },
//             .destructive("Abandon session")     { /* … */ },
//             .cancel("Keep cooking"),
//         ],
//     )
//
// Buttons render in the order given. The `cancel` role auto-dismisses
// without invoking a body closure; other roles flip `isPresented` to
// false and then run their action. Tap on the scrim also dismisses
// (treated as cancel).

import SwiftUI

// MARK: - Button model

/// A button inside a `StirDialog`. Use the static factories
/// (`.primary`, `.secondary`, `.destructive`, `.cancel`) at call sites
/// rather than constructing directly — the role drives visual style.
struct StirDialogButton: Identifiable {
    enum Role {
        /// Ember-filled CTA. Use for the action you want the user to
        /// take by default ("Save", "OK").
        case primary
        /// Paper-bordered neutral action. The "second answer" — pairs
        /// with `.primary` or stands alone for non-destructive options.
        case secondary
        /// Crimson-text destructive action. Use for irreversible /
        /// data-losing actions ("Abandon session", "Delete").
        case destructive
        /// Tertiary dismissive action. Renders as ember text on the
        /// paper surface — visually lighter than `.secondary`. Auto-
        /// dismisses; the supplied action runs in addition to dismiss.
        case cancel
    }

    let id = UUID()
    let title: String
    let role: Role
    let action: () -> Void

    static func primary(_ title: String, action: @escaping () -> Void) -> StirDialogButton {
        StirDialogButton(title: title, role: .primary, action: action)
    }

    static func secondary(_ title: String, action: @escaping () -> Void) -> StirDialogButton {
        StirDialogButton(title: title, role: .secondary, action: action)
    }

    static func destructive(_ title: String, action: @escaping () -> Void) -> StirDialogButton {
        StirDialogButton(title: title, role: .destructive, action: action)
    }

    /// Cancel button with no side-effect action — only dismisses.
    static func cancel(_ title: String = "Cancel") -> StirDialogButton {
        StirDialogButton(title: title, role: .cancel, action: {})
    }

    /// Cancel button that also runs an action (e.g. clearing a buffer).
    static func cancel(_ title: String, action: @escaping () -> Void) -> StirDialogButton {
        StirDialogButton(title: title, role: .cancel, action: action)
    }
}

// MARK: - View extensions

extension View {
    /// Title + message + buttons. Drop-in replacement for `.alert` /
    /// `.confirmationDialog` that renders in the Stir grammar.
    func stirDialog(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        buttons: [StirDialogButton],
    ) -> some View {
        modifier(StirDialogModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            content: { EmptyView() },
            buttons: buttons,
        ))
    }

    /// Title + custom slot (e.g. an `InputField`) + buttons. Use when
    /// the dialog needs an inline form field — the slot renders between
    /// the title and the button stack.
    func stirDialog<DialogContent: View>(
        isPresented: Binding<Bool>,
        title: String,
        message: String? = nil,
        buttons: [StirDialogButton],
        @ViewBuilder content: @escaping () -> DialogContent,
    ) -> some View {
        modifier(StirDialogModifier(
            isPresented: isPresented,
            title: title,
            message: message,
            content: content,
            buttons: buttons,
        ))
    }
}

// MARK: - Modifier (overlay host)

private struct StirDialogModifier<DialogContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String?
    @ViewBuilder let content: () -> DialogContent
    let buttons: [StirDialogButton]

    func body(content hostContent: Content) -> some View {
        hostContent
            .overlay {
                if isPresented {
                    StirDialogOverlay(
                        title: title,
                        message: message,
                        slot: content(),
                        buttons: buttons,
                        onDismiss: { isPresented = false },
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .stirAnimation(.Stir.standard, value: isPresented)
    }
}

// MARK: - Overlay (backdrop + card)

private struct StirDialogOverlay<Slot: View>: View {
    let title: String
    let message: String?
    let slot: Slot
    let buttons: [StirDialogButton]
    let onDismiss: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ZStack {
            // 40% black scrim — same dim as native UIAlertController so
            // the surrounding screen recedes without going pitch black.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            VStack(spacing: CGFloat.Stir.space4) {
                VStack(spacing: CGFloat.Stir.space2) {
                    Text(title)
                        .stirFont(.displaySm)
                        .foregroundStyle(Color.Stir.ink900)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    if let message {
                        Text(message)
                            .stirFont(.bodyMd)
                            .foregroundStyle(Color.Stir.ink500)
                            .multilineTextAlignment(.center)
                    }
                }

                // EmptyView is a no-op in a VStack (zero size, no
                // spacing contribution), so the previous
                // `Slot.self != EmptyView.self` runtime metatype check
                // added a per-body branch without changing behaviour.
                slot

                VStack(spacing: CGFloat.Stir.space2) {
                    ForEach(buttons) { button in
                        StirDialogButtonView(
                            button: button,
                            onTap: { handle(button) },
                        )
                    }
                }
            }
            .padding(CGFloat.Stir.space5)
            .frame(maxWidth: 320)
            // Card surface: .stirCard collapses the previous
            // background-RoundedRect + overlay-stroke pair (W-C W15)
            // so the fill and stroke radii can't drift apart. SCA-434:
            // fill is paper.50 (the screen background) rather than the
            // usual paper.100 card surface so the in-card buttons
            // (paper.100) read as a brighter step-up layer on top —
            // matches the elevation grammar elsewhere in the app
            // (screens = paper.50, cards-on-screens = paper.100).
            .stirCard(
                fill: Color.Stir.paper50,
                radius: CGFloat.Stir.radiusXl,
            )
            .stirShadow(.modal)
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            // VoiceOver: treat the card as a modal so VO doesn't read
            // the underlying screen, give it an .escape action mapped
            // to dismiss (two-finger Z gesture), and force focus onto
            // the title when the overlay first appears so a blind user
            // hears the dialog announce itself the way native .alert
            // does. The .onAppear flips titleFocused after one runloop
            // because @AccessibilityFocusState changes issued during
            // the same body pass as the view appears are coalesced.
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, onDismiss)
            .onAppear {
                DispatchQueue.main.async { titleFocused = true }
            }
        }
    }

    private func handle(_ button: StirDialogButton) {
        // Dismiss first so the surrounding view ticks animation state
        // back to .closed before the action mutates VM state; matches
        // the system alert dismissal order and avoids the "dialog
        // re-presents itself for one frame because the action set a
        // bool that re-trips the binding" race.
        onDismiss()
        button.action()
    }
}

// MARK: - Button

private struct StirDialogButtonView: View {
    let button: StirDialogButton
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(button.title)
                .stirFont(.labelLg)
                .fontWeight(weight)
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .fill(fill),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                        .strokeBorder(border, lineWidth: borderWidth),
                )
                .contentShape(Rectangle())
        }
        .accessibilityLabel(button.title)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(button.role == .destructive
            ? "Discards your progress"
            : "")
    }

    private var foreground: Color {
        switch button.role {
        case .primary:     return Color.Stir.paper50
        case .secondary:   return Color.Stir.ink900
        case .destructive: return Color.Stir.crimson600
        case .cancel:      return Color.Stir.ember600
        }
    }

    private var fill: Color {
        switch button.role {
        case .primary:     return Color.Stir.ember600
        case .secondary:   return Color.Stir.paper100
        case .destructive: return Color.Stir.paper100
        case .cancel:      return .clear
        }
    }

    private var border: Color {
        switch button.role {
        case .primary:     return .clear
        case .secondary:   return Color.Stir.divider
        case .destructive: return Color.Stir.crimson600.opacity(0.35)
        case .cancel:      return .clear
        }
    }

    private var borderWidth: CGFloat {
        switch button.role {
        case .primary, .cancel: return 0
        case .secondary, .destructive: return 1
        }
    }

    private var weight: Font.Weight {
        switch button.role {
        case .primary, .secondary, .destructive: return .semibold
        case .cancel: return .medium
        }
    }
}

// MARK: - Previews

#Preview("StirDialog — Cook Mode exit (light)") {
    PreviewHost(message: "Your progress is saved. You can resume from Tonight Home.")
        .preferredColorScheme(.light)
}

#Preview("StirDialog — Cook Mode exit (dark)") {
    PreviewHost(message: "Your progress is saved. You can resume from Tonight Home.")
        .preferredColorScheme(.dark)
}

#Preview("StirDialog — error alert (single OK)") {
    SingleOKHost()
        .preferredColorScheme(.light)
}

private struct PreviewHost: View {
    let message: String
    @State private var showing = true

    var body: some View {
        ZStack {
            Color.Stir.paper50.ignoresSafeArea()
            VStack {
                Text("Cook Mode would be rendering behind the modal.")
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink500)
                    .padding()
                Button("Re-show dialog") { showing = true }
                    .padding()
            }
        }
        .stirDialog(
            isPresented: $showing,
            title: "Leave Cook Mode?",
            message: message,
            buttons: [
                .secondary("Pause and resume later") {},
                .destructive("Abandon session") {},
                .cancel("Keep cooking"),
            ],
        )
    }
}

private struct SingleOKHost: View {
    @State private var showing = true

    var body: some View {
        ZStack {
            Color.Stir.paper50.ignoresSafeArea()
        }
        .stirDialog(
            isPresented: $showing,
            title: "Something went wrong",
            message: "We couldn't reach your kitchen. Check your connection and try again.",
            buttons: [.primary("OK") {}],
        )
    }
}
