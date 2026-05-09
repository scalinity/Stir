// DishOptionCard
//
// The hero component on Dinner Options — this is the "aha moment"
// surface (Specs/Design-System.md §8.3, mockup 05 §Dinner Options).
// Three of these arrive as SSE events stream in from /v1/ai/dinner-solve.
// Users tap one to move to Dish Preview.
//
// Visual grammar (matches the mockup verbatim):
//   - radius.lg (16pt) — hero card radius, distinct from the default
//     14pt so the dish cards visibly out-rank Saved/Import rows
//   - Horizontal split: paper.200 plate column (104pt) | content column
//   - Plate column hosts a SwiftUI port of the mockup's Plate
//     illustration; the tint cycles by rank (salmon / sage / amber)
//   - Content column carries an optional "TONIGHT'S PICK" eyebrow
//     (rank 1 only), the New York title (displayMd), and a single
//     muted sentence subtitle composed from `whyItFits` + total time
//   - Press feedback: 98% scale + ember border ring (DishOptionCardStyle)
//
// Refactor history: pre-step-9 the card carried a rank numeral, a
// FitLabel pill, and a clock/cart metadata row. The mockup-aligned
// design strips all three — `whyItFits` already reads as the "why"
// and the time folds into the subtitle, so the dual-pill + meta-row
// chrome was redundant.

import SwiftUI

struct DishOptionCard: View {
    let rank: Int
    let title: String
    let totalTimeMinutes: Int
    let whyItFits: String
    /// Retained for the accessibility label only — the new layout
    /// hides the missing-ingredient meta visually, but VoiceOver still
    /// reads "N ingredients to grab" so screen-reader users get the
    /// same shopping-load signal sighted users will read on the
    /// downstream DishPreviewView.
    let missingIngredientCount: Int
    /// Renders the ember "TONIGHT'S PICK" eyebrow above the title.
    /// DinnerOptionsView passes `rank == 1`; defaulted to false so
    /// previews and other callers can opt in explicitly.
    let tonightPick: Bool
    /// Max line count for the recipe title. Defaults to 2 to preserve
    /// the post-solve grid's compact silhouette; OtherOptionsRoot
    /// passes 3 because its long Gemini-generated titles ("Quick
    /// Flatbread with Tomato & Mozzarella") otherwise truncate
    /// mid-word with the ellipsis swallowing the meaningful tail.
    let titleLineLimit: Int

    init(
        rank: Int,
        title: String,
        totalTimeMinutes: Int,
        whyItFits: String,
        missingIngredientCount: Int,
        tonightPick: Bool = false,
        titleLineLimit: Int = 2,
    ) {
        self.rank = rank
        self.title = title
        self.totalTimeMinutes = totalTimeMinutes
        self.whyItFits = whyItFits
        self.missingIngredientCount = missingIngredientCount
        self.tonightPick = tonightPick
        self.titleLineLimit = titleLineLimit
    }

    /// Strip whitespace + leading/trailing periods from `whyItFits`
    /// before composing the subtitle. Lifted to a static constant —
    /// rebuilding the union on every body re-render was a small but
    /// pointless allocation.
    private static let whyItFitsTrimSet: CharacterSet =
        CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))

    var body: some View {
        // No internal Button wrapper — callers wrap the card in the
        // navigation affordance that suits their route type
        // (NavigationLink, Button, etc) and apply
        // `DishOptionCardStyle` via `.buttonStyle(...)`. Doing this
        // internally when the caller is already a NavigationLink
        // produces `Button(NavigationLink(Button(...)))`, which
        // VoiceOver reads as nested buttons and which `.buttonStyle(
        // .plain)` on the outer NavigationLink strips the press
        // feedback off of. Review finding W-H W33 (CR1+FD1).
        HStack(spacing: 0) {
            plateTile
            contentColumn
        }
        .frame(maxWidth: .infinity)
        // Match the skeleton's minHeight so the loading→loaded swap
        // doesn't shift the surrounding scroll content vertically.
        // Loaded cards still grow past 116pt for long titles or
        // accessibility-sized text.
        .frame(minHeight: 116)
        .stirCard(radius: CGFloat.Stir.radiusLg)
        // The plate tile fills its 104pt column edge-to-edge with
        // paper.200 — without clipShape, that fill would extend past
        // the card's rounded left corner and break the silhouette.
        // The `strokeBorder` baked into stirCard insets fully inside
        // the path, so the same-radius clip leaves the border intact.
        .clipShape(RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous))
        .contentShape(Rectangle())
        // Collapse the card's inner Text + plate subtree and substitute
        // the single card-level label. Without `.ignore`, SwiftUI
        // appends the accessibilityLabel to the auto-generated subtree
        // label producing a garbled double-read. Review finding W-H
        // W34 (CR1). `.ignore` also makes per-child
        // `.accessibilityHidden(true)` redundant — the children are
        // already excluded from the a11y tree.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Subviews

    private var plateTile: some View {
        // Plate stays a fixed 88pt and the tile column a fixed 104pt
        // even at accessibility-sized Dynamic Type. The plate is a
        // decorative anchor, not informational — its purpose is
        // ordinal differentiation between the three cards, not
        // legibility. Letting only the text grow keeps the content
        // column reading-friendly at XXXL while the plate remains a
        // stable visual anchor (mockup 05 keeps it fixed for the
        // same reason).
        ZStack {
            Color.Stir.paper200
            StirPlate(.option(tint: plateTint), size: 88)
        }
        .frame(width: 104)
        .frame(maxHeight: .infinity)
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: CGFloat.Stir.space1) {
            if tonightPick {
                Text("Tonight's pick")
                    .stirFont(.labelEyebrow)
                    .foregroundStyle(Color.Stir.ember600)
            }
            Text(title)
                .stirFont(.displayMd)
                .foregroundStyle(Color.Stir.ink900)
                .multilineTextAlignment(.leading)
                .lineLimit(titleLineLimit)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .stirFont(.bodyMd)
                .foregroundStyle(Color.Stir.ink500)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CGFloat.Stir.space4)
        .padding(.vertical, CGFloat.Stir.space3Half) // 14pt
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Composed strings

    /// "{whyItFits}. {N} min." — collapses the model's one-line
    /// rationale and the total cook time into a single sentence so
    /// the card body reads continuously (mockup 05 §Dinner Options).
    /// Trailing-period strip keeps us from rendering ".." when the
    /// model already terminates `whyItFits`.
    ///
    /// Note: visual uses the abbreviated "min." while
    /// `accessibilityLabel` uses the verbose "minutes" form —
    /// VoiceOver pronounces the verbose form more naturally. The
    /// asymmetry is intentional; if either string changes, update
    /// both deliberately.
    private var subtitle: String {
        let core = whyItFits.trimmingCharacters(in: Self.whyItFitsTrimSet)
        if core.isEmpty {
            return "\(totalTimeMinutes) min."
        }
        return "\(core). \(totalTimeMinutes) min."
    }

    /// Plate tint cycles by rank — salmon (1) → sage (2) → amber (3).
    /// No backend signal drives the choice; the visual variety is
    /// purely ordinal so users distinguish cards at a glance.
    private var plateTint: StirPlate.OptionTint {
        switch rank {
        case 1: return .salmon
        case 2: return .sage
        default: return .amber
        }
    }

    private var accessibilityLabel: String {
        // Same defensive clamp as the wire layer — a malformed upstream
        // response with a negative `missingIngredientCount` would
        // otherwise read "-2 ingredients to grab".
        let safeCount = max(0, missingIngredientCount)
        var parts: [String] = []
        if tonightPick {
            parts.append("Tonight's pick")
        }
        parts.append("Option \(rank): \(title)")
        parts.append("\(totalTimeMinutes) minutes")
        parts.append(safeCount == 0
                     ? "has every ingredient"
                     : "\(safeCount) ingredients to grab")
        parts.append("why it fits: \(whyItFits)")
        return parts.joined(separator: ", ")
    }
}

// MARK: - ButtonStyle — press feedback

/// 98% scale + ember border ring on press, per Spec §8.3. Reduce Motion
/// collapses the scale animation to instant (border still flips for the
/// press signal). Public so callers (NavigationLink, Button) can apply
/// it with `.buttonStyle(DishOptionCardStyle())`; internal use only —
/// not re-exported beyond the module.
struct DishOptionCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        // `.stirAnimation` handles the Reduce Motion gate internally,
        // so the scale step still fires on press (gated by
        // !reduceMotion) but the transition is instant under RM.
        // Review finding W-C W12 — demonstrates the DS pattern so the
        // tokens in Shared/Motion.swift aren't orphaned.
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1.0)
            .stirAnimation(.Stir.standard, value: configuration.isPressed)
            .overlay(
                RoundedRectangle(cornerRadius: CGFloat.Stir.radiusLg, style: .continuous)
                    .strokeBorder(
                        configuration.isPressed ? Color.Stir.ember600 : Color.clear,
                        lineWidth: 2,
                    ),
            )
    }
}

// MARK: - Previews

#Preview("DishOptionCard — light") {
    dishOptionGallery
        .preferredColorScheme(.light)
}

#Preview("DishOptionCard — dark") {
    dishOptionGallery
        .preferredColorScheme(.dark)
}

@MainActor
private var dishOptionGallery: some View {
    ScrollView {
        VStack(spacing: CGFloat.Stir.space3) {
            DishOptionCard(
                rank: 1,
                title: "Miso-Glazed Salmon with Sesame Rice",
                totalTimeMinutes: 22,
                whyItFits: "Uses salmon expiring tomorrow",
                missingIngredientCount: 0,
                tonightPick: true,
            )
            DishOptionCard(
                rank: 2,
                title: "Spinach & Scallion Tofu Scramble",
                totalTimeMinutes: 18,
                whyItFits: "Vegan swap",
                missingIngredientCount: 0,
            )
            DishOptionCard(
                rank: 3,
                title: "Everything Fried Rice with Crispy Egg",
                totalTimeMinutes: 15,
                whyItFits: "Clears 6 pantry items",
                missingIngredientCount: 0,
            )
        }
        .padding(CGFloat.Stir.space4)
    }
    .frame(width: 390, height: 844)
    .background(Color.Stir.paper50)
}
