// CloudKitAccountMonitor
//
// Thin wrapper around CKContainer for account status + userRecordID, plus a
// NotificationCenter observer for `.CKAccountChanged`. The actual re-resolve
// logic lives in `IdentityService`; this file exists only to isolate CloudKit
// API surface for testability — unit tests swap in a mock conforming to
// `CloudKitAccountProviding`.

import CloudKit
import Foundation

/// Abstraction over the subset of CKContainer step-2 identity needs.
/// Kept minimal so mocks in commit-10 tests are small.
protocol CloudKitAccountProviding: Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func userRecordID() async throws -> CKRecord.ID
    func webAuthToken(apiToken: String) async throws -> String
}

/// Thin real-world implementation backed by `CKContainer.default()`.
struct CloudKitAccountProvider: CloudKitAccountProviding {
    private let container: CKContainer

    init(container: CKContainer = .default()) {
        self.container = container
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func userRecordID() async throws -> CKRecord.ID {
        try await container.userRecordID()
    }

    func webAuthToken(apiToken: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchWebAuthTokenOperation(apiToken: apiToken)
            operation.qualityOfService = .utility
            operation.fetchWebAuthTokenResultBlock = { result in
                continuation.resume(with: result)
            }
            container.privateCloudDatabase.add(operation)
        }
    }
}

// CKContainer is a reference type without Sendable conformance — but it is
// thread-safe per Apple's docs. Mark `CloudKitAccountProvider` Sendable by
// storing CKContainer in a value type; the init is the only place it leaves
// actor-isolated land.
extension CloudKitAccountProvider: @unchecked Sendable {}
