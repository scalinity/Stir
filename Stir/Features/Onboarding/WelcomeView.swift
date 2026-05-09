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

    /// Scales the 22pt top-left wordmark + 40pt hero tagline with
    /// Dynamic Type. Review finding W-F W25 (FD1).
    @ScaledMetric(relativeTo: .largeTitle) private var topWordmarkSize: CGFloat = 22
    @ScaledMetric(relativeTo: .largeTitle) private var heroTaglineSize: CGFloat = 40

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
            // justification: 22pt top-left wordmark — one-off hero size per §4.1 (see StirWordmark comment block above), scaled via @ScaledMetric
            .font(.system(size: topWordmarkSize, weight: .semibold, design: .serif))
            .tracking(topWordmarkSize * -0.02) // -0.02em tight wordmark tracking, scales with size
            .padding(.leading, CGFloat.Stir.space1)
            .padding(.top, CGFloat.Stir.space1)
            .accessibilityLabel("Stir")
    }

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space5) {
            HStack {
                Spacer()
                WelcomeBowl()
                    .frame(width: 140, height: 110)
                    .accessibilityHidden(true) // decorative motif
                Spacer()
            }
            .padding(.bottom, CGFloat.Stir.space2)

            // justification: 40pt hero tagline is a one-off per §4.1 —
            // between display.xl (34pt) and a scaled-up bespoke 40pt for
            // the first-impression moment.
            Text("Cook what you already\u{00A0}have.")
                // justification: 40pt hero tagline — one-off per §4.1 (between display.xl 34pt and bespoke Welcome scale-up), scaled via @ScaledMetric
                .font(.system(size: heroTaglineSize, weight: .semibold, design: .serif))
                .tracking(heroTaglineSize * -0.025) // -0.025em tight tracking, scales with size
                .lineSpacing(heroTaglineSize * 0.15) // ~46pt line height at default (40×1.15), scales proportionally
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
/// (steam wisps + ember rim + paper.200 bowl body + six ingredient
/// dots) as SwiftUI Canvas. Not an empty-state illustration; not a
/// general icon — this is the one bespoke brand image in v1 and lives
/// with its only consumer rather than in the icon catalog.
///
/// Coordinate system mirrors the mockup SVG viewBox `-10 -24 160 120`
/// so paths port verbatim from the HTML source. Earlier revisions
/// drifted into a closed two-curve "lens" bowl that read as a smiley
/// face (SCA-290) — bowl body is now a single open half-ellipse, the
/// rim sits on top, ingredients drop into the broth.
///
/// Design-System.md §13 defers a general illustration library to v2;
/// this one is scoped tightly to Welcome, not a library entry.
private struct WelcomeBowl: View {
    var body: some View {
        Canvas { context, size in
            // Mockup viewBox: -10 -24 160 120 (width 160, height 120).
            // Map SVG coords → canvas with uniform scale + offset so a
            // 140×110 frame renders at ~scale 0.875.
            let scale = min(size.width / 160, size.height / 120)
            let offsetX = 10 * scale  // = -viewBoxMinX * scale
            let offsetY = 24 * scale  // = -viewBoxMinY * scale

            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale + offsetX, y: y * scale + offsetY)
            }

            let strokeBowl = StrokeStyle(
                lineWidth: 1.5 * scale,
                lineCap: .round,
                lineJoin: .round,
            )
            let strokeRim = StrokeStyle(lineWidth: 1.5 * scale)
            let strokeWisp = StrokeStyle(lineWidth: 1.5 * scale, lineCap: .round)

            // Steam — three wavy S-curve wisps rising from the rim.
            // Verbatim from mockup SVG paths; opacity 0.6 / 0.7 / 0.6.
            let wisps: [(start: CGPoint, ctrl1: CGPoint, mid: CGPoint, ctrl2: CGPoint, end: CGPoint, opacity: Double)] = [
                // M54 10 Q50 4 54 -2 Q58 -8 54 -14
                (p(54, 10), p(50, 4), p(54, -2), p(58, -8), p(54, -14), 0.6),
                // M70 8  Q66 2 70 -4 Q74 -10 70 -16
                (p(70, 8), p(66, 2), p(70, -4), p(74, -10), p(70, -16), 0.7),
                // M86 10 Q82 4 86 -2 Q90 -8 86 -14
                (p(86, 10), p(82, 4), p(86, -2), p(90, -8), p(86, -14), 0.6),
            ]
            for wisp in wisps {
                var path = Path()
                path.move(to: wisp.start)
                path.addQuadCurve(to: wisp.mid, control: wisp.ctrl1)
                path.addQuadCurve(to: wisp.end, control: wisp.ctrl2)
                context.stroke(
                    path,
                    with: .color(Color.Stir.ink300.opacity(wisp.opacity)),
                    style: strokeWisp,
                )
            }

            // Bowl body — single open half-ellipse hanging from the rim:
            // M18 34 Q70 88 122 34. Fill closes the implicit shape;
            // stroke renders only the visible arc.
            var bowlBody = Path()
            bowlBody.move(to: p(18, 34))
            bowlBody.addQuadCurve(to: p(122, 34), control: p(70, 88))
            context.fill(bowlBody, with: .color(Color.Stir.paper200))
            context.stroke(bowlBody, with: .color(Color.Stir.ember600), style: strokeBowl)

            // Rim ellipse drawn on top of the bowl body:
            // cx=70 cy=34 rx=52 ry=7
            let rimRect = CGRect(
                origin: p(70 - 52, 34 - 7),
                size: CGSize(width: 104 * scale, height: 14 * scale),
            )
            let rim = Path(ellipseIn: rimRect)
            context.fill(rim, with: .color(Color.Stir.ember100))
            context.stroke(rim, with: .color(Color.Stir.ember600), style: strokeRim)

            // Ingredients sitting in the broth (six dots — four colored,
            // two small dark accents at half opacity).
            let ingredients: [(cx: CGFloat, cy: CGFloat, r: CGFloat, color: Color, opacity: Double)] = [
                (52, 32, 3.5, Color.Stir.ember600, 1.0),
                (64, 33, 2.5, Color.Stir.amber600, 1.0),
                (76, 32, 3.0, Color.Stir.sage600,  1.0),
                (88, 33, 2.5, Color.Stir.ember600, 1.0),
                (58, 35, 1.5, Color.Stir.ink700,   0.5),
                (82, 35, 1.5, Color.Stir.ink700,   0.5),
            ]
            for ing in ingredients {
                let center = p(ing.cx, ing.cy)
                let rad = ing.r * scale
                let rect = CGRect(
                    x: center.x - rad,
                    y: center.y - rad,
                    width: 2 * rad,
                    height: 2 * rad,
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(ing.color.opacity(ing.opacity)),
                )
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
