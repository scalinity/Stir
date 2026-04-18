// MockKeychain
//
// In-memory `KeychainStoring` double for unit tests. Thread-safe via NSLock
// so tests that spin off tasks can read/write without data races.

import Foundation
@testable import Stir

final class MockKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [KeychainKey: String] = [:]

    func read(key: KeychainKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func write(_ value: String, key: KeychainKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    func delete(key: KeychainKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = nil
    }

    /// Test-only accessor for state assertions.
    var snapshot: [KeychainKey: String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
