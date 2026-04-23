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

/// Shared state between ShareViewController (which extracts the
/// PendingImport asynchronously) and this root view. Replaces the
/// NotificationCenter pattern whose subscription timing raced with
/// the extraction post, leaving the UI permanently stuck on
/// "Reading what you shared…" for text-only shares (CR1-22/DB1-22).
@Observable
@MainActor
final class ShareExtractionState {
    var pending: PendingImport?
    var isWaitingForExtraction: Bool = true
}

struct ShareExtensionRootView: View {
    let onSend: (PendingImport) -> Void
    let onCancel: () -> Void
    @Bindable var state: ShareExtractionState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if state.isWaitingForExtraction {
                PlaceholderCard()
            } else if let pending = state.pending {
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
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StirGlyph(size: 22)
                Text("Send to Stir")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ink500)
            }
            Text("Import this recipe?")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing shareable")
                .stirFont(.labelLg)
                .fontWeight(.semibold)
                .foregroundStyle(Color.Stir.ink900)
            Text("This page didn't include a URL or recipe text I could read.")
                .stirFont(.bodySm)
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
            .stirFont(.bodySm)
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
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
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
            .accessibilityLabel("Cancel")
            .accessibilityHint("Dismiss the share sheet without saving")
            Button {
                if let pending = state.pending { onSend(pending) }
            } label: {
                Text("Send to Stir")
                    .stirFont(.labelLg)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(state.pending == nil ? Color.Stir.ink300 : Color.Stir.ember600),
                    )
            }
            .disabled(state.pending == nil)
            .accessibilityLabel("Send to Stir")
            .accessibilityHint(state.pending == nil
                ? "Waiting for the shared content to load"
                : "Queues this recipe for import when you re-open Stir")
        }
    }
}

// MARK: - Payload cards

private struct PayloadCard: View {
    let pending: PendingImport
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pending.impliedSource == "share_sheet" ? "URL" : "Text")
                .stirFont(.labelMicroEyebrow)
                .foregroundStyle(Color.Stir.ember600)
            Text(pending.displayLabel)
                .stirFont(.bodyMd)
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
                .stirFont(.bodySm)
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
