// PantryMatching
//
// String tokenizer + lemmatizer used by `PantryItemRepository.fetchExisting`'s
// Tier-3 normalized match (SCA-26). The contract: two ingredient names
// that "obviously refer to the same thing" should produce the same
// sorted token array, so set-equality matching catches plural/case/
// modifier-order variation without over-matching distinct products.
//
// Design notes:
// - Sorted-set comparison (not subset). "olive oil" must NOT match
//   "olive oil spray" — the spray has an extra token "spray", set
//   inequality, no match. This is the primary defense against false
//   positives that would auto-delete the wrong pantry row.
// - Lemmatization is deliberately conservative: only trailing 's',
//   'es', 'ies' on tokens >3 chars. "boss" doesn't strip to "bos";
//   "is" stays "is". Reduces false-negatives on plurals (onion ↔
//   onions) without producing English-rule corner-case bugs.
// - Lowercase + strip non-alphanumeric handles "Red-Onion" ≡ "red
//   onion" ≡ "RED ONION!" without inflating token count.
// - English-only. v1 launch is US-only (CLAUDE.md §What NOT to
//   reopen → "English / US-only launch"). Revisit if/when i18n.
//
// Why not Core Data computed property: the normalized form is purely
// derived from displayName, no value in storing it on the row. The
// O(N) full-table scan in fetchExisting Tier 3 only runs when slug
// AND exact-name match both miss — the rare path. For 1000-row Pro
// pantries × 20 ingredients = ~20K compares per cook, sub-millisecond
// in practice.

import Foundation

extension String {
    /// Tokenized + lemmatized + sorted form for pantry match comparison.
    /// Returns an empty array for empty/whitespace-only input.
    ///
    /// Example mappings (post-sort):
    /// - "Red Onion" → ["onion", "red"]
    /// - "red onions" → ["onion", "red"]
    /// - "Red-Onion!" → ["onion", "red"]
    /// - "olive oil" → ["oil", "olive"]
    /// - "olive oil spray" → ["oil", "olive", "spray"]
    /// - "" → []
    /// - "  " → []
    func pantryMatchTokens() -> [String] {
        let lower = self.lowercased()
        let tokens = lower
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .map(String.lemmatizePantryToken)
            .filter { !$0.isEmpty }
        return tokens.sorted()
    }

    /// Conservative English plural stripping. Only acts on tokens >3
    /// characters so "is", "as", "yes" survive intact. Order matters:
    /// check `ies` before `es` before `s` so "berries" → "berry"
    /// resolves correctly, not via the `s` branch.
    fileprivate static func lemmatizePantryToken(_ token: String) -> String {
        guard token.count > 3 else { return token }
        if token.hasSuffix("ies") {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("es") {
            return String(token.dropLast(2))
        }
        if token.hasSuffix("s") {
            return String(token.dropLast(1))
        }
        return token
    }
}
