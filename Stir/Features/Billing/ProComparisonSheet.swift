// ProComparisonSheet
//
// Compare-plans modal launched from PaywallView. Side-by-side Premium vs
// Pro so power users can self-upgrade without the paywall steering them
// to Premium. Visual tokens resolve through Color.Stir / Font.Stir /
// CGFloat.Stir — zero raw hex, font, or spacing literals.

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .stirFont(.labelMd)
                }
            }
            .navigationTitle("Compare plans")
            .navigationBarTitleDisplayMode(.inline)
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
        VStack(spacing: 0) {
            // Column header row. Sighted users see which number is Premium
            // vs Pro; VoiceOver hears "Premium column" before the data rows.
            headerRow
            tableDivider
            row(label: "Dinner Solves / month", premium: "40", pro: "120")
            tableDivider
            row(label: "Voice Cook Sessions / month", premium: "20", pro: "40")
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

    private func row(label: String, premium: String, pro: String) -> some View {
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
        .accessibilityLabel("\(label). Premium: \(premium). Pro: \(pro).")
    }

    private var proCTAs: some View {
        VStack(spacing: CGFloat.Stir.space2 + 2) {
            if let offerings = viewModel.currentOfferings() {
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
                }
            } else {
                ProgressView()
                    .tint(Color.Stir.ember600)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, CGFloat.Stir.space4)
            }
        }
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
