// PaywallView
//
// Full-sheet paywall. Primary CTA = 7-day trial annual
// (`stir.premium.annual.trial7`); monthly Premium is secondary; Pro lives
// in a "Compare plans" sheet.
//
// Apple surface requirements: trial terms visible before Subscribe, Restore
// Purchases visible, ToS + Privacy linked, close button present.
//
// Primary CTA uses ink900 instead of the ember600 default from
// Design-System §8.1. This is a scoped paywall override (editorial
// tonality). Ember stays on secondary surfaces via the NavigationStack
// `.tint(Color.Stir.ember600)` at the top.

import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: PaywallViewModel

    @State private var showProComparison = false
    @State private var restoreToast: StirToastPayload?
    @State private var successIconBounce = false

    @ScaledMetric(relativeTo: .callout) private var featureIconWidth: CGFloat = 24

    /// 1.1s covers the `.bounce` symbol effect (~750ms) plus a short
    /// breathing pause before dismiss.
    private static let successDismissDelayNanos: UInt64 = 1_100_000_000
    /// Toast auto-hide window.
    private static let restoreToastVisibleNanos: UInt64 = 2_500_000_000
    /// Modal-state error icon size (40pt). Between `.iconLg` (28) and
    /// `.iconXl` (44) — renders smaller than the success celebration icon
    /// but larger than inline feature-row icons.
    private static let modalErrorIconSize: CGFloat = 40

    var body: some View {
        NavigationStack {
            contentView
                .tint(Color.Stir.ember600)
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

    private func handleSuccess() {
        // Gate the bounce trigger itself, not just `withAnimation`.
        // `.symbolEffect(.bounce, value: successIconBounce)` (line 356) plays
        // the bounce on every successIconBounce toggle regardless of the
        // surrounding withAnimation — iOS 17 .symbolEffect doesn't honor
        // accessibilityReduceMotion automatically (the disableSymbolEffect
        // / symbolEffectsRemoved APIs ship in iOS 18, and this app deploys
        // iOS 17). Leaving successIconBounce at false when reduceMotion is
        // on is the only way to suppress the bounce on iOS 17.
        // CR2-W1 / CR3-W2 / step-9 review.
        if !reduceMotion {
            withAnimation(.spring(duration: 0.4)) {
                successIconBounce = true
            }
        }
        // Asymmetric with `handleRestoreTap`'s race guard by design: toast
        // presentation can be overridden by a newer tap (so the tap needs a
        // UUID guard to avoid clearing the wrong toast), but `dismiss()` is
        // idempotent — firing it on an already-dismissed sheet is a no-op
        // per SwiftUI, and `.succeeded` is a terminal state the VM never
        // revisits. No guard needed.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.successDismissDelayNanos)
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
            // Keep real offerings rendered so buttons don't visually
            // collapse to "unavailable" while one purchase is in flight.
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
                .tint(Color.Stir.ember600)
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
        VStack(spacing: CGFloat.Stir.space3) {
            Image.Stir.sparkles
                .font(.system(size: CGFloat.Stir.iconXl))
                .foregroundStyle(Color.Stir.ember600)
                .padding(.bottom, CGFloat.Stir.space1)
                // Decorative — the headline carries semantic meaning; without
                // this, VoiceOver reads "sparkles" before the value prop.
                .accessibilityHidden(true)
            Text(viewModel.trigger.headline)
                .stirFont(.displayLg)
                .foregroundStyle(Color.Stir.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(viewModel.trigger.subheadline)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    private var featuresList: some View {
        // Premium feature list — ADR 0015 copy spec. Frequency framing
        // ("~3 dinners a week" vs "13 sessions/month") reads as benefit
        // not rationing, and ages well if the cap ever comes back up.
        // Voice bullet leads because it's the paid-tier differentiator.
        //
        // iPhone SE (4.7") truncation watch: "Hands-free voice for ~3
        // dinners a week" is the longest string in this list. If it
        // wraps awkwardly under Dynamic Type, fall back to "Voice for
        // ~3 dinners a week" (29 chars) and promote "Hands-free voice
        // Cook Mode" to a section header above the bullet list.
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            featureRow(icon: Image.Stir.voiceWave, title: "Hands-free voice for ~3 dinners a week")
            featureRow(icon: Image.Stir.cook, title: "40 Dinner Solves per month")
            featureRow(icon: Image.Stir.pro, title: "Unlimited Saved Favorites")
            featureRow(icon: Image.Stir.widgetFill, title: "Widgets + Shortcuts")
            featureRow(icon: Image.Stir.leaf, title: "Leftovers mode")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func featureRow(icon: Image, title: String, subtitle: String? = nil) -> some View {
        HStack(alignment: .top, spacing: CGFloat.Stir.space3) {
            icon
                .frame(width: featureIconWidth)
                .foregroundStyle(Color.Stir.ember600)
            // 2pt = off-scale tight pairing for title↔subtitle adjacency
            // (4pt would visually disconnect them inside a leading-icon row).
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1 / 2) {
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
        let package = offerings.primaryTrialPackage
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            VStack(spacing: CGFloat.Stir.space1) {
                Text("Start 7-day free trial")
                    .stirFont(.labelLg)
                // Subtitle uses `paper50` at 85% alpha on the solid `ink900`
                // background for visual hierarchy inside the CTA. Spec §3.3
                // "no transparency on text" targets opacity-over-photos (which
                // reveals the photo through glyphs); on a flat opaque surface
                // the rationale doesn't apply, and the inverse ink/paper
                // scale offers no 85%-equivalent step to use instead.
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
            .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusCard))
        }
        .disabled(package == nil || disablePurchaseFor == package?.productID)
        .overlay(alignment: .center) {
            if case .purchasing(let id) = viewModel.state, id == package?.productID {
                ProgressView().tint(Color.Stir.paper50)
            }
        }
    }

    private func secondaryCTA(offerings: PaywallOfferings, disablePurchaseFor: String?) -> some View {
        // `.buttonStyle(.bordered)` would inherit the NavigationStack ember
        // tint and fight the ink primary CTA, so this composes the outline
        // explicitly.
        let package = offerings.premiumMonthlyPackage
        let isDisabled = package == nil || disablePurchaseFor == package?.productID
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
                .opacity(isDisabled ? 0.5 : 1)
        }
        .disabled(isDisabled)
        .buttonStyle(.plain)
        .overlay(alignment: .center) {
            if case .purchasing(let id) = viewModel.state, id == package?.productID {
                ProgressView().tint(Color.Stir.textPrimary)
            }
        }
    }

    private func trialDisclosureView(package: PaywallPackage?) -> some View {
        // Apple requirement: auto-renew disclosure visible before subscribe.
        // 6pt = off-scale tight eyebrow↔body pairing (space2=8pt visually
        // detaches the uppercase label from its body copy; space1=4pt is
        // too tight against the eyebrow's baked line height).
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2 - 2) {
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
        try? await Task.sleep(nanoseconds: Self.restoreToastVisibleNanos)
        // Race guard: only dismiss this task's toast, not a newer one.
        if restoreToast?.id == myID {
            restoreToast = nil
        }
    }

    private var legalLinks: some View {
        // Three small-text links at the bottom of the paywall — Apple's
        // App Store guidelines require both Terms (or EULA) and Privacy
        // Policy disclosures before subscription confirmation. Stir's ToS
        // covers app usage; the EULA points at Apple's standard licensed-
        // application terms (no custom EULA today, so the standard URL
        // is the right link per Apple's App Store Connect guidance).
        HStack(spacing: CGFloat.Stir.space2) {
            Link("Terms", destination: URL(string: "https://getstir.app/terms")!)
            Text("·").foregroundStyle(Color.Stir.textTertiary).accessibilityHidden(true)
            Link("EULA", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            Text("·").foregroundStyle(Color.Stir.textTertiary).accessibilityHidden(true)
            Link("Privacy", destination: URL(string: "https://getstir.app/privacy")!)
        }
        .stirFont(.bodySm)
        .foregroundStyle(Color.Stir.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var successContent: some View {
        VStack(spacing: CGFloat.Stir.space4) {
            // Paywall success icon is the single exception to §6 icon.xl
            // (44pt) — 56pt reads as a celebration rather than chrome.
            Image.Stir.success
                .font(.system(size: CGFloat.Stir.iconXl + 12))
                .foregroundStyle(Color.Stir.sage600)
                .symbolEffect(.bounce, value: successIconBounce)
                .accessibilityHidden(true)
            Text("You're all set")
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.textPrimary)
                .accessibilityAddTraits(.isHeader)
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
                .tint(Color.Stir.ember600)
            Text("Purchase pending approval")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
                .accessibilityAddTraits(.isHeader)
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
                .font(.system(size: Self.modalErrorIconSize))
                .foregroundStyle(Color.Stir.rust600)
                // Decorative — the headline carries the PAY-01 semantic.
                .accessibilityHidden(true)
            // PAY-01 copy from spec §6.
            Text("Purchase didn't go through. You weren't charged.")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(error.userFacingMessage)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
            HStack(spacing: CGFloat.Stir.space3) {
                PrimaryButton(title: "Try Again") {
                    Task { await viewModel.purchase(productID: productID) }
                }
                SecondaryButton(title: "Choose Another Plan") {
                    viewModel.dismissError()
                }
            }
        }
        .padding(CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFailureContent(error: PayError) -> some View {
        VStack(spacing: CGFloat.Stir.space4) {
            Image.Stir.networkOff
                .font(.system(size: Self.modalErrorIconSize))
                .foregroundStyle(Color.Stir.rust600)
                // Decorative — the headline carries the network-failure semantic.
                .accessibilityHidden(true)
            Text("We couldn't reach the store right now.")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(error.userFacingMessage)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
            PrimaryButton(title: "Retry") {
                Task { await viewModel.load() }
            }
        }
        .padding(CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PayError → user copy

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
        case .timeout:
            return "Couldn't load plans in time. Try again."
        }
    }
}
