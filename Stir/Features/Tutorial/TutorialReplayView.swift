// TutorialReplayView
//
// Per-tutorial replay surface (SCA-17 W9). Lists every TutorialKey
// with its displayName + replaySubtitle and a single-tap reset
// button per row. Replaces the prior all-or-nothing
// `coordinator.replayAllTutorials()` row in Settings — with 9 tours
// shipped, friction-of-replay-all was high enough most users would
// just not bother re-seeing the one tour they actually wanted.
//
// Replay flow per row:
//   tap → manager.reset(key) → tour re-arms next time the user
//   reaches its host surface (no tab routing here; that responsibility
//   stays with the coordinator's per-key replay path if needed).
//
// "Replay all" preserved at the bottom for the rare case where the
// user wants the full new-user welcome experience back.

import SwiftUI

struct TutorialReplayView: View {
    @Environment(RootCoordinator.self) private var coordinator
    @State private var lastResetKey: TutorialKey?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
                introBlock
                tutorialList
                replayAllButton
            }
            .padding(.horizontal, CGFloat.Stir.screenMargin)
            .padding(.top, CGFloat.Stir.space3)
            .padding(.bottom, CGFloat.Stir.space7 + CGFloat.Stir.space4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Stir.paper50)
        .navigationTitle("Replay tutorials")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Replay tutorials")
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.textPrimary)
            }
        }
        .toolbarBackground(Color.Stir.paper50, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var introBlock: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            Text("Pick one to walk through again next time you open it.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink700)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tutorialList: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Tutorials")
            VStack(spacing: 0) {
                ForEach(Array(TutorialKey.allCases.enumerated()), id: \.element) { idx, key in
                    if idx > 0 { rowDivider }
                    replayRow(for: key)
                }
            }
            .stirCard()
        }
    }

    private var replayAllButton: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            sectionEyebrow("Or all of them")
            SecondaryButton(title: "Replay every tutorial") {
                coordinator.replayAllTutorials()
                lastResetKey = nil
            }
        }
    }

    private func replayRow(for key: TutorialKey) -> some View {
        Button {
            TutorialManager.shared.reset(key)
            lastResetKey = key
        } label: {
            HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
                VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
                    Text(key.displayName)
                        .stirFont(.labelLg)
                        .foregroundStyle(Color.Stir.ember600)
                    Text(key.replaySubtitle)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink500)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if lastResetKey == key {
                        Text("Will replay next time you open it.")
                            .stirFont(.bodySm)
                            .foregroundStyle(Color.Stir.sage600)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: CGFloat.Stir.space2)
                Image.Stir.refresh
                    .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                    .foregroundStyle(Color.Stir.ink300)
            }
            .padding(.horizontal, CGFloat.Stir.space3Half)
            .padding(.vertical, CGFloat.Stir.space3Half)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Replay \(key.displayName)")
        .accessibilityHint(key.replaySubtitle)
    }

    private func sectionEyebrow(_ text: String) -> some View {
        Text(text)
            .stirFont(.labelEyebrow)
            .foregroundStyle(Color.Stir.textTertiary)
            .padding(.horizontal, CGFloat.Stir.space1)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.Stir.divider)
            .frame(height: 1)
            .padding(.leading, CGFloat.Stir.space3Half)
    }
}
