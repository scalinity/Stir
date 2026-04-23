// LiveWebSocketTransportSecurityTests
//
// Pins the security-critical `open(url:)` guards in LiveWebSocketTransport:
//
//   - scheme MUST be `wss` (plaintext `ws://` or `http://` rejected).
//   - host MUST be the exact Gemini Live host
//     `generativelanguage.googleapis.com`.
//
// These guards defend against a compromised or MITM'd mint response
// redirecting the ephemeral Gemini token to an attacker endpoint via
// the `?access_token=...` query param. The test matrix below is the
// per-finding regression guard for P1-R (2026-04-23).

import XCTest
@testable import Stir

@MainActor
final class LiveWebSocketTransportSecurityTests: XCTestCase {
    func test_open_rejects_non_wss_scheme() throws {
        let transport = LiveWebSocketTransport()
        let url = URL(string: "http://generativelanguage.googleapis.com/path?access_token=abc")!
        XCTAssertThrowsError(try transport.open(url: url)) { error in
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
        // mint response pointing at `evilgoogleapis.com` — same TLD
        // suffix, different owner. `hasSuffix("googleapis.com")` would
        // accept this; exact equality rejects it.
        let transport = LiveWebSocketTransport()
        let url = URL(string: "wss://evilgoogleapis.com/path?access_token=abc")!
        XCTAssertThrowsError(try transport.open(url: url)) { error in
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

    func test_open_rejects_random_host() throws {
        let transport = LiveWebSocketTransport()
        let url = URL(string: "wss://attacker.example/path?access_token=abc")!
        XCTAssertThrowsError(try transport.open(url: url))
    }

    func test_open_accepts_pinned_host_and_scheme() throws {
        // Happy path — real host, wss. The open() call itself succeeds;
        // the underlying URLSession will fail to connect to the fake
        // endpoint but that's a runtime failure not a pin rejection.
        // We close() immediately after so the receive loop / ping
        // task don't stay running.
        let transport = LiveWebSocketTransport()
        let url = URL(string: "wss://generativelanguage.googleapis.com/ws?access_token=test")!
        XCTAssertNoThrow(try transport.open(url: url))
        transport.close()
    }

    func test_scrubAccessToken_redacts_token_value() {
        let raw = "connection failed to wss://generativelanguage.googleapis.com/ws?access_token=auth_tokens/secret-abc-123"
        let scrubbed = LiveWebSocketTransport.scrubAccessToken(raw)
        XCTAssertFalse(scrubbed.contains("secret-abc-123"), "token value must not survive scrub")
        XCTAssertTrue(scrubbed.contains("access_token=REDACTED"), "redaction marker must appear")
    }
}
