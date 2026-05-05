// CoachMarkCard
//
// Floating info card paired with the spotlight. Renders the step's
// title, message, optional voice-command examples, and the Skip + Next
// (or Got it) action stack.
//
// Visual grammar:
//   - paper100 body, ink100 hairline, radius.lg, shadow.md
//   - ember eyebrow ("STEP N OF M") in `labelMicroEyebrow`
//   - title in `displaySm`, message in `bodyMd`
//   - voice examples (when present): mono-quote phrase + bodySm
//     description, separated by ink100 hairlines
//   - Skip = TextButton ink500; Next/Got it = compact ember pill

import SwiftUI

struct CoachMarkCard: View {
    let step: CoachMarkStep
    let stepNumber: Int
    let totalSteps: Int
    let isFinalStep: Bool
    let onSkip: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space3) {
            eyebrow
            VStack(alignment: .leading, spacing: CGFloat.Stir.space2) {
                Text(step.title)
                    .stirFont(.displaySm)
                    .foregroundStyle(Color.Stir.ink900)
                    .accessibilityAddTraits(.isHeader)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.message)
                    .stirFont(.bodyMd)
                    .foregroundStyle(Color.Stir.ink700)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !step.voiceExamples.isEmpty {
                voiceExamples
            }
            actionStack
        }
        .padding(.horizontal, CGFloat.Stir.space4)
        .padding(.vertical, CGFloat.Stir.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                .fill(Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                .strokeBorder(Color.Stir.ink100, lineWidth: 1),
        )
        .shadow(color: Color.Stir.ink900.opacity(0.18), radius: 18, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var eyebrow: some View {
        HStack(spacing: CGFloat.Stir.space2) {
            // Suppress "STEP 1 OF 1" — it reads as redundant on
            // single-step sequences. Render "TIP" eyebrow for that
            // case so the card still has a typographic anchor.
            if totalSteps == 1 {
                Text("TIP")
                    .stirFont(.labelMicroEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
            } else {
                Text("STEP \(stepNumber) OF \(totalSteps)")
                    .stirFont(.labelMicroEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
            }
            Spacer(minLength: 0)
            if step.requiredAction != nil {
                Text("DO THIS")
                    .stirFont(.labelMicroEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
                    .padding(.horizontal, CGFloat.Stir.space2)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.Stir.ember100),
                    )
            }
        }
    }

    private var voiceExamples: some View {
        // Voice tutorial special: each command is a quoted phrase + a
        // plain-language description. Separated by hairlines so the
        // list reads as a glossary, not a paragraph.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(step.voiceExamples) { example in
                if example.id != step.voiceExamples.first?.id {
                    Rectangle()
                        .fill(Color.Stir.ink100)
                        .frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: CGFloat.Stir.space3) {
                    Text("“\(example.phrase)”")
                        .stirFont(.monoQuote)
                        .foregroundStyle(Color.Stir.voice600)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(example.does)
                        .stirFont(.bodySm)
                        .foregroundStyle(Color.Stir.ink700)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, CGFloat.Stir.space2)
            }
        }
        .padding(.horizontal, CGFloat.Stir.space3)
        .padding(.vertical, CGFloat.Stir.space2)
        .background(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                .fill(Color.Stir.voice100.opacity(0.4)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: CGFloat.Stir.radiusMd, style: .continuous)
                .strokeBorder(Color.Stir.voice600.opacity(0.5), lineWidth: 1),
        )
    }

    private var actionStack: some View {
        HStack(spacing: CGFloat.Stir.space3) {
            Button(action: onSkip) {
                Text("Skip")
                    .stirFont(.labelLg)
                    .foregroundStyle(Color.Stir.ink500)
            }
            .accessibilityLabel("Skip tutorial")
            .accessibilityHint("Dismiss the rest of the tutorial steps")

            Spacer(minLength: 0)

            // Required-action steps hide the advance button — the
            // user has to perform the highlighted action to continue.
            // Skip is always available as the safety hatch.
            if step.requiredAction == nil {
                Button(action: onAdvance) {
                    Text(isFinalStep ? "Got it" : "Next")
                        .stirFont(.labelLg)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.Stir.paper50)
                        .padding(.horizontal, CGFloat.Stir.space4)
                        .padding(.vertical, CGFloat.Stir.space2)
                        .background(
                            Capsule().fill(Color.Stir.ember600),
                        )
                }
                .accessibilityLabel(isFinalStep ? "Got it" : "Next step")
            }
        }
    }

    private var accessibilityLabel: String {
        var label = "\(step.title). \(step.message)"
        if !step.voiceExamples.isEmpty {
            let examples = step.voiceExamples
                .map { "Say \($0.phrase): \($0.does)." }
                .joined(separator: " ")
            label += " " + examples
        }
        if step.requiredAction != nil {
            label += " Tap the highlighted control to continue."
        }
        return label
    }
}
