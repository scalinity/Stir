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
        // SCA-386: 0.05s timeout vs 5s sleep — wide gap so sim resource
        // pressure can't compress the timer race. Pre-fix used 0.1s vs
        // 1.0s; the 900ms gap was thin enough that the full suite under
        // sim load occasionally saw the operation complete first.
        do {
            _ = try await withTimeout(seconds: 0.05, operation: "slow") {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 s ≫ 0.05 s budget
                return 42
            }
            XCTFail("expected StirError.timeout")
        } catch StirError.timeout(let operation, let seconds) {
            XCTAssertEqual(operation, "slow")
            XCTAssertEqual(seconds, 0.05)
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
        // SCA-386: 0.05s timeout vs 5s sleep — see test_slowOperation comment.
        do {
            _ = try await withTimeout(seconds: 0.05, operation: "configBootstrap") {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            XCTFail("expected timeout")
        } catch StirError.timeout(let op, _) {
            XCTAssertEqual(op, "configBootstrap")
        } catch {
            XCTFail("expected StirError.timeout, got \(error)")
        }
    }
}
