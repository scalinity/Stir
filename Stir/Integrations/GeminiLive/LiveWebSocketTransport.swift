// LiveWebSocketTransport
//
// Thin wrapper around URLSessionWebSocketTask that:
//   - opens the ws_url minted by /v1/ai/realtime-session (access_token
//     query param already embedded — we do NOT add an Authorization
//     header; CLAUDE.md §sharp-edge #13 + the constrained endpoint
//     spec say the token travels exclusively in the URL for that path)
//   - exposes a back-pressured AsyncThrowingStream of parsed inbound
//     frames so the session actor can consume with `for try await`
//   - serializes sends through the single task (URLSessionWebSocketTask
//     is documented as thread-safe for send, but we avoid interleaved
//     audio writes by routing all outbound through one method)
//   - tears down cleanly on `close()` (idempotent) — reusing the URL
//     session instance across transport lifetimes isn't supported by
//     URLSessionWebSocketTask semantics, so we own the session too.
//
// Deliberately NO retry / reconnect logic lives here — that's the
// session actor's responsibility (see RealtimeSession.refreshSession).
// This type is a thin pipe and stays testable in isolation.

import Foundation
import OSLog

@MainActor
final class LiveWebSocketTransport {
    /// Inbound frame stream. Consumers take this once at open time and
    /// iterate with `for try await`. The stream terminates on close or
    /// on an unrecoverable transport error.
    private(set) var inbound: AsyncThrowingStream<LiveInboundFrame, Error>!
    private var inboundContinuation: AsyncThrowingStream<LiveInboundFrame, Error>.Continuation!

    private let urlSession: URLSession
    private var wsTask: URLSessionWebSocketTask?
    private var isClosed = false
    private var receiveLoopTask: Task<Void, Never>?

    /// Error bucket for typed transport failures. Transport-level errors
    /// are distinct from session-level errors (bad wire shape, protocol
    /// violations) so the session actor can decide between "fall back"
    /// and "retry on this connection" cleanly.
    enum TransportError: Error, Equatable, Sendable {
        /// The URL couldn't be opened at all (DNS, TLS, unreachable).
        /// Session actor → fall back to C.3.
        case openFailed(message: String)
        /// Connection closed by server unexpectedly (non-goAway).
        /// Session actor → attempt refresh; if that fails, fall back.
        case connectionDropped(code: Int, reason: String?)
        /// Inbound payload wasn't valid JSON or was binary (unexpected
        /// for Gemini Live — it's a JSON-over-WebSocket protocol).
        case malformedInbound(message: String)
        /// Caller tried to send after `close()`. Indicates a shutdown
        /// race on the session actor's side; logged at info, not an
        /// assertion failure (pre-empt doesn't crash in production).
        case sendAfterClose
    }

    init(urlSession: URLSession = URLSession(configuration: .default)) {
        self.urlSession = urlSession
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LiveInboundFrame.self)
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Open the WebSocket. Resolves when the task is `.connecting` —
    /// the `setupComplete` inbound frame is the real "ready" signal and
    /// the session actor awaits that explicitly (don't front-run the
    /// handshake from here).
    func open(url: URL) throws {
        guard wsTask == nil else {
            Logger.voice.warning("live_ws_open_called_twice")
            return
        }
        guard !isClosed else {
            throw TransportError.sendAfterClose
        }
        var request = URLRequest(url: url)
        // Gemini Live's ephemeral-token path uses ?access_token=... in
        // the URL; no Authorization header. Attaching one causes a 401
        // in practice (pinned here so nobody "fixes" it by adding one).
        request.timeoutInterval = 10
        let task = urlSession.webSocketTask(with: request)
        self.wsTask = task
        task.resume()
        startReceiveLoop()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        inboundContinuation?.finish()
    }

    // MARK: - Send

    /// Send an outbound frame as JSON over the socket. Serializes via
    /// JSONSerialization (see LiveOutboundFrame for why we don't use
    /// JSONEncoder).
    func send(_ frame: LiveOutboundFrame) async throws {
        guard let task = wsTask, !isClosed else {
            throw TransportError.sendAfterClose
        }
        let obj = frame.asJSONObject()
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: obj, options: [])
        } catch {
            throw TransportError.malformedInbound(message: "encode failed: \(error.localizedDescription)")
        }
        // Gemini Live accepts text frames (stringified JSON) for the
        // control channel. Audio is still base64 inside that JSON — we
        // never send binary frames.
        guard let str = String(data: data, encoding: .utf8) else {
            throw TransportError.malformedInbound(message: "utf8 conversion failed")
        }
        try await task.send(.string(str))
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func receiveLoop() async {
        while !isClosed, !Task.isCancelled {
            guard let task = wsTask else { break }
            do {
                let message = try await task.receive()
                await handleInboundMessage(message)
            } catch {
                if isClosed || Task.isCancelled { break }
                // Map NSURLErrorDomain to connectionDropped. The
                // session actor decides whether to attempt refresh.
                let nsErr = error as NSError
                inboundContinuation?.finish(
                    throwing: TransportError.connectionDropped(
                        code: nsErr.code,
                        reason: nsErr.localizedDescription,
                    ),
                )
                break
            }
        }
    }

    private func handleInboundMessage(_ message: URLSessionWebSocketTask.Message) async {
        let text: String
        switch message {
        case let .string(s):
            text = s
        case let .data(d):
            // Unexpected binary — some Live variants might send binary
            // audio directly, but Constrained is JSON-only. Try UTF-8
            // decode as a best-effort; malformed binary surfaces as a
            // typed error the session actor logs then drops.
            guard let s = String(data: d, encoding: .utf8) else {
                inboundContinuation?.yield(with: .failure(TransportError.malformedInbound(
                    message: "unexpected binary frame, not utf8",
                )))
                return
            }
            text = s
        @unknown default:
            inboundContinuation?.yield(with: .failure(TransportError.malformedInbound(
                message: "unknown message case",
            )))
            return
        }
        guard let data = text.data(using: .utf8) else { return }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            Logger.voice.warning(
                "live_ws_inbound_json_parse_failed error=\(error.localizedDescription, privacy: .public)",
            )
            return
        }
        guard let frame = LiveInboundFrame.parse(json) else {
            Logger.voice.debug("live_ws_inbound_unparsed_shape")
            return
        }
        inboundContinuation?.yield(frame)
    }
}
