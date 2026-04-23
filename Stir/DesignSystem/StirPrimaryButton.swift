// StirPrimaryButton
//
// Shared 52pt ember primary button used by Import / Grocery /
// Leftovers / Share Extension. Pre-extraction the same ~15-line
// pattern lived as a copy-paste in 6+ files, and drift was already
// visible (48pt vs 52pt, ember vs paper, different disabled
// treatments). Single source of truth for the paper↔ember primary
// CTA so a design tweak doesn't scatter.
//
// Design:
//   - 52pt fixed height (matches mockups 08/11/12/16)
//   - Ember600 fill at full opacity, ink300 on disabled
//   - White text at 15pt semibold, inline spinner when `isBusy`
//   - 12pt rounded rect (matches mockup card radii)
//   - 44pt minHeight enforced via frame — fits HIG minimum even if
//     a caller shrinks the explicit 52pt via some outer layout
//
// Accessibility:
//   - accessibilityLabel set from the title
//   - .isButton trait (implicit via Button)
//   - busy state exposed as .updatesFrequently trait so VoiceOver
//     polls the spinner without re-announcing

import SwiftUI

struct StirPrimaryButton: View {
    let title: String
    let isBusy: Bool
    let isDisabled: Bool
    let action: () -> Void

    init(
        title: String,
        isBusy: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void,
    ) {
        self.title = title
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
