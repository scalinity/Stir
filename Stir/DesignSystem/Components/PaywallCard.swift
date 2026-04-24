// PaywallCard
//
// Tier-comparison card used in the Plan & Billing view and the Paywall
// compare-plans bottom sheet (Specs/Design-System.md §8.10). One card
// per tier — typical layout stacks two (Premium / Pro) vertically.
//
// Visual grammar:
//   - radius.lg (16pt) — hero card level (tier cards are promotional)
//   - paper.100 fill, 1pt ink.100 border at rest
//   - ember.600 2pt border ring when `isSelected` (for the
//     compare-plans selection affordance, not the paywall hero CTA)
//   - displayMd tier name in ink.900
//   - displayLg price (large stated price to anchor expectation)
//   - bodyMd trial / cadence copy below price
//   - Feature list: sage.600 checkmark + body.md description per row
//   - Current-tier checkmark badge top-right (sage.600 circle)
//   - Optional footer label eyebrow ("MOST POPULAR", "CURRENT PLAN")
//
// This component is visual ONLY — no RevenueCat coupling, no SKU
// strings, no trial logic. Callers pass pre-formatted price + trial
// copy. PaywallViewModel owns the business rules; this just renders.

import SwiftUI

struct PaywallCard: View {
    let tierName: String
    let priceDisplay: String
    let cadenceDisplay: String
    let trialCopy: String?
    let features: [String]
    let eyebrow: String?
    let isCurrentTier: Bool
    let isSelected: Bool
    let onSelect: (() -> Void)?

    init(
        tierName: String,
        priceDisplay: String,
        cadenceDisplay: String,
        trialCopy: String? = nil,
        features: [String],
        eyebrow: String? = nil,
        isCurrentTier: Bool = false,
        isSelected: Bool = false,
        onSelect: (() -> Void)? = nil,
    ) {
        self.tierName = tierName
        self.priceDisplay = priceDisplay
        self.cadenceDisplay = cadenceDisplay
        self.trialCopy = trialCopy
        self.features = features
        self.eyebrow = eyebrow
        self.isCurrentTier = isCurrentTier
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: CGFloat.Stir.space4) {
            headerSection
            priceSection
            featureList
        }
        .padding(CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth),
        )
        .contentShape(Rectangle())

        if let onSelect {
            Button(action: onSelect) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        } else {
            // Non-interactive variant: no `.combine` because that
            // would flatten any future interactive child (e.g. a
            // "Learn more" affordance) into the static label. Use
            // `.contain` instead so SwiftUI still groups the card as
            // a single VoiceOver container without erasing children.
            // Review finding C3 (FD1).
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
                if let eyebrow {
                    Text(eyebrow)
                        .stirFont(.labelEyebrow)
                        .foregroundStyle(Color.Stir.ember600)
                }
                Text(tierName)
                    .stirFont(.displayMd)
                    .foregroundStyle(Color.Stir.ink900)
            }

            Spacer(minLength: CGFloat.Stir.space3)

            if isCurrentTier {
                Image.Stir.success
                    .font(.system(size: CGFloat.Stir.iconMd))
                    .foregroundStyle(Color.Stir.sage600)
                    .accessibilityLabel("Current plan")
            }
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
            HStack(alignment: .firstTextBaseline, spacing: CGFloat.Stir.space2) {
                Text(priceDisplay)
                    .stirFont(.displayLg)
                    .foregroundStyle(Color.Stir.ink900)
                Text(cadenceDisplay)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink500)
            }
            if let trialCopy {
                Text(trialCopy)
                    .stirFont(.bodySm)
                    .foregroundStyle(Color.Stir.ember600)
            }
        }
    }

    private var featureList: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
            ForEach(features, id: \.self) { feature in
                HStack(alignment: .firstTextBaseline, spacing: CGFloat.Stir.space2) {
                    Image.Stir.check
                        .font(.system(size: CGFloat.Stir.iconSm, weight: .semibold))
                        .foregroundStyle(Color.Stir.sage600)
                        .accessibilityHidden(true)
                    Text(feature)
                        .stirFont(.bodyMd)
                        .foregroundStyle(Color.Stir.ink700)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Styling

    private var borderColor: Color {
        isSelected ? Color.Stir.ember600 : Color.Stir.divider
    }

    private var borderWidth: CGFloat {
        isSelected ? 2 : 1
    }

    private var accessibilityLabel: String {
        // Include full feature content, not just count — VoiceOver
        // users need to hear what the plan offers to make a purchase
        // decision. "Includes 5 features" tells them nothing about
        // Premium vs Pro. Review finding C3 (FD1).
        var parts = [tierName, priceDisplay, cadenceDisplay]
        if let trialCopy { parts.append(trialCopy) }
        if isCurrentTier { parts.append("current plan") }
        if isSelected { parts.append("selected") }
        if !features.isEmpty {
            parts.append("Features: " + features.joined(separator: "; "))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#Preview("PaywallCard — light") {
    paywallCardGallery
        .preferredColorScheme(.light)
}

#Preview("PaywallCard — dark") {
    paywallCardGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var paywallCardGallery: some View {
    ScrollView {
        VStack(spacing: CGFloat.Stir.space4) {
            PaywallCard(
                tierName: "Premium",
                priceDisplay: "$69.99",
                cadenceDisplay: "/ year",
                trialCopy: "7 days free, then $69.99/yr — cancel anytime",
                features: [
                    "40 Dinner Solves per month",
                    "13 voice Cook Sessions per month",
                    "Unlimited tap-based Cook Mode",
                    "Saved favorites + widgets",
                    "Leftovers mode",
                ],
                eyebrow: "MOST POPULAR",
                isSelected: true,
                onSelect: {},
            )

            PaywallCard(
                tierName: "Pro",
                priceDisplay: "$139.99",
                cadenceDisplay: "/ year",
                features: [
                    "120 Dinner Solves per month",
                    "27 voice Cook Sessions per month",
                    "Multi-image kitchen scans",
                    "Priority inference queue",
                    "365-day household memory",
                ],
                onSelect: {},
            )

            PaywallCard(
                tierName: "Free",
                priceDisplay: "$0",
                cadenceDisplay: "",
                features: [
                    "6 Dinner Solves per month",
                    "Unlimited tap-based Cook Mode",
                    "Text-based Substitution Sheet",
                ],
                isCurrentTier: true,
            )
        }
        .padding(CGFloat.Stir.space4)
    }
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
