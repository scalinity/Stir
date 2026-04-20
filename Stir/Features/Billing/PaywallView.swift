// PaywallView
//
// Full-sheet paywall presented from a paywall trigger. Primary CTA is the
// 7-day trial annual (`stir.premium.annual.trial7`); monthly is secondary;
// Pro is a tertiary "Compare plans" modal.
//
// Apple requirements satisfied:
//   - Trial terms visible BEFORE Subscribe CTA (auto-renew, billing date,
//     cancel path)
//   - Restore Purchases always visible
//   - ToS + Privacy Policy linked
//   - Close button allows dismiss without purchase
//
// CLAUDE.md §"billing model": primary paywall CTA is always the annual
// trial. Do not reorder without regenerating cohort-economics analysis.
//
// Visual tokens:
//   - Every hex / font / spacing / radius resolved through
//     `Color.Stir.*`, `Font.Stir.*` via `.stirFont(...)`, `CGFloat.Stir.*`.
//   - Primary CTA is ink900 (warm near-black), NOT ember — per design
//     mockup `stir-app-design/project/DesignMockups/16_paywall.html`
//     `PaywallSolve` + `PaywallScan`. This is a scoped paywall override
//     of Design-System §8.1 "PrimaryButton = ember.600"; see §3.3 color
//     rules for the rationale (paywall uses editorial tonality vs in-flow
//     action). Ember stays on secondary interactive elements via
//     NavigationStack-level `.tint(Color.Stir.ember600)`.
//
// Mockup-to-SwiftUI translation gaps documented inline with
// `// GAP:` comments where a CSS/React idiom has no direct SwiftUI
// equivalent.

import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PaywallViewModel

    @State private var showProComparison = false
    @State private var restoreToast: StirToastPayload?
    @State private var successIconBounce = false

    /// Feature-row icon column width scales with Dynamic Type so the
    /// icons don't crowd the text at AX sizes.
    @ScaledMetric(relativeTo: .callout) private var featureIconWidth: CGFloat = 24

    var body: some View {
        NavigationStack {
            contentView
                .tint(Color.Stir.ember600) // Preserve ember on secondary
                                           // interactive surfaces (links,
                                           // nav-bar items, .bordered
                                           // button accents). The ink900
                                           // primary CTA overrides inline.
                .background(Color.Stir.backgroundPrimary)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image.Stir.close
                                .foregroundStyle(Color.Stir.textTertiary)
                        }
                        .accessibilityLabel("Close")
                    }
                }
                .sheet(isPresented: $showProComparison) {
                    ProComparisonSheet(viewModel: viewModel)
                }
                .stirToast($restoreToast)
                .task {
                    if case .idle = viewModel.state {
                        await viewModel.load()
                    }
                }
                .onChange(of: viewModel.state) { _, newState in
                    if case .succeeded = newState {
                        handleSuccess()
                    }
                }
        }
    }

    /// Animate the success icon with a bounce, wait for the animation to
    /// settle, then dismiss. Duration matches `.symbolEffect(.bounce)`
    /// animation length (~750ms) + a short pause. Replaces the previous
    /// hardcoded `Task.sleep(600ms)` which ran regardless of whether the
    /// user's eye could actually register the success state.
    private func handleSuccess() {
        withAnimation(.spring(duration: 0.4)) {
            successIconBounce = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_100_000_000)  // 1.1s: bounce + breathing room
            dismiss()
        }
    }

    // MARK: - Content by state

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.state {
        case .idle, .loading:
            loadingContent
        case .displaying(let offerings):
            ScrollView {
                displayingContent(offerings: offerings)
            }
        case .purchasing(let productID):
            // Show the real offerings (from the VM cache) with only the
            // in-flight button disabled. Previous version passed empty
            // offerings here, which made every button visibly collapse
            // to "unavailable" during purchase — jarring.
            ScrollView {
                displayingContent(
                    offerings: viewModel.currentOfferings() ?? PaywallOfferings(packages: []),
                    disablePurchaseFor: productID,
                )
            }
        case .succeeded:
            successContent
        case .purchasePending(let productID):
            pendingContent(productID: productID)
        case .purchaseFailed(let productID, let error):
            purchaseFailedContent(productID: productID, error: error)
        case .failedToLoad(let error):
            loadFailureContent(error: error)
        }
    }

    private var loadingContent: some View {
        VStack(spacing: CGFloat.Stir.space4) {
            ProgressView()
            Text("Loading plans…")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayingContent(
        offerings: PaywallOfferings,
        disablePurchaseFor: String? = nil,
    ) -> some View {
        VStack(spacing: CGFloat.Stir.space5) {
            heroHeader
            featuresList
            primaryCTA(offerings: offerings, disablePurchaseFor: disablePurchaseFor)
            secondaryCTA(offerings: offerings, disablePurchaseFor: disablePurchaseFor)
            trialDisclosureView(package: offerings.primaryTrialPackage)
            compareAndRestoreRow
            legalLinks
        }
        .padding(.horizontal, CGFloat.Stir.space5)
        .padding(.vertical, CGFloat.Stir.space6)
    }

    // MARK: - Sections

    private var heroHeader: some View {
        // Mockup `16_paywall.html` replaces the generic crown hero with
        // the system's `sparkles` upsell mark — same SF Symbol the Design
        // System §6 pins for "Premium upsell". Ember-tinted, not yellow.
        VStack(spacing: CGFloat.Stir.space2 + 2) { // 10pt — between space2/space3
            Image.Stir.sparkles
                .font(.system(size: CGFloat.Stir.iconXl))
                .foregroundStyle(Color.Stir.ember600)
                .padding(.bottom, CGFloat.Stir.space1)
                // Decorative — the headline carries semantic meaning for
                // screen readers. Without this, VoiceOver reads "sparkles"
                // before the actual value prop.
                .accessibilityHidden(true)
            Text(viewModel.trigger.headline)
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.textPrimary)
                .multilineTextAlignment(.center)
            Text(viewModel.trigger.subheadline)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            // Step-5 copy says "Hands-free voice cooking (coming soon)" — voice
            // UI lands step 6. Update this copy when voice ships.
            featureRow(icon: Image(systemName: "waveform"), title: "Hands-free voice cooking", subtitle: "Coming soon")
            featureRow(icon: Image.Stir.cook, title: "40 Dinner Solves / month")
            featureRow(icon: Image.Stir.pro, title: "Unlimited Saved Favorites")
            featureRow(icon: Image(systemName: "square.grid.2x2.fill"), title: "Widgets + Shortcuts")
            featureRow(icon: Image(systemName: "leaf.fill"), title: "Leftovers mode")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(icon: Image, title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            icon
                .frame(width: featureIconWidth)
                .foregroundStyle(Color.Stir.ember600)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func primaryCTA(offerings: PaywallOfferings, disablePurchaseFor: String?) -> some View {
        // Primary CTA uses ink900 (warm near-black) per mockup, NOT ember.
        // The CTA label uses paper50 so contrast inverts correctly across
        // light/dark:
        //   - Light mode: bg=ink900 (dark), label=paper50 (warm off-white)
        //   - Dark mode:  bg=ink900 (warm off-white), label=paper50 (dark)
        // Both tokens flip per trait, so the CTA always reads high-contrast.
        // The mockup uses `color:c.bg` on `background:c.ink900` for the
        // same reason.
        let package = offerings.primaryTrialPackage
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            VStack(spacing: CGFloat.Stir.space1) {
                Text("Start 7-day free trial")
                    .stirFont(.labelLg)
                if let package {
                    Text("then \(package.displayPrice)/\(package.periodDescription)")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.paper50.opacity(0.85))
                } else {
                    Text("unavailable — check back later")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.paper50.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CGFloat.Stir.controlVerticalPadding)
            .background(Color.Stir.ink900)
            .foregroundStyle(Color.Stir.paper50)
            .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd))
        }
        .disabled(package == nil || disablePurchaseFor == package?.productID)
        .overlay(alignment: .center) {
            if case .purchasing(let id) = viewModel.state, id == package?.productID {
                ProgressView().tint(Color.Stir.paper50)
            }
        }
    }

    private func secondaryCTA(offerings: PaywallOfferings, disablePurchaseFor: String?) -> some View {
        // Secondary CTA style follows the mockup's "subtle outlined" idiom:
        // paper100 fill + ink100 hairline border + ink900 label. Cannot use
        // `.buttonStyle(.bordered)` cleanly because that style picks up the
        // NavigationStack `.tint` and renders an ember-tinted fill, which
        // fights the paywall's ink900 primary CTA.
        // GAP: mockup uses a 1.5pt border on some surfaces; SwiftUI
        // `RoundedRectangle.stroke(lineWidth:)` is pixel-ideal here, so
        // 1pt reads identically.
        let package = offerings.premiumMonthlyPackage
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            Text(package.map { "Premium monthly — \($0.displayPrice)/mo" } ?? "Premium monthly — unavailable")
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, CGFloat.Stir.controlVerticalPaddingSecondary)
                .background(Color.Stir.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd)
                        .stroke(Color.Stir.divider, lineWidth: 1),
                )
        }
        .disabled(package == nil || disablePurchaseFor == package?.productID)
        .buttonStyle(.plain)
    }

    private func trialDisclosureView(package: PaywallPackage?) -> some View {
        // Apple requirement: auto-renew disclosure visible before subscribe.
        VStack(alignment: .leading, spacing: 6) { // 6pt: sub-scale, between space1/space2 — deliberate tight label→body pairing
            // Heading uses `labelEyebrow` (uppercase, tracked) to match
            // the mockup's section-label tonality.
            Text("Trial terms")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.textTertiary)
            Group {
                if let package {
                    Text(
                        "7 days free, then \(package.displayPrice) billed annually. Renews automatically until canceled. Cancel anytime in Settings > Apple ID > Subscriptions. Trial auto-converts on day 8."
                    )
                } else {
                    Text(
                        "7 days free, then Premium annual rate. Renews automatically until canceled."
                    )
                }
            }
            .stirFont(.bodySm)
            .foregroundStyle(Color.Stir.textTertiary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compareAndRestoreRow: some View {
        HStack {
            Button("Compare plans") { showProComparison = true }
                .stirFont(.labelMd)
            Spacer()
            Button("Restore purchases") {
                Task { await handleRestoreTap() }
            }
            .stirFont(.labelMd)
        }
    }

    private func handleRestoreTap() async {
        let outcome = await viewModel.restore(origin: .paywall)
        let payload: StirToastPayload
        switch outcome {
        case .restored:
            payload = StirToastPayload(id: UUID(), message: "Restored. Welcome back.", kind: .success)
        case .nothingToRestore:
            payload = StirToastPayload(id: UUID(), message: "No active purchase to restore.", kind: .info)
        case .failed(let err):
            payload = StirToastPayload(id: UUID(), message: "Couldn't restore: \(err.userFacingMessage)", kind: .failed)
        }
        let myID = payload.id
        restoreToast = payload
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // Race guard: only dismiss if this task's toast is still presented.
        if restoreToast?.id == myID {
            restoreToast = nil
        }
    }

    private var legalLinks: some View {
        // Apple requirement: ToS + Privacy Policy must be reachable from
        // the paywall before subscribe. Placeholder URLs; hosted pages
        // land before beta (step 9).
        HStack(spacing: CGFloat.Stir.space4) {
            Link("Terms of Service", destination: URL(string: "https://stir.app/terms")!)
            Link("Privacy Policy", destination: URL(string: "https://stir.app/privacy")!)
        }
        .stirFont(.bodySm)
        .foregroundStyle(Color.Stir.textTertiary)
    }

    private var successContent: some View {
        VStack(spacing: CGFloat.Stir.space4) {
            Image.Stir.success
                .font(.system(size: 56)) // Hero success icon — spec §6
                                          // icon.xl is 44; this is the
                                          // paywall's single exception,
                                          // rendering the confirmation
                                          // as a larger celebration.
                .foregroundStyle(Color.Stir.sage600)
                .symbolEffect(.bounce, value: successIconBounce)
                .accessibilityHidden(true)
            Text("You're all set")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.textPrimary)
            Text("Welcome to Premium.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
        }
        .padding(.horizontal, CGFloat.Stir.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pendingContent(productID: String) -> some View {
        VStack(spacing: CGFloat.Stir.space4) {
            ProgressView()
            Text("Purchase pending approval")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
            Text(
                "Your purchase is waiting for approval. You'll unlock Premium once it's approved. You can close this screen; Stir will catch up automatically."
            )
            .stirFont(.bodyMd)
            .foregroundStyle(Color.Stir.textTertiary)
            .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .stirFont(.labelLg)
                .padding(.top, CGFloat.Stir.space2)
        }
        .padding(CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func purchaseFailedContent(productID: String, error: PayError) -> some View {
        VStack(spacing: CGFloat.Stir.space4) {
            Image.Stir.softError
                // Soft error SF Symbol (non-fill), colored `rust.600`
                // per Design-System §3.1 (soft recoverable AI/store failure).
                .font(.system(size: CGFloat.Stir.iconXl - 4)) // 40pt — matches mockup error illustration scale
                .foregroundStyle(Color.Stir.rust600)
            // PAY-01 copy from spec §6.
            Text("Purchase didn't go through. You weren't charged.")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
                .multilineTextAlignment(.center)
            Text(error.userFacingMessage)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: CGFloat.Stir.space3) {
                Button("Try Again") {
                    Task { await viewModel.purchase(productID: productID) }
                }
                .buttonStyle(.borderedProminent) // Inherits NavigationStack
                                                  // .tint ember600 for the
                                                  // filled action.
                Button("Choose Another Plan") { viewModel.dismissError() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFailureContent(error: PayError) -> some View {
        VStack(spacing: CGFloat.Stir.space4) {
            Image.Stir.networkOff
                // NET-01 icon — wifi.slash.
                .font(.system(size: CGFloat.Stir.iconXl - 4))
                .foregroundStyle(Color.Stir.rust600)
            Text("We couldn't reach the store right now.")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
                .multilineTextAlignment(.center)
            Text(error.userFacingMessage)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PayError → user copy
//
// (The `RestoreToast` + `RestoreToastView` types that used to live here
// were replaced by the shared `StirToast` component in `Stir/App/Views/
// StirToast.swift` during the step-5 review follow-up. Settings uses the
// same component, so a single capsule style lives in one place now.)

extension PayError {
    var userFacingMessage: String {
        switch self {
        case .networkUnreachable:
            return "Check your connection and try again."
        case .productNotAvailable:
            return "This plan isn't available right now. Try again shortly."
        case .paymentInvalid:
            return "Your payment method isn't valid. Update it in Settings > Apple ID."
        case .paymentNotAllowed:
            return "Purchases aren't allowed on this device."
        case .storeProblem:
            return "The App Store had a problem with this purchase."
        case .generic(let description):
            return description
        }
    }
}
