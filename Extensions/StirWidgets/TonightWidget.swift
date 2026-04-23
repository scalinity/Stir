// TonightWidget
//
// Home Screen widget surfacing the latest dinner-solve. Matches the
// visual grammar in `stir-app-design/project/DesignMockups/13_widgets_liveactivity.html`:
//
//   - Paper50 card background, 14pt inner corner radius where shown
//   - StirGlyph badge + "TONIGHT" uppercase micro-eyebrow label (700/0.12em)
//   - Serif dish title (`.displaySm`), `.ink900`
//   - Tertiary metadata in `.ink500`
//   - Sage "Uses pantry" chip (`sage.100` tint + `sage.600` text)
//   - Ember CTA tile on Medium (100pt wide, 14pt radius, white stir + "START COOK")
//   - 3-row stack on Large (first row ember-tinted to highlight tonight's pick)
//
// Mockup divergence flagged to Daniel: mockup's Large widget shows a
// 5-day week-plan, which requires day-indexed meal persistence Stir
// doesn't have in step 7. Step-7 prompt specified "full 3-option
// dinner solve preview" → keeping that content scope. If week-plan
// large widget is desired, add a persisted MealPlan entity first.
//
// Refresh policy:
//   - Daily at 5pm local (TimelineProvider.nextFivePM)
//   - Event-driven: main app calls WidgetCenter.reloadAllTimelines()
//     after a successful solve (TonightSnapshotService)
//
// Deep links:
//   stir://solve/<solveId>/dish/<id> — specific dish
//   stir://solve/<solveId>           — solve overview
//   stir://scan/start                — empty state
//   stir://paywall/widget            — Free upgrade state
//
// Premium+ gating: checks cached tier in SharedStorage; Free users see
// the upgrade affordance rather than content.

import SwiftUI
import WidgetKit

struct TonightWidget: Widget {
    let kind: String = "TonightWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TonightProvider()) { entry in
            TonightWidgetView(entry: entry)
                .containerBackground(Color.Stir.paper50, for: .widget)
        }
        .configurationDisplayName("Tonight's dinner")
        .description("A quick glance at what Stir suggests cooking tonight.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Timeline

struct TonightEntry: TimelineEntry {
    let date: Date
    let snapshot: TonightSnapshot?
    let tier: String?
}

struct TonightProvider: TimelineProvider {
    func placeholder(in context: Context) -> TonightEntry {
        TonightEntry(date: .now, snapshot: .preview, tier: "premium")
    }

    func getSnapshot(in context: Context, completion: @escaping (TonightEntry) -> Void) {
        let storage = SharedStorage()
        completion(TonightEntry(
            date: .now,
            snapshot: storage.readTonight() ?? .preview,
            tier: storage.readTier(),
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TonightEntry>) -> Void) {
        let storage = SharedStorage()
        // First-seen signal for the `widget_added` Retention funnel.
        // Idempotent — only the first getTimeline fetch sets the
        // timestamp; main app drains on foreground.
        storage.markWidgetFirstSeenIfNeeded()
        let entry = TonightEntry(
            date: .now,
            snapshot: storage.readTonight(),
            tier: storage.readTier(),
        )
        let nextRefresh = Self.nextFivePM(from: .now)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }

    static func nextFivePM(from now: Date) -> Date {
        let cal = Calendar.current
        var components = cal.dateComponents([.year, .month, .day], from: now)
        components.hour = 17
        components.minute = 0
        components.second = 0
        let todayFive = cal.date(from: components) ?? now.addingTimeInterval(3_600)
        // `<=` (not `<`) so a call at exactly 17:00:00.000 schedules
        // TOMORROW's 5pm, not today's. Prior `<` would return a date in
        // the past by ~0ms, which WidgetKit treats as "refresh now" and
        // burns a reload budget slot on no-change data (S25).
        return now <= todayFive
            ? todayFive
            : cal.date(byAdding: .day, value: 1, to: todayFive) ?? todayFive
    }
}

// MARK: - Root view

struct TonightWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: TonightEntry

    var body: some View {
        if isPremium(tier: entry.tier) {
            if let snapshot = entry.snapshot, let top = snapshot.topDishes.first {
                switch family {
                case .systemSmall:  SmallView(snapshot: snapshot, top: top)
                case .systemMedium: MediumView(snapshot: snapshot, top: top)
                case .systemLarge:  LargeView(snapshot: snapshot)
                default:            SmallView(snapshot: snapshot, top: top)
                }
            } else {
                EmptyStateView()
            }
        } else {
            UpgradeView()
        }
    }

    private func isPremium(tier: String?) -> Bool {
        guard let raw = tier, let t = SharedTier(rawValue: raw) else { return false }
        return t.isPaid
    }
}

// MARK: - Small

private struct SmallView: View {
    let snapshot: TonightSnapshot
    let top: TonightSnapshot.DishBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                StirGlyph(size: 14)
                Text("Tonight")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.08)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.ink500)
            }
            .opacity(0.8)
            .padding(.bottom, 8)

            Text(top.title)
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .tracking(-0.17)
                .foregroundStyle(Color.Stir.ink900)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 0)

            Text(top.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.Stir.ink500)
                .padding(.top, 3)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text("Start cook")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(Color.Stir.ember600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "stir://solve/\(snapshot.solveId)/dish/\(top.id)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tonight: \(top.title), \(top.subtitle)")
        .accessibilityHint("Tap to start cooking")
    }
}

// MARK: - Medium

private struct MediumView: View {
    let snapshot: TonightSnapshot
    let top: TonightSnapshot.DishBrief

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    StirGlyph(size: 14)
                    Text("Tonight")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.08)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.Stir.ink500)
                }
                .opacity(0.8)
                .padding(.bottom, 8)

                Text(top.title)
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .tracking(-0.21)
                    .foregroundStyle(Color.Stir.ink900)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    UsesPantryChip()
                    Text(top.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.Stir.ink500)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            StartCookTile()
                .frame(width: 100)
        }
        .widgetURL(URL(string: "stir://solve/\(snapshot.solveId)/dish/\(top.id)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tonight: \(top.title), \(top.subtitle)")
        .accessibilityHint("Tap to start cooking")
    }
}

private struct UsesPantryChip: View {
    var body: some View {
        Text("Uses pantry")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Color.Stir.sage600)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(Color.Stir.sage100),
            )
    }
}

private struct StartCookTile: View {
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.2))
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 32, height: 32)

            Text("Start cook")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Stir.ember600),
        )
    }
}

// MARK: - Large

private struct LargeView: View {
    let snapshot: TonightSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                StirGlyph(size: 16)
                Text("Tonight's picks")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.ink500)
                Spacer()
                Text("\(snapshot.topDishes.count) of 3")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.Stir.ink500)
            }
            .padding(.bottom, 14)

            VStack(spacing: 6) {
                ForEach(Array(snapshot.topDishes.prefix(3).enumerated()), id: \.element.id) { idx, dish in
                    DishRow(dish: dish, isTopPick: idx == 0)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(.system(size: 11))
                Text("Open solve")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .heavy))
            }
            .foregroundStyle(Color.Stir.ember600)
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.Stir.ink100)
                    .frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "stir://solve/\(snapshot.solveId)"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(largeA11yLabel())
        .accessibilityHint("Tap to open tonight's solve")
    }

    /// Reads tonight's picks as one coherent phrase rather than a wall
    /// of per-dish sub-labels. "Tonight's picks, 3 of 3: Miso-Glazed
    /// Salmon tops the list, followed by Kale Farro Salad and Stir-fry
    /// veg."
    private func largeA11yLabel() -> String {
        let dishes = Array(snapshot.topDishes.prefix(3))
        guard !dishes.isEmpty else { return "Tonight's picks: nothing saved yet" }
        let titles = dishes.map(\.title)
        let countPhrase = "\(dishes.count) of 3"
        switch titles.count {
        case 1:
            return "Tonight's picks, \(countPhrase): \(titles[0])"
        case 2:
            return "Tonight's picks, \(countPhrase): \(titles[0]), and \(titles[1])"
        default:
            return "Tonight's picks, \(countPhrase): \(titles[0]) tops the list, followed by \(titles[1]) and \(titles[2])"
        }
    }
}

private struct DishRow: View {
    let dish: TonightSnapshot.DishBrief
    let isTopPick: Bool

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTopPick ? Color.Stir.paper50 : Color.Stir.paper100)
                .frame(width: 22, height: 22)
                .overlay(
                    Text(dish.heroEmoji)
                        .font(.system(size: 13)),
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(dish.title)
                    .font(.system(size: 12, weight: isTopPick ? .semibold : .medium))
                    .foregroundStyle(Color.Stir.ink900)
                    .lineLimit(1)
                Text(dish.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.Stir.ink500)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isTopPick {
                Text("Tonight")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.72)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.ember600)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous).fill(Color.Stir.paper50),
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isTopPick ? Color.Stir.ember100 : Color.Stir.paper100),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    isTopPick ? Color.Stir.ember600.opacity(0.25) : .clear,
                    lineWidth: 1,
                ),
        )
    }
}

// MARK: - Empty + Upgrade

private struct EmptyStateView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                StirGlyph(size: 14)
                Text("Stir")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.08)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.ink500)
            }
            .opacity(0.8)
            Text("Run a scan to see tonight's idea.")
                .font(.system(size: 13))
                .foregroundStyle(Color.Stir.ink700)
                .padding(.top, 4)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("Start scan")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(Color.Stir.ember600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "stir://scan/start"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stir. Run a scan to see tonight's idea")
        .accessibilityHint("Tap to start a scan")
    }
}

private struct UpgradeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                StirGlyph(size: 14)
                Text("Premium")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.08)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.Stir.ember600)
            }
            .opacity(0.85)
            Text("Widgets unlock with Premium.")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(Color.Stir.ink900)
                .padding(.top, 4)
                .lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("Upgrade")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .heavy))
            }
            .foregroundStyle(Color.Stir.ember600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "stir://paywall/widget"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Widgets unlock with Stir Premium")
        .accessibilityHint("Tap to upgrade")
    }
}

// MARK: - Preview fixture

extension TonightSnapshot {
    static let preview = TonightSnapshot(
        solveId: UUID(),
        capturedAt: .now,
        topDishes: [
            .init(
                id: UUID(),
                title: "Miso-Glazed Salmon",
                subtitle: "28 min · 2 serves",
                totalTimeMin: 28,
                keyIngredients: ["salmon", "miso"],
                heroEmoji: "🐟",
            ),
            .init(
                id: UUID(),
                title: "Kale & Farro Salad",
                subtitle: "20 min · 4 ingredients",
                totalTimeMin: 20,
                keyIngredients: ["kale", "farro"],
                heroEmoji: "🥗",
            ),
            .init(
                id: UUID(),
                title: "Stir-fry veg",
                subtitle: "15 min · 5 ingredients",
                totalTimeMin: 15,
                keyIngredients: ["bell pepper", "soy sauce"],
                heroEmoji: "🥦",
            ),
        ],
    )
}
