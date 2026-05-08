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
//
// Tier-agnostic; the card itself decides Free→paywall vs Premium+
// →save. Suppression applies regardless of tier — a Free user who
// taps "Don't ask again" stays suppressed even after upgrading.

import Foundation

@MainActor
final class RepeatCandidateSuppressionStore {
    static let shared = RepeatCandidateSuppressionStore()

    private let defaults: UserDefaults
    private static let key = "stir.feedback.repeatCandidate.suppressed.v1"
    private static let maxEntries = 200

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns `true` when the user has previously tapped "Don't ask
    /// again" for this recipe.
    func isSuppressed(recipePlanId: UUID) -> Bool {
        load().contains(recipePlanId.uuidString)
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
        defaults.removeObject(forKey: Self.key)
    }

    private func load() -> [String] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func save(_ entries: [String]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
