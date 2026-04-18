// KeychainStorage
//
// Thin `SecItem*` wrapper used by IdentityService (install UUID),
// SupabaseSessionClient (session JWT), and EntitlementService (last-known-good
// entitlement snapshot for the 24h offline grace window).
//
// CLAUDE.md §"What NOT to do by default" mandates Keychain over UserDefaults
// for anything mildly sensitive. Every key here gets a deterministic
// account/service pairing so uninstall-and-reinstall clears everything.
//
// Access group is intentionally unset — step 7 (extensions) will introduce a
// shared access group if Share Extension or Widgets need to read the session.
// Default group is per-app, scoped by bundle ID.

import Foundation
import Security
import OSLog

/// Abstraction over Keychain access so tests can swap in an in-memory double.
protocol KeychainStoring: Sendable {
    func read(key: KeychainKey) throws -> String?
    func write(_ value: String, key: KeychainKey) throws
    func delete(key: KeychainKey) throws
}

/// Typed Keychain slot. Service + account tuple is the Keychain-level primary key.
struct KeychainKey: Hashable, Sendable {
    let service: String
    let account: String
}

extension KeychainKey {
    /// Default service scope — derived from the bundle identifier so multiple
    /// apps installed side-by-side (e.g. `com.scalinity.stir.dev` and
    /// `com.scalinity.stir`) don't collide.
    private static var defaultService: String {
        Bundle.main.bundleIdentifier ?? "com.scalinity.stir"
    }

    /// The keychain-backed install UUID used when CloudKit identity is
    /// unavailable. Persists across reinstalls only if iCloud Keychain sync
    /// is active (which is generally OK — same user, same device lineage).
    static var installUUID: KeychainKey {
        KeychainKey(service: defaultService, account: "install_uuid")
    }

    /// Current session JWT from /v1/session/bootstrap. TTL 24h; refreshed by
    /// SupabaseSessionClient on AUTH-01 or 24h-expired reads.
    static var sessionJWT: KeychainKey {
        KeychainKey(service: defaultService, account: "session_jwt")
    }

    /// Last-known-good entitlement snapshot (JSON). Used within a 24h grace
    /// window when bootstrap fails, per step-2 spec.
    static var entitlementSnapshot: KeychainKey {
        KeychainKey(service: defaultService, account: "entitlement_snapshot")
    }
}

enum KeychainStorageError: Error, Sendable, Equatable {
    case osStatus(OSStatus)
    case dataCorrupted
}

struct KeychainStorage: KeychainStoring {
    static let shared = KeychainStorage()

    func read(key: KeychainKey) throws -> String? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: key.service,
            kSecAttrAccount: key.account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]

        var result: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            SecItemCopyMatching(query as CFDictionary, ptr)
        }
        _ = query // silence unused in Release-only builds

        switch status {
        case errSecSuccess:
            guard
                let data = result as? Data,
                let string = String(data: data, encoding: .utf8)
            else {
                throw KeychainStorageError.dataCorrupted
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            Logger.identity.error("keychain read failed, OSStatus=\(status, privacy: .public)")
            throw KeychainStorageError.osStatus(status)
        }
    }

    func write(_ value: String, key: KeychainKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainStorageError.dataCorrupted
        }

        // Upsert: try update first; if not present, add.
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: key.service,
            kSecAttrAccount: key.account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            // Items are accessible after first unlock, never on locked device
            // or backup to another device. kSecAttrAccessibleAfterFirstUnlock
            // is the standard pattern for session tokens that must survive
            // app relaunches but not device-to-device migration.
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary,
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            for (k, v) in attributes { addQuery[k] = v }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Logger.identity.error("keychain add failed, OSStatus=\(addStatus, privacy: .public)")
                throw KeychainStorageError.osStatus(addStatus)
            }
        default:
            Logger.identity.error("keychain update failed, OSStatus=\(updateStatus, privacy: .public)")
            throw KeychainStorageError.osStatus(updateStatus)
        }
    }

    func delete(key: KeychainKey) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: key.service,
            kSecAttrAccount: key.account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            Logger.identity.error("keychain delete failed, OSStatus=\(status, privacy: .public)")
            throw KeychainStorageError.osStatus(status)
        }
    }
}
