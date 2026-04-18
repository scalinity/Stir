// CanonicalKeyHash
//
// Produces the 16-char SHA-256 truncation used for canonical_user_key_hash
// in spec §11 / CLAUDE.md. Every OSLog line, Sentry tag, and PostHog distinct
// ID uses this hash — NEVER the raw key — so log aggregators don't leak
// identity lineage across users.

import CryptoKit
import Foundation

enum CanonicalKeyHash {
    /// 16-char lowercase hex SHA-256 truncation. Deterministic; cheap.
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
