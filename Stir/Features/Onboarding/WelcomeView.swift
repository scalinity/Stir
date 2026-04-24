// WelcomeView
//
// First screen new users see (mockup 01 §Welcome). Two CTAs:
//   - "Try it now" → proceeds into Setup 1 (preferences).
//   - "See a sample" → bypasses onboarding with a sample Tonight Home.
//     Sample path remains stubbed pending mockup 04's Scan flow work.
//
// Visual grammar (mockup 01):
//   - Top-left "Stir." wordmark in New York Semibold, 22pt
//   - Centered bowl illustration (one-off brand mark — §2 "wordmark
//     only for v1" softened by the bowl as a welcome-specific motif)
//   - Hero tagline "Cook what you already have." in New York Semibold
//     40pt, -0.025em tracking (§4.1 one-off hero size, NOT tokenized)
//   - Body copy at bodyLg: "Scan your kitchen. Stir gives you three
//     dinners, ranked — then walks you through one."
//   - PrimaryButton "Try it now"
//   - TextButton "See a sample"
//   - Footer body.sm: "No account needed. Your scans stay on device."
//     (defuses "do I need to log in?" anxiety — mockup annotation)

import SwiftUI

struct WelcomeView: View {
    let onTryIt: () -> Void
    let onSeeSample: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topWordmark
            heroBlock
            actionStack
            footer
        }
        .padding(.horizontal, CGFloat.Stir.screenMarginHero) // 20pt hero margin
        .padding(.top, CGFloat.Stir.space3)
        .padding(.bottom, CGFloat.Stir.space5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.Stir.paper50)
    }

    // MARK: - Sections

    /// Small wordmark in top-left, restrained brand anchor above the hero.
    private var topWordmark: some View {
        // justification: 22pt wordmark is a one-off hero size per §4.1;
        // Stir's wordmark renders at bespoke per-screen sizes (22pt here,
        // 40pt tagline, 96pt launch), not from the typography scale.
        (Text("Stir")
            .foregroundStyle(Color.Stir.ink900)
            + Text(".")
            .foregroundStyle(Color.Stir.ember600))
            // justification: 22pt top-left wordmark — one-off hero size per §4.1 (see StirWordmark comment block above)
            .font(.system(size: 22, weight: .semibold, design: .serif))
            .tracking(-0.44) // 22 × -0.02em
            .padding(.leading, CGFloat.Stir.space1)
            .padding(.top, CGFloat.Stir.space1)
            .accessibilityLabel("Stir")
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
            HStack {
                Spacer()
                WelcomeBowl()
                    .frame(width: 140, height: 84)
                    .accessibilityHidden(true) // decorative motif
                Spacer()
            }
            .padding(.bottom, CGFloat.Stir.space2)

            // justification: 40pt hero tagline is a one-off per §4.1 —
            // between display.xl (34pt) and a scaled-up bespoke 40pt for
            // the first-impression moment.
            Text("Cook what you already\u{00A0}have.")
                // justification: 40pt hero tagline — one-off per §4.1 (between display.xl 34pt and bespoke Welcome scale-up)
                .font(.system(size: 40, weight: .semibold, design: .serif))
                .tracking(-1.0) // 40 × -0.025em
                .lineSpacing(6)  // targets ~46pt line height at default
                .foregroundStyle(Color.Stir.ink900)
                .accessibilityAddTraits(.isHeader)

            Text("Scan your kitchen. Stir gives you three dinners, ranked — then walks you through one.")
                .stirFont(.bodyLg)
                .foregroundStyle(Color.Stir.ink700)
                .frame(maxWidth: 330, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.bottom, CGFloat.Stir.space6)
    }

    private var actionStack: some View {
        VStack(spacing: CGFloat.Stir.space3 - 2) { // 10pt — tighter stack
            PrimaryButton(title: "Try it now", action: onTryIt)
            TextButton(title: "See a sample", action: onSeeSample)
        }
    }

    private var footer: some View {
        Text("No account needed. Your scans stay on device.")
            .stirFont(.bodySm)
            .foregroundStyle(Color.Stir.ink500)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, CGFloat.Stir.space2)
            .accessibilityHint("Privacy reassurance — no sign-in required")
    }
}

// MARK: - WelcomeBowl

/// Illustrated bowl motif for Welcome only. Reproduces mockup 01's SVG
/// (steam wisps + ember rim + paper.200 bowl body + five ingredient
/// dots) as SwiftUI Canvas. Not an empty-state illustration; not a
/// general icon — this is the one bespoke brand image in v1 and lives
/// with its only consumer rather than in the icon catalog.
///
/// Design-System.md §13 defers a general illustration library to v2;
/// this one is scoped tightly to Welcome, not a library entry.
private struct WelcomeBowl: View {
    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 140
            let scaleY = size.height / 84
            let scale = min(scaleX, scaleY)

            // Steam wisps
            let wispStroke = GraphicsContext.Shading.color(Color.Stir.ink300)
            let wispStyle = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round)
            for x in [50, 70, 90] {
                let xp = CGFloat(x) * scale
                var path = Path()
                path.move(to: CGPoint(x: xp, y: 18 * scale))
                path.addQuadCurve(
                    to: CGPoint(x: xp, y: 0),
                    control: CGPoint(x: xp + 4 * scale, y: 8 * scale),
                )
                context.stroke(path, with: wispStroke, style: wispStyle)
            }

            // Bowl body (below the rim) — paper200 fill, ember outline
            var body = Path()
            body.move(to: CGPoint(x: 16 * scale, y: 36 * scale))
            body.addQuadCurve(
                to: CGPoint(x: 124 * scale, y: 36 * scale),
                control: CGPoint(x: 70 * scale, y: 90 * scale),
            )
            body.addLine(to: CGPoint(x: 118 * scale, y: 62 * scale))
            body.addQuadCurve(
                to: CGPoint(x: 22 * scale, y: 62 * scale),
                control: CGPoint(x: 70 * scale, y: 92 * scale),
            )
            body.closeSubpath()
            context.fill(body, with: .color(Color.Stir.paper200))
            context.stroke(
                body,
                with: .color(Color.Stir.ember600),
                style: StrokeStyle(lineWidth: 1.5 * scale, lineJoin: .round),
            )

            // Rim ellipse — ember tint fill + ember outline
            let rimRect = CGRect(
                x: (70 - 56) * scale,
                y: (34 - 8) * scale,
                width: 112 * scale,
                height: 16 * scale,
            )
            let rim = Path(ellipseIn: rimRect)
            context.fill(rim, with: .color(Color.Stir.ember100))
            context.stroke(
                rim,
                with: .color(Color.Stir.ember600),
                style: StrokeStyle(lineWidth: 1.5 * scale),
            )

            // Ingredients sitting on the rim
            let ingredients: [(CGFloat, CGFloat, CGFloat, Color)] = [
                (56, 32, 4, Color.Stir.ember600),
                (70, 30, 3, Color.Stir.amber600),
                (84, 32, 4, Color.Stir.sage600),
                (64, 35, 2, Color.Stir.ink700),
                (78, 35, 2, Color.Stir.ink700),
            ]
            for (cx, cy, r, color) in ingredients {
                let rect = CGRect(
                    x: (cx - r) * scale,
                    y: (cy - r) * scale,
                    width: 2 * r * scale,
                    height: 2 * r * scale,
                )
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
    }
}

// MARK: - Previews

#Preview("Welcome — light") {
    WelcomeView(onTryIt: {}, onSeeSample: {})
        .frame(width: 390, height: 844)
        .preferredColorScheme(.light)
}

#Preview("Welcome — dark") {
    WelcomeView(onTryIt: {}, onSeeSample: {})
        .frame(width: 390, height: 844)
        .preferredColorScheme(.dark)
}
