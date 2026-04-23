// ShareExtensionRootView
//
// SwiftUI content hosted inside ShareViewController. Shows the
// captured URL/text, a short "What happens next" note, and primary/
// secondary CTAs.
//
// Visual grammar matches Stir's main-app tokens (paper50 card on
// slightly-darker paper200 back, ember primary, ink hierarchy) so
// the extension reads as Stir rather than a generic iOS share sheet.

import SwiftUI

struct ShareExtensionRootView: View {
    let onSend: (PendingImport) -> Void
    let onCancel: () -> Void

    @State private var pending: PendingImport?
    @State private var isWaitingForExtraction: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isWaitingForExtraction {
                PlaceholderCard()
            } else if let pending {
                PayloadCard(pending: pending)
                infoNote
            } else {
                emptyCard
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.Stir.paper200.ignoresSafeArea())
        .onReceive(NotificationCenter.default.publisher(
            for: .stirShareExtensionDidExtract,
        )) { note in
            if let extracted = note.object as? PendingImport {
                pending = extracted
                isWaitingForExtraction = false
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StirGlyph(size: 22)
                Text("Send to Stir")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.32)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.ink500)
            }
            Text("Import this recipe?")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .tracking(-0.22)
                .foregroundStyle(Color.Stir.ink900)
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing shareable")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.Stir.ink900)
            Text("This page didn't include a URL or recipe text I could read.")
                .font(.system(size: 13))
                .foregroundStyle(Color.Stir.ink500)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Stir.paper100),
        )
    }

    private var infoNote: some View {
        Text("Opening Stir will finish parsing + save this to your recipes.")
            .font(.system(size: 12))
            .foregroundStyle(Color.Stir.ink500)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.Stir.paper100),
            )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink700)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.Stir.paper100),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.Stir.ink100, lineWidth: 1),
                    )
            }
            Button {
                if let pending { onSend(pending) }
            } label: {
                Text("Send to Stir")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(pending == nil ? Color.Stir.ink300 : Color.Stir.ember600),
                    )
            }
            .disabled(pending == nil)
        }
    }
}

// MARK: - Payload cards

private struct PayloadCard: View {
    let pending: PendingImport
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pending.impliedSource == "share_sheet" ? "URL" : "Text")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.Stir.ember600)
            Text(pending.displayLabel)
                .font(.system(size: 14))
                .foregroundStyle(Color.Stir.ink900)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.Stir.ember600.opacity(0.3), lineWidth: 1),
        )
    }
}

private struct PlaceholderCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.Stir.ember600)
            Text("Reading what you shared…")
                .font(.system(size: 13))
                .foregroundStyle(Color.Stir.ink500)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Stir.paper100),
        )
    }
}
