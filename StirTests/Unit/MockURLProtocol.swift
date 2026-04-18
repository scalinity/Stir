// MockURLProtocol
//
// URLProtocol subclass that intercepts URLSession requests so we can assert
// + script HTTP behavior for `SupabaseSessionClient` unit tests without
// standing up a real server.

import Foundation

final class MockURLProtocol: URLProtocol {
    /// Handler set by the test. Receives the outgoing request; returns the
    /// response tuple or throws to simulate a network-level failure.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() { handler = nil }

    /// Make an ephemeral URLSession configured to route through this protocol.
    static func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "MockURLProtocol", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: "no handler set"]),
            )
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
