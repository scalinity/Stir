// ProComparisonSheet
//
// Modal presented from the PaywallView's "Compare plans" link. Lists all
// four SKUs with a side-by-side Premium vs Pro feature table so power
// users can self-upgrade without the paywall leading them to Premium.

import SwiftUI

struct ProComparisonSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: PaywallViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    comparisonTable
                    proCTAs
                    proDisclosure
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationTitle("Compare plans")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Premium or Pro?")
                .font(.title2.bold())
            Text("Premium covers most weeknight cooks. Pro adds more Solves, longer memory, and multi-image scans.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    /// Used for the Pro column's minimum width so the column expands with
    /// Dynamic Type instead of clipping at accessibility sizes. 48pt at
    /// default body size; grows proportionally.
    @ScaledMetric(relativeTo: .footnote) private var proColumnMinWidth: CGFloat = 48

    private var comparisonTable: some View {
        VStack(spacing: 0) {
            // Column header row. Needed so a sighted user knows which
            // number is Premium vs Pro, and so VoiceOver users can hear
            // "Premium column" before the data rows are read.
            headerRow
            Divider()
            row(label: "Dinner Solves / month", premium: "40", pro: "120")
            Divider()
            row(label: "Voice Cook Sessions / month", premium: "20", pro: "40")
            Divider()
            row(label: "Remembered pantry items", premium: "250", pro: "1,000")
            Divider()
            row(label: "Multi-image scan", premium: "—", pro: "✓")
            Divider()
            row(label: "Priority inference queue", premium: "—", pro: "✓")
            Divider()
            row(label: "Household memory", premium: "90 days", pro: "365 days")
        }
        .padding(.vertical, 4)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var headerRow: some View {
        HStack {
            Text("").font(.caption.bold())
            Spacer()
            Text("Premium")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("Pro")
                .font(.caption.bold())
                .foregroundStyle(.tint)
                .frame(minWidth: proColumnMinWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Feature, Premium, Pro")
    }

    private func row(label: String, premium: String, pro: String) -> some View {
        HStack {
            Text(label).font(.footnote)
            Spacer()
            Text(premium).font(.footnote.monospacedDigit())
            Text(pro)
                .font(.footnote.monospacedDigit().bold())
                .foregroundStyle(.tint)
                .frame(minWidth: proColumnMinWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Combine children so VoiceOver reads each row as a single
        // phrase rather than three disconnected tokens. Previously the
        // screen reader voiced "Dinner Solves per month", silence,
        // "40", silence, "120" — leaving the user to infer which number
        // belongs to which column.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label). Premium: \(premium). Pro: \(pro).")
    }

    private var proCTAs: some View {
        VStack(spacing: 10) {
            if case .displaying(let offerings) = viewModel.state {
                if let pkg = offerings.proAnnualPackage {
                    Button {
                        Task { await viewModel.purchase(productID: pkg.productID) }
                    } label: {
                        VStack(spacing: 2) {
                            Text("Pro annual").font(.callout.bold())
                            Text("\(pkg.displayPrice) / year").font(.caption).foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.tint)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                if let pkg = offerings.proMonthlyPackage {
                    Button {
                        Task { await viewModel.purchase(productID: pkg.productID) }
                    } label: {
                        Text("Pro monthly — \(pkg.displayPrice)/mo")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private var proDisclosure: some View {
        Text(
            "Pro renews automatically. Cancel anytime in Settings > Apple ID > Subscriptions."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
}
