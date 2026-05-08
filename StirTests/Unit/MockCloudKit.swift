// MockCloudKit
//
// `CloudKitAccountProviding` double backed by configurable state so we can
// simulate .available / .noAccount / .restricted without a real iCloud signin.

import CloudKit
import Foundation
@testable import Stir

final class MockCloudKitAccountProvider: CloudKitAccountProviding, @unchecked Sendable {
    enum AccountBehavior {
        case available(recordName: String)
        case status(CKAccountStatus)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var _behavior: AccountBehavior
    private var _webAuthToken: Result<String, any Error> = .success("mock-web-auth-token")

    init(_ behavior: AccountBehavior = .status(.noAccount)) {
        self._behavior = behavior
    }

    func setBehavior(_ behavior: AccountBehavior) {
        lock.lock(); defer { lock.unlock() }
        self._behavior = behavior
    }

    func setWebAuthToken(_ result: Result<String, any Error>) {
        lock.lock(); defer { lock.unlock() }
        self._webAuthToken = result
    }

    func accountStatus() async throws -> CKAccountStatus {
        let behavior: AccountBehavior = {
            lock.lock(); defer { lock.unlock() }
            return _behavior
        }()
        switch behavior {
        case .available: return .available
        case .status(let s): return s
        case .failure(let e): throw e
        }
    }

    func userRecordID() async throws -> CKRecord.ID {
        let behavior: AccountBehavior = {
            lock.lock(); defer { lock.unlock() }
            return _behavior
        }()
        switch behavior {
        case .available(let recordName):
            return CKRecord.ID(recordName: recordName)
        case .status:
            throw NSError(domain: "MockCloudKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "userRecordID called on non-available status"])
        case .failure(let e):
            throw e
        }
    }

    func webAuthToken(apiToken: String) async throws -> String {
        let result: Result<String, any Error> = {
            lock.lock(); defer { lock.unlock() }
            return _webAuthToken
        }()
        return try result.get()
    }
}
