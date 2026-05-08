// RepeatCandidateSuppressionStore
//
// SCA-66 — per-recipe lifetime suppression for the "Save this as a
// one-tap weeknight meal?" prompt. Spec §8 row 947 fallback: "never
// nag again for same recipe". This store records the recipe IDs the
// user has explicitly opted out of and answers `isSuppressed(_:)` on
// the post-feedback intent decision.
//
// Storage:
//   * UserDefaults set serialized as a JSON array of UUID strings
//   * Bounded at 200 entries (FIFO eviction) to keep storage trivially
//     small. The cap is generous — even a power user who cooks 200
//     distinct recipes is unusual; if the cap evicts an old entry,
//     the user gets a re-prompt for that recipe, which is acceptable
//     behavior for a long-tail outlier.
//   * SCA-126: in-memory `Set<String>` cache invalidated on suppress /
//     reset; previously every isSuppressed() decoded the JSON blob.
//     Hot path is once per cook completion (not actually a perf
//     pinch today), but preempts a future O(n²) regression if a
//     list-screen caller ever filters by suppression.
//
// Tier-agnostic; the card itself decides Free→paywall vs Premium+
// →save. Suppression applies regardless of tier — a Free user who
// taps "Don't ask again" stays suppressed even after upgrading to
// Premium. SCA-126 documents the per-install scope explicitly:
// UserDefaults is per-app-install, NOT per-iCloud-user. Two-device
// users will see independent suppression sets (iPhone "Don't ask
// again" doesn't sync to iPad). App reinstall wipes. Spec §8 doesn't
// require cross-device sync; if a user complaint warrants it, this is
// the integration point to swap to a tiny CloudKit record per
// North-star #3.

import Foundation

@MainActor
final class RepeatCandidateSuppressionStore {
    static let shared = RepeatCandidateSuppressionStore()

    private let defaults: UserDefaults
    private static let key = "stir.feedback.repeatCandidate.suppressed.v1"
    private static let maxEntries = 200

    /// SCA-126: in-memory cache of the decoded suppression set. Lazily
    /// hydrated on first read; invalidated on every mutation. The
    /// underlying array on disk preserves FIFO order; the cache holds
    /// a Set for O(1) lookup. Reset() drops the cache + the disk row
    /// in lockstep.
    private var cachedEntries: Set<String>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns `true` when the user has previously tapped "Don't ask
    /// again" for this recipe.
    func isSuppressed(recipePlanId: UUID) -> Bool {
        loadCached().contains(recipePlanId.uuidString)
    }

    /// Suppress the prompt for this recipe lifetime (subject to FIFO
    /// eviction at maxEntries).
    func suppress(recipePlanId: UUID) {
        var entries = load()
        let key = recipePlanId.uuidString
        guard !entries.contains(key) else { return }
        entries.append(key)
        if entries.count > Self.maxEntries {
            entries = Array(entries.suffix(Self.maxEntries))
        }
        save(entries)
    }

    /// Test seam — wipe the suppression set.
    func reset() {
        cachedEntries = nil
        defaults.removeObject(forKey: Self.key)
    }

    private func load() -> [String] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func loadCached() -> Set<String> {
        if let cachedEntries { return cachedEntries }
        let set = Set(load())
        cachedEntries = set
        return set
    }

    private func save(_ entries: [String]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
        // Refresh the cache in lockstep so a follow-up isSuppressed()
        // sees the just-written entries without round-tripping disk.
        cachedEntries = Set(entries)
    }
}
