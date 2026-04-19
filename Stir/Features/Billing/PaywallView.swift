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
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.secondary)
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
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading plans…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func displayingContent(
        offerings: PaywallOfferings,
        disablePurchaseFor: String? = nil,
    ) -> some View {
        VStack(spacing: 24) {
            heroHeader
            featuresList
            primaryCTA(offerings: offerings, disablePurchaseFor: disablePurchaseFor)
            secondaryCTA(offerings: offerings, disablePurchaseFor: disablePurchaseFor)
            trialDisclosureView(package: offerings.primaryTrialPackage)
            compareAndRestoreRow
            legalLinks
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    // MARK: - Sections

    private var heroHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)
                .padding(.bottom, 4)
                // Decorative — the headline carries semantic meaning for
                // screen readers. Without this, VoiceOver reads "crown"
                // before the actual value prop.
                .accessibilityHidden(true)
            Text(viewModel.trigger.headline)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(viewModel.trigger.subheadline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Step-5 copy says "Hands-free voice cooking (coming soon)" — voice
            // UI lands step 6. Update this copy when voice ships.
            featureRow(icon: "waveform", title: "Hands-free voice cooking", subtitle: "Coming soon")
            featureRow(icon: "fork.knife", title: "40 Dinner Solves / month")
            featureRow(icon: "star.fill", title: "Unlimited Saved Favorites")
            featureRow(icon: "square.grid.2x2.fill", title: "Widgets + Shortcuts")
            featureRow(icon: "leaf.fill", title: "Leftovers mode")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(icon: String, title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: featureIconWidth)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func primaryCTA(offerings: PaywallOfferings, disablePurchaseFor: String?) -> some View {
        let package = offerings.primaryTrialPackage
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            VStack(spacing: 4) {
                Text("Start 7-day free trial")
                    .font(.headline)
                if let package {
                    Text("then \(package.displayPrice)/\(package.periodDescription)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Text("unavailable — check back later")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.tint)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(package == nil || disablePurchaseFor == package?.productID)
        .overlay(alignment: .center) {
            if case .purchasing(let id) = viewModel.state, id == package?.productID {
                ProgressView().tint(.white)
            }
        }
    }

    private func secondaryCTA(offerings: PaywallOfferings, disablePurchaseFor: String?) -> some View {
        let package = offerings.premiumMonthlyPackage
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            Text(package.map { "Premium monthly — \($0.displayPrice)/mo" } ?? "Premium monthly — unavailable")
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .disabled(package == nil || disablePurchaseFor == package?.productID)
        .buttonStyle(.bordered)
    }

    private func trialDisclosureView(package: PaywallPackage?) -> some View {
        // Apple requirement: auto-renew disclosure visible before subscribe.
        VStack(alignment: .leading, spacing: 6) {
            // Heading uses primary + semibold so it reads as a section
            // label rather than getting muted into the legalese body.
            Text("Trial terms")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compareAndRestoreRow: some View {
        HStack {
            Button("Compare plans") { showProComparison = true }
                .font(.footnote)
            Spacer()
            Button("Restore purchases") {
                Task { await handleRestoreTap() }
            }
            .font(.footnote)
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
        HStack(spacing: 16) {
            Link("Terms of Service", destination: URL(string: "https://stir.app/terms")!)
            Link("Privacy Policy", destination: URL(string: "https://stir.app/privacy")!)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var successContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: successIconBounce)
                .accessibilityHidden(true)
            Text("You're all set")
                .font(.title2.bold())
            Text("Welcome to Premium.")
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pendingContent(productID: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Purchase pending approval")
                .font(.headline)
            Text(
                "Your purchase is waiting for approval. You'll unlock Premium once it's approved. You can close this screen; Stir will catch up automatically."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Button("Close") { dismiss() }.padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func purchaseFailedContent(productID: String, error: PayError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            // PAY-01 copy from spec §6.
            Text("Purchase didn't go through. You weren't charged.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(error.userFacingMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try Again") {
                    Task { await viewModel.purchase(productID: productID) }
                }
                .buttonStyle(.borderedProminent)
                Button("Choose Another Plan") { viewModel.dismissError() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFailureContent(error: PayError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("We couldn't reach the store right now.")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(error.userFacingMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await viewModel.load() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
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
