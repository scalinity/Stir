// TutorialStepView
//
// Single tutorial-step layout: ember-tinted icon disc → display
// headline → body message → optional content slot → CTA stack.

import SwiftUI

struct TutorialStepView<Content: View>: View {
    let icon: Image
    let iconTint: Color
    let headline: String
    /// Body copy. Named `message` to avoid shadowing SwiftUI's
    /// `var body: some View`.
    let message: String
    let content: Content
    let primaryLabel: String
    let primaryAction: () -> Void
    let skipAction: (() -> Void)?

    /// Icon glyph size — anchored to `iconXl` (44pt) so a future bump
    /// to the icon scale propagates here.
    @ScaledMetric(relativeTo: .largeTitle)
    private var iconGlyphSize: CGFloat = CGFloat.Stir.iconXl

    init(
        icon: Image,
        iconTint: Color = Color.Stir.ember600,
        headline: String,
        message: String,
        primaryLabel: String = "Next",
        primaryAction: @escaping () -> Void,
        skipAction: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
    ) {
        self.icon = icon
        self.iconTint = iconTint
        self.headline = headline
        self.message = message
        self.primaryLabel = primaryLabel
        self.primaryAction = primaryAction
        self.skipAction = skipAction
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: CGFloat.Stir.space5)

            VStack(spacing: CGFloat.Stir.space4) {
                iconBlock
                copyBlock
                content
                    .padding(.top, CGFloat.Stir.space3)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CGFloat.Stir.screenMargin)

            Spacer(minLength: CGFloat.Stir.space5)

            actionStack
                .padding(.horizontal, CGFloat.Stir.screenMargin)
                .padding(.bottom, CGFloat.Stir.space5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var iconBlock: some View {
        ZStack {
            // 96pt disc — generous tap-free tutorial icon, distinct
            // from the 32pt settings tile and the 44pt iconXl glyph
            // it contains. One-off; not promoted to a token until a
            // second tutorial surface uses the same disc.
            Circle()
                .fill(Color.Stir.ember100)
                .frame(width: 96, height: 96)
            icon
                .font(.system(size: iconGlyphSize, weight: .semibold))
                .foregroundStyle(iconTint)
        }
        .accessibilityHidden(true)
    }

    private var copyBlock: some View {
        VStack(spacing: CGFloat.Stir.space2) {
            Text(headline)
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            // 320pt message clamp — visual line-length cap that keeps
            // body copy in a comfortable reading column on iPhone
            // widths without wrapping awkwardly on iPad.
            Text(message)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
    }

    private var actionStack: some View {
        VStack(spacing: CGFloat.Stir.space2) {
            PrimaryButton(title: primaryLabel, action: primaryAction)
            if let skipAction {
                TextButton(title: "Skip", action: skipAction)
                    .accessibilityHint("Skip the rest of the tutorial")
            }
        }
    }
}

extension TutorialStepView where Content == EmptyView {
    init(
        icon: Image,
        iconTint: Color = Color.Stir.ember600,
        headline: String,
        message: String,
        primaryLabel: String = "Next",
        primaryAction: @escaping () -> Void,
        skipAction: (() -> Void)? = nil,
    ) {
        self.init(
            icon: icon,
            iconTint: iconTint,
            headline: headline,
            message: message,
            primaryLabel: primaryLabel,
            primaryAction: primaryAction,
            skipAction: skipAction,
        ) { EmptyView() }
    }
}

#Preview("TutorialStepView — light") {
    TutorialStepView(
        icon: Image.Stir.scan,
        headline: "Cook what you already have",
        message: "Scan your kitchen and Stir gives you three dinners ranked by what fits — then walks you through one.",
        primaryAction: {},
        skipAction: {},
    )
    .frame(width: 390, height: 720)
    .background(Color.Stir.paper50)
}
