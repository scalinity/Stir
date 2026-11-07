// LiveWebSocketTransportSecurityTests
//
// Pins the security-critical `open(url:authToken:)` guards in
// LiveWebSocketTransport:
//
//   - scheme MUST be `wss` (plaintext `ws://` or `http://` rejected).
//   - host MUST be the exact Realtime host `api.openai.com`.
//
// These guards defend against a compromised or MITM'd mint response
// redirecting the client secret (sent as a bearer header to whatever
// host `ws_url` names) to an attacker endpoint. The test matrix below
// is the per-finding regression guard for P1-R (2026-04-23).

import XCTest
@testable import Stir

@MainActor
final class LiveWebSocketTransportSecurityTests: XCTestCase {
    func test_open_rejects_non_wss_scheme() throws {
        let transport = LiveWebSocketTransport()
        let url = URL(string: "http://api.openai.com/v1/realtime?model=m")!
        XCTAssertThrowsError(try transport.open(url: url, authToken: "ek_test")) { error in
            guard let transportError = error as? LiveWebSocketTransport.TransportError else {
                return XCTFail("expected TransportError, got \(error)")
            }
            switch transportError {
            case .openFailed(let message):
                XCTAssertTrue(
                    message.contains("non-wss"),
                    "message should identify scheme rejection — got: \(message)",
                )
            default:
                XCTFail("expected openFailed, got \(transportError)")
            }
        }
    }

    func test_open_rejects_lookalike_host() throws {
        // The literal attack this pin defends against: a compromised
        // mint response pointing at `evilopenai.com` — same name suffix,
        // different owner. `hasSuffix("openai.com")` would accept this;
        // exact equality rejects it.
        let transport = LiveWebSocketTransport()
        let url = URL(string: "wss://evilopenai.com/v1/realtime?model=m")!
        XCTAssertThrowsError(try transport.open(url: url, authToken: "ek_test")) { error in
            guard let transportError = error as? LiveWebSocketTransport.TransportError else {
                return XCTFail("expected TransportError, got \(error)")
            }
            switch transportError {
            case .openFailed(let message):
                XCTAssertTrue(
                    message.contains("host not pinned"),
                    "message should identify host rejection — got: \(message)",
                )
            default:
                XCTFail("expected openFailed, got \(transportError)")
            }
        }
    }

    func test_open_rejects_subdomain_of_pinned_host() throws {
        // Exact match, not suffix: a subdomain is a different origin.
        let transport = LiveWebSocketTransport()
        let url = URL(string: "wss://api.openai.com.attacker.example/v1/realtime?model=m")!
        XCTAssertThrowsError(try transport.open(url: url, authToken: "ek_test"))
    }

    func test_open_rejects_random_host() throws {
        let transport = LiveWebSocketTransport()
        let url = URL(string: "wss://attacker.example/v1/realtime?model=m")!
        XCTAssertThrowsError(try transport.open(url: url, authToken: "ek_test"))
    }

    func test_open_accepts_pinned_host_and_scheme() throws {
        // Happy path — real host, wss. The open() call itself succeeds;
        // the underlying URLSession will fail to connect to the fake
        // endpoint but that's a runtime failure not a pin rejection.
        // We close() immediately after so the receive loop / ping
        // task don't stay running.
        let transport = LiveWebSocketTransport()
        let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")!
        XCTAssertNoThrow(try transport.open(url: url, authToken: "ek_test"))
        transport.close()
    }

    func test_scrubClientSecret_redacts_secret_and_bearer_values() {
        let raw = "request failed: Authorization: Bearer ek_secret-abc_123 for wss://api.openai.com/v1/realtime and key ek_other999"
        let scrubbed = LiveWebSocketTransport.scrubClientSecret(raw)
        XCTAssertFalse(scrubbed.contains("secret-abc_123"), "secret value must not survive scrub")
        XCTAssertFalse(scrubbed.contains("ek_other999"), "bare ek_ secrets must not survive scrub")
        XCTAssertTrue(scrubbed.contains("REDACTED"), "redaction marker must appear")
        XCTAssertTrue(scrubbed.contains("wss://api.openai.com/v1/realtime"), "non-secret text must be left alone")
    }

    func test_closeDuringToolOutputSendPreventsLateResponseCreate() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let transport = LiveWebSocketTransport(sharedSession: session)
        let task = session.webSocketTask(with: URL(string: "wss://test.invalid")!)
        transport._testInstallSocket(task)
        let firstMessage = expectation(description: "function output send suspended")
        var sendContinuation: CheckedContinuation<Void, Never>?
        var sentTypes: [String] = []
        transport.testingMessageSender = { message in
            guard case let .string(text) = message else { return }
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
            sentTypes.append(object?["type"] as? String ?? "unknown")
            await withCheckedContinuation { continuation in
                sendContinuation = continuation
                firstMessage.fulfill()
            }
        }
        let sending = Task { @MainActor in
            try await transport.send(.toolResponse(functionResponseId: "tool", name: "advance_step", response: ["ok": true]))
        }
        await fulfillment(of: [firstMessage], timeout: 1)
        let continuation = try XCTUnwrap(sendContinuation)
        transport.close()
        continuation.resume()
        do {
            try await sending.value
            XCTFail("closed tool send must fail before response.create")
        } catch {
            XCTAssertEqual(error as? LiveWebSocketTransport.TransportError, .sendAfterClose)
        }
        XCTAssertEqual(sentTypes, ["conversation.item.create"])
    }

}
