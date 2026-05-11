// PaywallView
//
// Full-sheet paywall. All four SKUs render inline so the user picks tier
// + period on a single surface: Pro Annual (primary, 7-day trial, ink900),
// Pro Monthly, Premium Annual, Premium Monthly. The trial lives on Pro
// Annual (SCA-294). ProComparisonSheet is no longer reachable from this
// surface — Settings keeps its own direct entry point for the feature
// comparison.
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

    /// Whether to render trial-flavored copy ("Start 7-day free trial",
    /// "Trial terms", "7 days free, then...") for a primary-trial package.
    ///
    /// SCA-287 + SCA-294: must be exhaustive on `IntroEligibility`. The
    /// trial copy only fits when RC reports the package as `.eligible` or
    /// `.unknown` (per RC convention, treat unknown as eligible — Apple is
    /// the final arbiter). `.ineligible` AND `.noOffer` both fall through
    /// to the auto-renew-only "Subscribe annually" copy:
    ///   - `.ineligible`: this Apple ID already consumed the trial.
    ///   - `.noOffer`: the trial-bearing SKU on the dashboard side doesn't
    ///     carry an intro offer (e.g. ASC dashboard drift, RC cache stale
    ///     post-SCA-294, future SKU swap without iOS update). Showing
    ///     "Start 7-day free trial" / "then $139.99/year" while Apple
    ///     charges full price immediately is the exact UX failure SCA-287
    ///     was meant to prevent — exhaustive matching makes that
    ///     impossible to regress past.
    ///
    /// Pure / `static` so PaywallViewTrialCopyTests can exercise all four
    /// IntroEligibility cases without instantiating SwiftUI.
    static func shouldShowTrialCopy(for eligibility: IntroEligibility?) -> Bool {
        switch eligibility ?? .unknown {
        case .eligible, .unknown: return true
        case .ineligible, .noOffer: return false
        }
    }

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
        case .succeeded(let productID):
            successContent(productID: productID)
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
            proMonthlyCTA(offerings: offerings, disablePurchaseFor: disablePurchaseFor)
            premiumPlansSection(offerings: offerings, disablePurchaseFor: disablePurchaseFor)
            trialDisclosureView(package: offerings.primaryTrialPackage)
            restoreRow
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
        // SCA-294: trial unlocks Pro for 7 days, so the feature list
        // anchors Pro's caps and Pro-exclusive features (multi-image scan).
        // ADR 0015 copy spec (amended by SCA-294 — original spec anchored
        // Premium caps on the primary paywall) — frequency framing ("every
        // dinner" vs "27 sessions/month") reads as benefit not rationing,
        // and ages well if the cap shifts. Voice + multi-image lead as
        // the durable Pro differentiators.
        //
        // iPhone SE (4.7") truncation watch: "Hands-free voice for every
        // dinner" is the longest string in this list (well within iPhone
        // SE's single-line budget at default Dynamic Type). If a future
        // copy variant exceeds, promote a single Pro line to a section
        // header above the bullet list as the fallback pattern.
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            featureRow(icon: Image.Stir.voiceWave, title: "Hands-free voice for every dinner")
            featureRow(icon: Image.Stir.cook, title: "120 Dinner Solves per month")
            featureRow(icon: Image.Stir.pro, title: "Multi-image pantry scan")
            featureRow(icon: Image.Stir.widgetFill, title: "Widgets + Shortcuts")
            featureRow(icon: Image.Stir.leaf, title: "Leftovers + unlimited favorites")
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
        let isTrialEligible = Self.shouldShowTrialCopy(for: package?.introEligibility)
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            VStack(spacing: CGFloat.Stir.space1) {
                Text(isTrialEligible ? "Start 7-day free trial" : "Subscribe annually")
                    .stirFont(.labelLg)
                // Subtitle uses `paper50` at 85% alpha on the solid `ink900`
                // background for visual hierarchy inside the CTA. Spec §3.3
                // "no transparency on text" targets opacity-over-photos (which
                // reveals the photo through glyphs); on a flat opaque surface
                // the rationale doesn't apply, and the inverse ink/paper
                // scale offers no 85%-equivalent step to use instead.
                if let package {
                    Text(
                        isTrialEligible
                            ? "then \(package.displayPrice)/\(package.periodDescription)"
                            : "\(package.displayPrice)/\(package.periodDescription)"
                    )
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

    private func proMonthlyCTA(offerings: PaywallOfferings, disablePurchaseFor: String?) -> some View {
        // `.buttonStyle(.bordered)` would inherit the NavigationStack ember
        // tint and fight the ink primary CTA, so this composes the outline
        // explicitly.
        //
        // SCA-294: Pro monthly sits directly under the trial CTA — same Pro
        // tier, no trial, for users who want monthly cadence. Premium
        // plans live in `premiumPlansSection` below.
        let package = offerings.proMonthlyPackage
        let isDisabled = package == nil || disablePurchaseFor == package?.productID
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            Text(package.map { "Pro monthly — \($0.displayPrice)/mo" } ?? "Pro monthly — unavailable")
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

    // MARK: - Premium plans (de-emphasized)

    /// Premium plans section: an eyebrow divider plus two compact rows
    /// (Annual + Monthly). Visually de-emphasized so the user clocks
    /// "alternative tier" rather than "equal choice". No trial messaging
    /// — neither Premium SKU carries one (SCA-294 moved the trial to Pro
    /// Annual). Apple's "one trial per Apple ID per subscription group"
    /// rule means a user who already burned the Pro trial would only see
    /// the Premium rows here as the trial-less alternative.
    @ViewBuilder
    private func premiumPlansSection(
        offerings: PaywallOfferings,
        disablePurchaseFor: String?,
    ) -> some View {
        if offerings.premiumAnnualPackage != nil || offerings.premiumMonthlyPackage != nil {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                HStack(spacing: CGFloat.Stir.space2) {
                    Text("Or choose Premium")
                        .stirFont(.labelEyebrow)
                        .foregroundStyle(Color.Stir.textTertiary)
                    Rectangle()
                        .fill(Color.Stir.divider)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
                VStack(spacing: CGFloat.Stir.space2) {
                    premiumPlanRow(
                        package: offerings.premiumAnnualPackage,
                        title: "Premium annual",
                        priceSuffix: "/yr",
                        unavailableLabel: "Premium annual — unavailable",
                        disablePurchaseFor: disablePurchaseFor,
                    )
                    premiumPlanRow(
                        package: offerings.premiumMonthlyPackage,
                        title: "Premium monthly",
                        priceSuffix: "/mo",
                        unavailableLabel: "Premium monthly — unavailable",
                        disablePurchaseFor: disablePurchaseFor,
                    )
                }
            }
        }
    }

    private func premiumPlanRow(
        package: PaywallPackage?,
        title: String,
        priceSuffix: String,
        unavailableLabel: String,
        disablePurchaseFor: String?,
    ) -> some View {
        let isDisabled = package == nil || disablePurchaseFor == package?.productID
        return Button {
            if let package { Task { await viewModel.purchase(productID: package.productID) } }
        } label: {
            HStack(spacing: CGFloat.Stir.space2) {
                Text(title)
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.textPrimary)
                Spacer(minLength: CGFloat.Stir.space2)
                if let package {
                    Text("\(package.displayPrice)\(priceSuffix)")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.textTertiary)
                } else {
                    Text(unavailableLabel)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CGFloat.Stir.space3)
            .padding(.vertical, CGFloat.Stir.controlVerticalPaddingSecondary - 2)
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
        .overlay(alignment: .trailing) {
            if case .purchasing(let id) = viewModel.state, id == package?.productID {
                ProgressView()
                    .tint(Color.Stir.textPrimary)
                    .padding(.trailing, CGFloat.Stir.space3)
            }
        }
        .accessibilityLabel(
            package.map { "\(title), \($0.displayPrice)\(priceSuffix)" } ?? unavailableLabel,
        )
    }

    private func trialDisclosureView(package: PaywallPackage?) -> some View {
        // Apple requirement: auto-renew disclosure visible before subscribe.
        // 6pt = off-scale tight eyebrow↔body pairing (space2=8pt visually
        // detaches the uppercase label from its body copy; space1=4pt is
        // too tight against the eyebrow's baked line height).
        //
        let isTrialEligible = Self.shouldShowTrialCopy(for: package?.introEligibility)
        return VStack(alignment: .leading, spacing: CGFloat.Stir.space2 - 2) {
            Text(isTrialEligible ? "Trial terms" : "Subscription terms")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.textTertiary)
            Group {
                if let package {
                    if isTrialEligible {
                        Text(
                            "7 days free, then \(package.displayPrice) billed annually. Renews automatically until canceled. Cancel anytime in Settings > Apple ID > Subscriptions. Trial auto-converts on day 8."
                        )
                    } else {
                        Text(
                            "\(package.displayPrice) billed annually. Renews automatically until canceled. Cancel anytime in Settings > Apple ID > Subscriptions."
                        )
                    }
                } else {
                    Text(
                        "7 days free, then Pro annual rate. Renews automatically until canceled."
                    )
                }
            }
            .stirFont(.bodySm)
            .foregroundStyle(Color.Stir.textTertiary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var restoreRow: some View {
        HStack {
            Spacer()
            Button("Restore purchases") {
                Task { await handleRestoreTap() }
            }
            .stirFont(.labelMd)
            Spacer()
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

    private func successContent(productID: String) -> some View {
        // SCA-294 follow-up: the trial buys Pro now, but the user can also
        // pick Premium directly from the same paywall. Map the purchased
        // SKU back through `StirProduct` so the welcome copy names the
        // tier they actually bought — "Welcome to Premium" after a Pro
        // purchase (or vice versa) reads as a billing bug, not chrome.
        let tier: Tier = StirProduct(rawValue: productID)?.tier ?? .pro
        let welcomeCopy = tier == .pro ? "Welcome to Stir Pro." : "Welcome to Stir Premium."
        return VStack(spacing: CGFloat.Stir.space4) {
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
            Text(welcomeCopy)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
        }
        .padding(.horizontal, CGFloat.Stir.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pendingContent(productID: String) -> some View {
        // SCA-294 follow-up: pending copy names the tier the user actually
        // bought (Ask-to-Buy can resolve days later, so the message has to
        // age correctly when re-read in a notification or background-fetch
        // toast). Default to "Pro" because the primary CTA buys Pro; any
        // Premium-row tap routes through here too.
        let tier: Tier = StirProduct(rawValue: productID)?.tier ?? .pro
        let tierWord = tier == .pro ? "Pro" : "Premium"
        return VStack(spacing: CGFloat.Stir.space4) {
            ProgressView()
                .tint(Color.Stir.ember600)
            Text("Purchase pending approval")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Your purchase is waiting for approval. You'll unlock \(tierWord) once it's approved. You can close this screen; Stir will catch up automatically."
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
