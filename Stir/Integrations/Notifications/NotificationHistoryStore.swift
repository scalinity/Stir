// NotificationHistoryStore
//
// UserDefaults-backed bookkeeping for the leftovers-followup +
// use-soon schedulers. Tracks fire timestamps + actioned-or-not per
// fire and exposes the two policy primitives both schedulers need:
//
//   1. 2-per-7d rolling cap — refuse to schedule when the last 7d
//      already saw 2 fires. Prevents a chatty user from getting
//      multiple back-to-back nudges.
//   2. 14d unactioned-streak suppression — when the prior 2 fires
//      both went unactioned, suppress further fires for 14 days.
//      An action (deep-link tap, leftovers session start, etc.)
//      clears the suppression immediately.
//
// Generic over storage keys so each scheduler gets its own isolated
// bucket.

import Foundation

@MainActor
final class NotificationHistoryStore {
    private let defaults: UserDefaults
    private let stateKey: String
    private let suppressionKey: String
    private static let maxEntries = 5

    struct Entry: Codable, Equatable {
        let fireAt: Date
        var actioned: Bool
    }

    init(defaults: UserDefaults, stateKey: String, suppressionKey: String) {
        self.defaults = defaults
        self.stateKey = stateKey
        self.suppressionKey = suppressionKey
    }

    var suppressedUntil: Date? {
        defaults.object(forKey: suppressionKey) as? Date
    }

    /// Fire timestamps within the trailing 7-day window from `asOf`.
    /// Used for the 2-per-week cap check.
    func firesInLastWeek(asOf: Date) -> [Date] {
        let cutoff = asOf.addingTimeInterval(-7 * 86_400)
        return load()
            .filter { $0.fireAt >= cutoff }
            .map { $0.fireAt }
    }

    /// Append a scheduled-fire entry. Also evaluates the unactioned
    /// streak — if the prior 2 entries were both unactioned, set the
    /// 14-day suppression starting now. Bounded at maxEntries entries
    /// so storage stays trivially small.
    func recordScheduled(fireAt: Date) {
        var entries = load()
        let prior = entries.suffix(2)
        if prior.count == 2, prior.allSatisfy({ !$0.actioned }) {
            defaults.set(
                Date().addingTimeInterval(14 * 86_400),
                forKey: suppressionKey,
            )
        }
        entries.append(Entry(fireAt: fireAt, actioned: false))
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        save(entries)
    }

    /// Mark the most recent fire as actioned. Also clears any active
    /// suppression — the user just demonstrated engagement.
    func markMostRecentActioned(at _: Date) {
        var entries = load()
        guard let last = entries.indices.last else { return }
        entries[last].actioned = true
        save(entries)
        defaults.removeObject(forKey: suppressionKey)
    }

    /// Test seam — wipe both buckets.
    func reset() {
        defaults.removeObject(forKey: stateKey)
        defaults.removeObject(forKey: suppressionKey)
    }

    private func load() -> [Entry] {
        guard let data = defaults.data(forKey: stateKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: stateKey)
    }
}
