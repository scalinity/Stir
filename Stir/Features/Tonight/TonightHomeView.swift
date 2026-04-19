// TonightHomeView
//
// Step-3 iteration:
//   - Scan Kitchen → presents ScanFlowRoot as fullScreenCover
//   - Import Recipe + Cook Saved remain disabled (step 4 + step 7)
//   - Respects the disable_scan_parse kill switch from the latest config
//     bootstrap response by rendering Scan Kitchen in a disabled state
//     with "Temporarily unavailable" copy.

import SwiftUI

struct TonightHomeView: View {
    let coordinator: RootCoordinator

    @Environment(EntitlementService.self) private var entitlements
    @State private var toastMessage: String?
    @State private var showScanFlow = false

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
            .fullScreenCover(isPresented: $showScanFlow) {
                ScanFlowRoot(
                    aiDispatch: coordinator.aiDispatch,
                    pantryRepo: coordinator.pantryItemRepository,
                    solveRepo: coordinator.solveRepository,
                    householdStore: coordinator.household,
                    entitlements: entitlements,
                )
            }
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
            scanKitchenButton
            primaryButton(
                systemImage: "square.and.arrow.down.on.square",
                title: "Import Recipe",
                subtitle: "Paste a URL or share from Safari to cook someone else's recipe.",
                tint: .purple,
                enabled: false,
                comingSoon: "Recipe import lands with Premium features (step 7).",
            )
            primaryButton(
                systemImage: "bookmark.fill",
                title: "Cook Saved",
                subtitle: "One-tap replay for your favorites.",
                tint: .indigo,
                enabled: false,
                comingSoon: "Saved meals land with Cook Mode (step 4).",
            )
        }
    }

    private var scanKitchenButton: some View {
        let killed = scanIsKillSwitched
        return Button {
            if killed {
                toastMessage = "Kitchen scan is temporarily unavailable. Try a saved meal instead."
            } else {
                showScanFlow = true
            }
        } label: {
            buttonRow(
                systemImage: "camera.viewfinder",
                title: killed ? "Kitchen scan temporarily unavailable" : "Scan Kitchen",
                subtitle: killed
                    ? "We've paused scans while we investigate an issue."
                    : "Point at ingredients to get three dinner options.",
                tint: killed ? .secondary : .orange,
                enabled: !killed,
            )
        }
        .buttonStyle(.plain)
    }

    private func primaryButton(
        systemImage: String,
        title: String,
        subtitle: String,
        tint: Color,
        enabled: Bool,
        comingSoon: String,
    ) -> some View {
        Button {
            if enabled { /* no-op (no other enabled buttons in step 3) */ }
            else { toastMessage = comingSoon }
        } label: {
            buttonRow(systemImage: systemImage, title: title, subtitle: subtitle, tint: tint, enabled: enabled)
        }
        .buttonStyle(.plain)
    }

    private func buttonRow(
        systemImage: String,
        title: String,
        subtitle: String,
        tint: Color,
        enabled: Bool,
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(enabled ? tint : .secondary)
                .frame(width: 44, height: 44)
                .background(enabled ? tint.opacity(0.15) : Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(enabled ? Color.primary : .secondary)
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

    // MARK: - Kill switch

    private var scanIsKillSwitched: Bool {
        entitlements.flagBool(forKey: "disable_scan_parse") ?? false
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
