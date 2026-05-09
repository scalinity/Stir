// UseSoonCard
//
// SCA-250 (W2 from /review-5): extracted from TonightHomeView.swift
// where SCA-86 originally inlined this view as a `private struct`.
// SCA-94 had refactored TonightHomeView to clear the SwiftUI typecheck
// ceiling; SCA-86 immediately added 358 LOC back to the same file by
// inlining UseSoonCard / WidgetNudgeCard / WidgetSetupGuideView. This
// extraction restores the per-file separation matching the rest of
// `Stir/Features/Tonight/` (CookModeRoot, OtherOptionsRoot,
// SolveAgainRoot — all single-component files).
//
// Consumes `TonightHomeView.UseSoonCandidate` (kept on TonightHomeView
// since it's the only consumer; promote to a top-level type if a
// second consumer ever appears).
//
// Visual: sage-tinted card surfacing one expiring pantry item with a
// "Use <name> soon" headline + relative-time subtitle and a tap
// affordance into the use-first solve flow.

import SwiftUI

struct UseSoonCard: View {
    let candidate: TonightHomeView.UseSoonCandidate
    let onSolve: () -> Void

    var body: some View {
        Button(action: onSolve) {
            HStack(alignment: .center, spacing: CGFloat.Stir.space3) {
                Image.Stir.pantry
                    .font(.system(size: CGFloat.Stir.iconLg, weight: .semibold))
                    .foregroundStyle(Color.Stir.sage600)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                            .fill(Color.Stir.sage100),
                    )

                VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                    Text("Use \(candidate.displayName) soon")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.ink900)
                        .lineLimit(2)
                    Text(candidate.subtitle())
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image.Stir.disclosure
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink300)
            }
            .padding(CGFloat.Stir.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .stirCard(
                fill: Color.Stir.sage100.opacity(0.45),
                borderColor: Color.Stir.sage600.opacity(0.25),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use \(candidate.displayName) soon")
        .accessibilityHint("Find dinner ideas that prioritize this ingredient")
    }
}

// MARK: - Previews
//
// SCA-275/S17 (parent SCA-243): #Preview blocks for the SCA-86/87 cards.
// `TonightPickHeroCard` already had previews; the new cards didn't.
// Adding light-state previews now that the views live in dedicated
// files where Xcode's preview canvas can render them in isolation.

#Preview("UseSoonCard") {
    UseSoonCard(
        candidate: TonightHomeView.UseSoonCandidate(
            id: UUID(),
            displayName: "Spinach",
            expiresAt: Date().addingTimeInterval(36 * 3600),
        ),
        onSolve: {},
    )
    .padding()
    .background(Color.Stir.paper50)
}
