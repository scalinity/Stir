// ProComparisonSheet
//
// Compare-plans modal launched from Settings (SCA-382). Side-by-side
// Premium vs Pro feature matrix so power users can self-evaluate the
// tiers. Both tiers are purchasable inline (SCA-384 added the Premium
// half — previously the sheet only sold Pro and forced Premium-leaning
// users to back out and use PaywallView's "Or choose Premium" section).
// Visual tokens resolve through Color.Stir / Font.Stir / CGFloat.Stir
// — zero raw hex, font, or spacing literals.

import SwiftUI

struct ProComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PaywallViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CGFloat.Stir.space5) {
                    header
                    comparisonTable
                    proCTAs
                    proDisclosure
                }
                .padding(.horizontal, CGFloat.Stir.space5)
                .padding(.vertical, CGFloat.Stir.space4)
            }
            .background(Color.Stir.backgroundPrimary)
            .tint(Color.Stir.ember600)
            // Keep `.navigationTitle` for the implicit back-chevron
            // label any deeper pushed screen reads, plus VoiceOver —
            // visible chrome is `.stirTopBar` below.
            .navigationTitle("Compare plans")
            .navigationBarTitleDisplayMode(.inline)
            // SCA-457: custom top bar escapes iOS 26 Liquid Glass.
            .stirTopBar(
                title: "Compare plans",
                trailing: {
                    StirTopBarTextButton("Done") { dismiss() }
                },
            )
        }
    }

    private var header: some View {
        VStack(spacing: CGFloat.Stir.space2) {
            Text("Premium or Pro?")
                .stirFont(.displaySm)
                .foregroundStyle(Color.Stir.textPrimary)
            Text("Premium covers most weeknight cooks. Pro adds more Solves, longer memory, and multi-image scans.")
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
        }
    }

    /// Used for the Pro column's minimum width so the column expands with
    /// Dynamic Type instead of clipping at accessibility sizes.
    @ScaledMetric(relativeTo: .footnote) private var proColumnMinWidth: CGFloat = 48

    private var comparisonTable: some View {
        // Voice row uses frequency framing per ADR 0015 paywall copy spec
        // ("~3/week" vs "Every dinner" — reads as benefit, not rationing,
        // and ages well if the cap ever moves). Other rows stay numeric
        // because they're unit-count features that already read naturally
        // (40 Dinner Solves isn't a rationing framing in the way "13 voice
        // sessions" would be — voice sessions were the only cap users
        // actively feel). Enforcement numbers (13 / 27) live in
        // `_shared/entitlements.ts`; frequency labels here must stay
        // truthful to those numbers — revisit if the cap changes.
        //
        // The voice row passes explicit a11y overrides because VoiceOver
        // on some iOS versions pronounces "~3/week" literally as "tilde
        // three slash week". The spoken form ("about 3 dinners a week")
        // renders cleanly regardless of locale / reader version. Non-
        // voice rows fall back to the default accessibilityLabel which
        // reads the visible strings verbatim — fine for "40" / "120" /
        // "250" / "✓" / "90 days".
        VStack(spacing: 0) {
            // Column header row. Sighted users see which number is Premium
            // vs Pro; VoiceOver hears "Premium column" before the data rows.
            headerRow
            tableDivider
            row(label: "Dinner Solves / month", premium: "40", pro: "120")
            tableDivider
            row(
                label: "Hands-free voice cooking",
                premium: "~3/week",
                pro: "Every dinner",
                premiumA11y: "about 3 dinners a week",
                proA11y: "every dinner",
            )
            tableDivider
            row(label: "Remembered pantry items", premium: "250", pro: "1,000")
            tableDivider
            row(label: "Multi-image scan", premium: "—", pro: "✓")
            tableDivider
            row(label: "Priority inference queue", premium: "—", pro: "✓")
            tableDivider
            row(label: "Household memory", premium: "90 days", pro: "365 days")
        }
        .padding(.vertical, CGFloat.Stir.space1)
        .background(Color.Stir.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd))
    }

    private var tableDivider: some View {
        Rectangle()
            .fill(Color.Stir.divider)
            .frame(height: 1)
    }

    private var headerRow: some View {
        HStack {
            Text("Feature")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.textTertiary)
            Spacer()
            Text("Premium")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.textTertiary)
            Text("Pro")
                .stirFont(.labelEyebrow)
                .foregroundStyle(Color.Stir.ember600)
                .frame(minWidth: proColumnMinWidth, alignment: .trailing)
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space2 + 2) // 10pt — labels sit tight to table border
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Feature, Premium, Pro")
    }

    /// Comparison table row. `premiumA11y` / `proA11y` override the
    /// spoken label for cells where the visible string would read
    /// badly via VoiceOver (e.g. "~3/week" pronounced as "tilde three
    /// slash week"). Pass nil to use the visible string verbatim.
    private func row(
        label: String,
        premium: String,
        pro: String,
        premiumA11y: String? = nil,
        proA11y: String? = nil,
    ) -> some View {
        HStack {
            Text(label)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textPrimary)
            Spacer()
            Text(premium)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textSecondary)
            Text(pro)
                .stirFont(.labelMd)
                .foregroundStyle(Color.Stir.ember600)
                .frame(minWidth: proColumnMinWidth, alignment: .trailing)
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space2 + 2) // 10pt — matches headerRow
        // Combine children so VoiceOver reads each row as a single
        // phrase rather than three disconnected tokens. Previously the
        // screen reader voiced "Dinner Solves per month", silence,
        // "40", silence, "120" — leaving the user to infer which number
        // belongs to which column.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label). Premium: \(premiumA11y ?? premium). Pro: \(proA11y ?? pro).",
        )
    }

    private var proCTAs: some View {
        // Hoist `currentOfferings()` once per body re-eval and branch
        // explicitly on state. The earlier `case .idle, .loading where
        // viewModel.currentOfferings() == nil:` form was correct (Swift
        // applies `where` to the whole case, not just the last pattern)
        // but read ambiguously AND called `currentOfferings()` twice
        // per evaluation. Reader-confidence > terseness here.
        let offerings = viewModel.currentOfferings()
        return VStack(spacing: CGFloat.Stir.space2 + 2) {
            switch viewModel.state {
            case .failedToLoad(let error):
                loadFailureCTA(error: error)
            case .idle, .loading:
                // First-time load → spinner. Retry-after-success keeps
                // the cached offerings visible so the UI doesn't blank
                // during the re-fetch.
                if let offerings {
                    purchaseCTAs(offerings: offerings)
                } else {
                    loadingCTA
                }
            default:
                if let offerings {
                    purchaseCTAs(offerings: offerings)
                } else {
                    // Defensive: state past .loading without cached
                    // offerings — `displaying` implies offerings loaded,
                    // so this only fires on a corrupted state machine.
                    // Treat as load failure for UX rather than blank.
                    loadFailureCTA(error: .generic(description: "Plans unavailable."))
                }
            }
        }
    }

    /// Pro purchase buttons (annual + monthly). Disabled during
    /// `.purchasing` / `.succeeded` / `.purchasePending` so a fast
    /// double-tap can't spawn duplicate purchase Tasks (the VM's
    /// state guard catches the second one, but only AFTER the first
    /// `await` flips state — leaves a tiny window where two tasks
    /// pass through and emit duplicate `purchase_started`).
    @ViewBuilder
    private func purchaseCTAs(offerings: PaywallOfferings) -> some View {
        if let pkg = offerings.proAnnualPackage {
            Button {
                Task { await viewModel.purchase(productID: pkg.productID) }
            } label: {
                VStack(spacing: CGFloat.Stir.space1 / 2) { // 2pt — tight title/price pairing
                    Text("Pro annual")
                        .stirFont(.labelLg)
                    Text("\(pkg.displayPrice) / year")
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.paper50.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, CGFloat.Stir.controlVerticalPadding)
                .background(Color.Stir.ink900)
                .foregroundStyle(Color.Stir.paper50)
                .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd))
            }
            .accessibilityLabel("Upgrade to Pro annual, \(pkg.displayPrice) per year")
            .disabled(isPurchaseInFlight)
        }
        if let pkg = offerings.proMonthlyPackage {
            Button {
                Task { await viewModel.purchase(productID: pkg.productID) }
            } label: {
                Text("Pro monthly — \(pkg.displayPrice)/mo")
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
            .buttonStyle(.plain)
            .accessibilityLabel("Pro monthly, \(pkg.displayPrice) per month")
            .disabled(isPurchaseInFlight)
        }
        // SCA-384: Premium half of the comparison sheet. Mirrors
        // PaywallView.premiumPlansSection grammar (eyebrow divider +
        // compact bordered rows). De-emphasized vs Pro CTAs above so
        // tier hierarchy reads correctly: Pro is the recommended tier,
        // Premium is the price-conscious alternative for users who
        // explicitly want it. `isPurchaseInFlight` is shared with the
        // Pro buttons so a single in-flight purchase greys all four
        // SKUs together.
        premiumCTAs(offerings: offerings)
    }

    /// Premium purchase buttons (annual + monthly). Rendered as a
    /// de-emphasized section below the Pro CTAs with an "Or choose
    /// Premium" eyebrow divider — matches PaywallView's grammar so the
    /// two surfaces stay visually consistent. Section only renders if
    /// at least one Premium SKU is purchasable; individual nil rows
    /// are skipped (partial-availability RC configs surface as one
    /// row instead of one row + one "unavailable" placeholder).
    @ViewBuilder
    private func premiumCTAs(offerings: PaywallOfferings) -> some View {
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
                    if let pkg = offerings.premiumAnnualPackage {
                        premiumPlanButton(
                            package: pkg,
                            title: "Premium annual",
                            priceSuffix: "/yr",
                        )
                    }
                    if let pkg = offerings.premiumMonthlyPackage {
                        premiumPlanButton(
                            package: pkg,
                            title: "Premium monthly",
                            priceSuffix: "/mo",
                        )
                    }
                }
            }
            .padding(.top, CGFloat.Stir.space2)
        }
    }

    /// Single Premium plan row. Compact, bordered, de-emphasized vs
    /// the Pro CTAs above. Disabled during any in-flight purchase
    /// (shared `isPurchaseInFlight` guard with the Pro buttons).
    private func premiumPlanButton(
        package: PaywallPackage,
        title: String,
        priceSuffix: String,
    ) -> some View {
        Button {
            Task { await viewModel.purchase(productID: package.productID) }
        } label: {
            HStack(spacing: CGFloat.Stir.space2) {
                Text(title)
                    .stirFont(.labelMd)
                    .foregroundStyle(Color.Stir.textPrimary)
                Spacer(minLength: CGFloat.Stir.space2)
                Text("\(package.displayPrice)\(priceSuffix)")
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CGFloat.Stir.space3)
            .padding(.vertical, CGFloat.Stir.controlVerticalPaddingSecondary - 2) // -2pt off-scale, matches PaywallView.premiumPlanRow
            .background(Color.Stir.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd)
                    .stroke(Color.Stir.divider, lineWidth: 1),
            )
            .opacity(isPurchaseInFlight ? 0.5 : 1)
        }
        .disabled(isPurchaseInFlight)
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(package.displayPrice)\(priceSuffix)")
    }

    /// True while a purchase is in flight or has reached a terminal state
    /// the user shouldn't be able to re-tap from. `purchaseFailed` stays
    /// enabled so the user can retry the same SKU; that path runs
    /// through `purchase(productID:)`'s explicit `.purchaseFailed` arm.
    private var isPurchaseInFlight: Bool {
        switch viewModel.state {
        case .purchasing, .succeeded, .purchasePending:
            return true
        default:
            return false
        }
    }

    /// Spinner shown during the initial offerings load (state .idle / .loading).
    private var loadingCTA: some View {
        ProgressView()
            .tint(Color.Stir.ember600)
            .frame(maxWidth: .infinity)
            .padding(.vertical, CGFloat.Stir.space4)
            .accessibilityLabel("Loading plans")
    }

    /// Failure surface — error copy + Retry button calling `vm.load()`.
    /// Mirrors PaywallView's `loadFailureContent` pattern so the user
    /// has the same recovery affordance regardless of which surface
    /// presented the offerings fetch.
    @ViewBuilder
    private func loadFailureCTA(error: PayError) -> some View {
        VStack(spacing: CGFloat.Stir.space3) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: CGFloat.Stir.iconLg, weight: .semibold))
                .foregroundStyle(Color.Stir.amber600)
                .accessibilityHidden(true)
            Text("Couldn't load plans")
                .stirFont(.labelLg)
                .foregroundStyle(Color.Stir.textPrimary)
            Text(error.userFacingMessage)
                .stirFont(.bodySm)
                .foregroundStyle(Color.Stir.textTertiary)
                .multilineTextAlignment(.center)
            Button {
                Task { await viewModel.load() }
            } label: {
                Text("Try again")
                    .stirFont(.labelLg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CGFloat.Stir.controlVerticalPadding)
                    .background(Color.Stir.ink900)
                    .foregroundStyle(Color.Stir.paper50)
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd))
            }
            .accessibilityLabel("Retry loading plans")
        }
        .padding(.vertical, CGFloat.Stir.space3)
        .frame(maxWidth: .infinity)
    }

    private var proDisclosure: some View {
        Text(
            "Pro renews automatically. Cancel anytime in Settings > Apple ID > Subscriptions."
        )
        .stirFont(.bodySm)
        .foregroundStyle(Color.Stir.textTertiary)
        .multilineTextAlignment(.center)
    }
}
