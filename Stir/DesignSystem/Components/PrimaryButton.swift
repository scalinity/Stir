// PrimaryButton
//
// The single most important action on a screen (Specs/Design-System.md §8.1).
// Used everywhere a full-width ember CTA appears: onboarding CTAs, Solve
// constraints submit, Cook Mode Next Step, Paywall feature-modal, Import
// review Save, Grocery export, Leftovers follow-up.
//
// Previously named `StirPrimaryButton` and co-located at
// `Stir/DesignSystem/StirPrimaryButton.swift`. Step-9 design pass renamed
// it per spec §12: components live in `Stir/DesignSystem/Components/` and
// drop the `Stir` prefix since the folder IS the namespace.
//
// Design:
//   - 52pt fixed height (mockups 08/11/12/16 — slightly taller than the
//     spec §8.1 48pt minimum for extra presence on hero CTAs)
//   - `minHeight: 44` floor for HIG accessibility
//   - `ember.600` fill at full opacity; `ink.300` on disabled/busy
//   - `paper.50` label at `.labelLg` + semibold override
//   - `radius.md` (12pt) per spec §5.4 / §8.1
//   - ProgressView inline when `isBusy`; Button disabled while busy
//
// Accessibility:
//   - accessibilityLabel set from title (exposes CTA intent to VoiceOver)
//   - Implicit `.isButton` from Button
//   - Busy state exposes `.updatesFrequently` so VoiceOver polls the
//     spinner without re-announcing the title each tick

import SwiftUI

struct PrimaryButton: View {
    let title: String
    let trailingIcon: Image?
    let isBusy: Bool
    let isDisabled: Bool
    let action: () -> Void

    init(
        title: String,
        trailingIcon: Image? = nil,
        isBusy: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void,
    ) {
        self.title = title
        self.trailingIcon = trailingIcon
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt — slightly tighter than space3
                if isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(Color.Stir.paper50)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.Stir.paper50)
                if let trailingIcon, !isBusy {
                    trailingIcon
                        // justification: 16pt trailing-icon glyph aligned with .labelLg cap-height; matches mockup-04 §Review CTA arrow proportions
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.Stir.paper50)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                    .fill(resolvedBackground),
            )
            .contentShape(Rectangle())
        }
        .disabled(isDisabled || isBusy)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isBusy ? [.updatesFrequently] : [])
    }

    private var resolvedBackground: Color {
        (isDisabled || isBusy) ? Color.Stir.ink300 : Color.Stir.ember600
    }
}

// MARK: - Previews

#Preview("PrimaryButton — light") {
    PrimaryButtonGallery()
        .padding(CGFloat.Stir.space4)
        .frame(width: 390, height: 844)
        .background(Color.Stir.paper50)
}

#Preview("PrimaryButton — dark") {
    PrimaryButtonGallery()
        .padding(CGFloat.Stir.space4)
        .frame(width: 390, height: 844)
        .background(Color.Stir.paper50)
        .preferredColorScheme(.dark)
}

#Preview("PrimaryButton — busy state") {
    VStack(spacing: CGFloat.Stir.space4) {
        Text("Spinner animation isolated so Xcode's canvas runs it continuously rather than snapshotting it once.")
            .stirFont(.bodySm)
            .foregroundStyle(Color.Stir.textTertiary)
        PrimaryButton(title: "Importing…", isBusy: true, action: {})
    }
    .padding(CGFloat.Stir.space4)
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}

private struct PrimaryButtonGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
            Group {
                label("Default")
                PrimaryButton(title: "Start 7-day free trial", action: {})

                label("Busy")
                PrimaryButton(title: "Starting trial…", isBusy: true, action: {})

                label("Disabled")
                PrimaryButton(title: "Next Step", isDisabled: true, action: {})
            }
            Spacer()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
    }
}
