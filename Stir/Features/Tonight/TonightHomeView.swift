// TonightHomeView
//
// Step-2 shell for spec §6's "Tonight Home". Three primary action buttons +
// recent-meals empty state + "Why Stir works" strip. All three actions are
// disabled placeholders in step 2:
//   - Scan Kitchen  → lands in step 3
//   - Import Recipe → lands in step 7
//   - Cook Saved    → lands in step 4
// Tapping any shows a "Coming soon" toast; we don't ship disabled visuals
// because those read as broken. Instead, the button taps surface an
// inline banner explaining when the feature arrives.

import SwiftUI

struct TonightHomeView: View {
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    greeting
                    primaryActions
                    recentMealsSection
                    whyStirStrip
                }
                .padding()
            }
            .navigationTitle("Tonight")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsRootView() } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .overlay(alignment: .top) { toastOverlay }
        }
    }

    // MARK: - Sections

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What's for dinner?")
                .font(.title2.weight(.semibold))
            Text("Start from your kitchen, a saved meal, or a recipe you found.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var primaryActions: some View {
        VStack(spacing: 12) {
            primaryButton(
                systemImage: "camera.viewfinder",
                title: "Scan Kitchen",
                subtitle: "Point at ingredients to get three dinner options.",
                tint: .orange,
                comingSoon: "Kitchen scan lands next release (step 3).",
            )
            primaryButton(
                systemImage: "square.and.arrow.down.on.square",
                title: "Import Recipe",
                subtitle: "Paste a URL or share from Safari to cook someone else's recipe.",
                tint: .purple,
                comingSoon: "Recipe import lands with Premium features (step 7).",
            )
            primaryButton(
                systemImage: "bookmark.fill",
                title: "Cook Saved",
                subtitle: "One-tap replay for your favorites.",
                tint: .indigo,
                comingSoon: "Saved meals land with Cook Mode (step 4).",
            )
        }
    }

    private func primaryButton(
        systemImage: String,
        title: String,
        subtitle: String,
        tint: Color,
        comingSoon: String,
    ) -> some View {
        Button {
            toastMessage = comingSoon
        } label: {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var recentMealsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent meals")
                .font(.headline)
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
                .frame(height: 80)
                .overlay(
                    Text("No recent meals yet — cook one to see it here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(),
                )
        }
    }

    private var whyStirStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Why Stir works")
                .font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                whyItem(icon: "fork.knife", text: "Your actual kitchen, not a generic recipe index.")
                whyItem(icon: "bolt.fill", text: "Three real dinners in under two minutes.")
                whyItem(icon: "hand.raised.fill", text: "Hard rules like allergies are never broken.")
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func whyItem(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(text).font(.subheadline)
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastOverlay: some View {
        if let toastMessage {
            Text(toastMessage)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.85), in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { self.toastMessage = nil }
                }
        }
    }
}

#Preview {
    TonightHomeView()
}
