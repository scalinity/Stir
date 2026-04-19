// AsyncTimeoutTests
//
// Verifies `withTimeout(seconds:operation:_:)` in `Core/Utilities/AsyncTimeout.swift`.

import XCTest
@testable import Stir

final class AsyncTimeoutTests: XCTestCase {
    func test_fastOperation_returnsResult() async throws {
        let result = try await withTimeout(seconds: 2, operation: "fast") {
            42
        }
        XCTAssertEqual(result, 42)
    }

    func test_slowOperation_throwsTimeout() async {
        do {
            _ = try await withTimeout(seconds: 0.1, operation: "slow") {
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 s > 0.1 s budget
                return 42
            }
            XCTFail("expected StirError.timeout")
        } catch StirError.timeout(let operation, let seconds) {
            XCTAssertEqual(operation, "slow")
            XCTAssertEqual(seconds, 0.1)
        } catch {
            XCTFail("expected StirError.timeout, got \(error)")
        }
    }

    func test_innerError_propagatesUnchanged() async {
        struct Boom: Error, Equatable {}
        do {
            _ = try await withTimeout(seconds: 2, operation: "throwing") {
                throw Boom()
            }
            XCTFail("expected Boom")
        } catch is Boom {
            // expected
        } catch {
            XCTFail("expected Boom, got \(error)")
        }
    }

    func test_operationLabel_surfacesInError() async {
        do {
            _ = try await withTimeout(seconds: 0.05, operation: "configBootstrap") {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            XCTFail("expected timeout")
        } catch StirError.timeout(let op, _) {
            XCTAssertEqual(op, "configBootstrap")
        } catch {
            XCTFail("expected StirError.timeout, got \(error)")
        }
    }
}
