// CanonicalKeyHash
//
// Produces the 16-char SHA-256 truncation used for canonical_user_key_hash
// in spec §11 / CLAUDE.md. Every OSLog line, Sentry tag, and PostHog distinct
// ID uses this hash — NEVER the raw key — so log aggregators don't leak
// identity lineage across users.
//
// **Why 16 hex chars (64 bits) of a 256-bit digest?**
// Collision resistance has to exceed the realistic user population by a wide
// margin to stay safe under the birthday bound. 64 bits gives a 50% collision
// probability around 2^32 users (~4 billion) — three orders of magnitude past
// Stir's plausible TAM. Truncating keeps log lines compact (256-bit full
// digest would be 64 hex chars and blow past PostHog's distinct-id size
// preference). Review finding S11 (SA2) documents this so a future reader
// doesn't "fix" the truncation thinking it's a shortcut.

import CryptoKit
import Foundation

enum CanonicalKeyHash {
    /// 16-char lowercase hex SHA-256 truncation (64 bits of the 256-bit
    /// digest). Deterministic; cheap. See file-level comment for the
    /// collision-budget rationale.
    static func hash(_ canonicalKey: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalKey.utf8))
        return digest
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
            .lowercased()
    }

    /// Convenience for `CanonicalUserKey.stringValue` → hash.
    static func hash(_ key: CanonicalUserKey) -> String {
        hash(key.stringValue)
    }
}
