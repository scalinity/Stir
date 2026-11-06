// LiveWebSocketTransport
//
// Thin wrapper around URLSessionWebSocketTask that:
//   - opens the ws_url minted by /v1/ai/realtime-session, authenticating
//     with the minted OpenAI client secret as `Authorization: Bearer`
//     (the URL carries no credential)
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

/// Minimal async counting semaphore for single-slot FIFO serialization
/// of awaited calls. Declared at file scope so it can be referenced in
/// `LiveWebSocketTransport`'s stored properties without extra imports.
/// Not exported as public API — transport-internal use only.
///
/// NSLock is thread-synchronous (blocks), DispatchSemaphore doesn't
/// compose with `await`, and `actor` isolation doesn't by itself
/// serialize across suspension points. This covers the gap.
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.count = value
    }

    func wait() async {
        if count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            count += 1
        }
    }
}

@MainActor
protocol LiveTransporting: AnyObject {
    var inbound: AsyncThrowingStream<LiveInboundFrame, Error> { get }
    func open(url: URL, authToken: String) throws
    func close()
    func send(_ frame: LiveOutboundFrame) async throws
}

@MainActor
final class LiveWebSocketTransport: LiveTransporting {
    #if DEBUG
    /// Toggle for the per-event DEBUG log (event type + size, plus
    /// status and usage on `response.done`). Off by default because audio
    /// deltas fire ~10–50 lines/second during a turn. Flip to `true` when
    /// diagnosing wire-shape drift (e.g., token reporting breaking after
    /// an API change). Used by `handleInboundMessage` and gated via
    /// `#if DEBUG` so it's stripped from release builds entirely.
    static var verboseFrameLogging: Bool = false
    #endif

    /// Inbound frame stream. Consumers take this once at open time and
    /// iterate with `for try await`. The stream terminates on close or
    /// on an unrecoverable transport error.
    private(set) var inbound: AsyncThrowingStream<LiveInboundFrame, Error>
    private var inboundContinuation: AsyncThrowingStream<LiveInboundFrame, Error>.Continuation!

    private let urlSession: URLSession
    /// Whether `close()` should invalidate the URLSession. True when we
    /// constructed the session ourselves; false when a caller injected
    /// one (tests sharing a session across fixtures, future connection-
    /// pool reuse). Without this flag an injected shared session would
    /// be destroyed on every `close()` — a trap that the default-init
    /// path narrowly avoids today only because nobody shares yet.
    private let ownsSession: Bool
    private var wsTask: URLSessionWebSocketTask?
    #if DEBUG
    var testingMessageSender: ((URLSessionWebSocketTask.Message) async throws -> Void)?

    /// Install an unresumed socket so tests exercise the real send loop
    /// without a network connection. The injected sender owns each await.
    func _testInstallSocket(_ task: URLSessionWebSocketTask) {
        wsTask = task
    }
    #endif
    private var isClosed = false
    private var receiveLoopTask: Task<Void, Never>?
    /// P0-E (2026-04-23): periodic WebSocket ping task. Detects cellular
    /// TCP-head-of-line stalls that leave `receive()` blocked for
    /// minutes with no error (CLAUDE.md §sharp-edge #2). Without this,
    /// a frozen session only surfaces when `awaitTurnComplete` hits its
    /// 30s budget — from the transport's perspective the connection
    /// looks healthy the entire time.
    private var pingTask: Task<Void, Never>?
    /// Consecutive ping failures. Reset on every successful pong. After
    /// `pingFailuresBeforeDrop` in a row, we synthesize a
    /// `connectionDropped` error into the inbound stream so
    /// `handleTransportError` recovery fires with the right shape.
    private var consecutivePingFailures: Int = 0
    /// Ping cadence. 15s balances "catches a stall within ~30s worst
    /// case" against "doesn't swamp a healthy session with wake-ups."
    private static let pingIntervalSec: Double = 15
    /// Per-ping timeout — if the pong handler hasn't fired in this
    /// window, the ping is counted as failed. 10s is generous enough
    /// that normal network latency doesn't false-trigger while tight
    /// enough to keep the two-miss drop window at ~30s total.
    private static let pingTimeoutSec: Double = 10
    /// How many consecutive ping failures to tolerate before declaring
    /// the connection dropped. Two rules out single transient miss;
    /// three would stretch detection to ~45s which is past
    /// `awaitTurnComplete`'s budget.
    private static let pingFailuresBeforeDrop: Int = 2

    /// Serializes outbound sends across `await` suspensions. The
    /// `@MainActor` isolation alone doesn't help — each `await
    /// task.send(...)` suspends the actor, letting the next `send`
    /// callsite race into `URLSessionWebSocketTask.send` before the
    /// first one's string has been enqueued. Mic forwarding emits at
    /// 20 ms cadence, interleaving with toolResponse frames; under
    /// cellular stalls a slow `task.send` could let ordering invert.
    /// A single-slot AsyncSemaphore guarantees FIFO across callsites.
    private let sendLock = AsyncSemaphore(value: 1)

    /// Response gate. Realtime runs one response at a time and rejects a
    /// `response.create` sent while one is active
    /// (`conversation_already_has_active_response`). A tool result can be
    /// ready before the response that requested it has emitted
    /// `response.done` — local tools like `start_timer` finish in
    /// milliseconds — and a text injection can land while the model is
    /// speaking. Either would lose its `response.create` and leave the turn
    /// waiting for the stuck-turn watchdog. The transport therefore defers
    /// any `response.create` until the active response is done.
    ///
    /// State lives in `ResponseGate` (below) so it is unit-testable
    /// without a socket.
    private var responseGate = ResponseGate()
    private static let responseCreateMessage = #"{"type":"response.create"}"#

    /// Error bucket for typed transport failures. Transport-level errors
    /// are distinct from session-level errors (bad wire shape, protocol
    /// violations) so the session actor can decide between "fall back"
    /// and "retry on this connection" cleanly.
    enum TransportError: Error, Equatable, Sendable {
        /// The URL couldn't be opened at all (DNS, TLS, unreachable).
        /// Session actor → fall back to C.3.
        case openFailed(message: String)
        /// Connection closed by server unexpectedly.
        /// Session actor → attempt refresh; if that fails, fall back.
        case connectionDropped(code: Int, reason: String?)
        /// Inbound payload wasn't valid JSON or was binary (unexpected
        /// for the Realtime API — it's a JSON-over-WebSocket protocol).
        case malformedInbound(message: String)
        /// Caller tried to send after `close()`. Indicates a shutdown
        /// race on the session actor's side; logged at info, not an
        /// assertion failure (pre-empt doesn't crash in production).
        case sendAfterClose
    }

    /// The only host `ws_url` may point at.
    static let pinnedHost = "api.openai.com"

    /// Default-init creates and OWNS a URLSession — `close()` will
    /// invalidate it. Use `init(sharedSession:)` for tests that inject
    /// a session the caller continues to own.
    init() {
        self.urlSession = URLSession(configuration: .default)
        self.ownsSession = true
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: LiveInboundFrame.self,
            bufferingPolicy: .bufferingNewest(Self.inboundBufferMax),
        )
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    /// Test hook: accept a caller-owned URLSession. `close()` will NOT
    /// invalidate it, so the caller can reuse it across multiple
    /// transport instances. Not exercised in production paths.
    init(sharedSession: URLSession) {
        self.urlSession = sharedSession
        self.ownsSession = false
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: LiveInboundFrame.self,
            bufferingPolicy: .bufferingNewest(Self.inboundBufferMax),
        )
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    /// P3-I (2026-04-23): inbound frame stream buffer cap. Prior code
    /// used the default `.unbounded` policy; under MainActor stalls
    /// (long Core Data save, SwiftUI reconciliation spike) frames can
    /// queue without limit while the server streams audio deltas. OpenAI
    /// streams audio faster than real time, so a single response is a
    /// burst of many small deltas; the cap is sized so a ~1 s stall can't
    /// push the trailing `response.done` (usage + turnComplete) out of
    /// the buffer. A longer stall is unrecoverable regardless, so
    /// dropping oldest (`.bufferingNewest`) is strictly safer than OOM.
    /// By the time we hit this cap the session is already broken — the
    /// drop just prevents memory growth while we unwind.
    private static let inboundBufferMax: Int = 1000

    // MARK: - Lifecycle

    /// Open the WebSocket. Resolves when the task is `.connecting` —
    /// the `setupComplete` inbound frame is the real "ready" signal and
    /// the session actor awaits that explicitly (don't front-run the
    /// handshake from here).
    ///
    /// SECURITY: Validates scheme + host before opening. The client
    /// secret is sent as a bearer header to whatever host `ws_url` names;
    /// a compromised or MITM'd mint response could redirect it to an
    /// attacker endpoint. Pinning scheme=`wss` + host=`api.openai.com`
    /// prevents that silent exfiltration.
    func open(url: URL, authToken: String) throws {
        guard wsTask == nil else {
            Logger.voice.warning("live_ws_open_called_twice")
            return
        }
        guard !isClosed else {
            throw TransportError.sendAfterClose
        }
        guard url.scheme == "wss" else {
            throw TransportError.openFailed(message: "non-wss scheme rejected")
        }
        // Exact host pin — `hasSuffix("openai.com")` alone would allow
        // `evilopenai.com`. The Realtime WebSocket endpoint lives
        // exclusively on this host; no legitimate mint response should
        // point anywhere else.
        guard let host = url.host?.lowercased(),
              host == Self.pinnedHost else {
            throw TransportError.openFailed(message: "host not pinned to \(Self.pinnedHost)")
        }
        var request = URLRequest(url: url)
        // The client secret authenticates the socket. It is a header, not
        // a query param, so it can't leak through URL logging.
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let task = urlSession.webSocketTask(with: request)
        // Cap inbound message size so a malicious/misbehaving endpoint
        // can't OOM the device with an unbounded payload. 512 KiB is
        // well above the largest expected event (audio deltas are a few
        // tens of KiB) with headroom for `response.done` payloads.
        task.maximumMessageSize = 512 * 1024
        self.wsTask = task
        task.resume()
        startReceiveLoop()
        startPingTask()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        // P0-E (2026-04-23): stop the ping watchdog.
        pingTask?.cancel()
        pingTask = nil
        consecutivePingFailures = 0
        inboundContinuation?.finish()
        // Only invalidate sessions we own. Caller-injected sessions
        // are the caller's problem to release — invalidating here
        // would kill any other transports sharing the session.
        if ownsSession {
            urlSession.invalidateAndCancel()
        }
    }

    // MARK: - Send

    /// Send an outbound frame as JSON over the socket. A frame may expand
    /// to several wire messages (a tool result is a conversation item plus
    /// `response.create`); they are sent in order. Serializes via
    /// JSONSerialization (see LiveOutboundFrame for why we don't use
    /// JSONEncoder).
    func send(_ frame: LiveOutboundFrame) async throws {
        guard let task = wsTask, !isClosed else {
            throw TransportError.sendAfterClose
        }

        // If the frame is already a serialized JSON string
        // (`setupRawJSON`), skip the JSONSerialization encode/decode
        // round-trip entirely: the backend pre-serializes the setup frame,
        // and re-parsing 4-8 KiB on every preWarm + refresh for a
        // constant is pure cost.
        var messages: [String] = []
        if let raw = frame.asJSONString() {
            messages = [raw]
        } else {
            // `isValidJSONObject` is an O(n) full-graph walk. Audio fires
            // at ~40-50 Hz and builds `[String: String]` shapes that
            // cannot fail the check, so only the frame carrying a
            // caller-provided `[String: Any]` payload pays for it
            // (a Date/URL/NSNull could sneak into a session.update).
            // Tool outputs are validated inside the frame encoder.
            let needsValidityCheck: Bool = {
                switch frame {
                case .sessionUpdate:
                    return true
                case .realtimeInputAudio, .realtimeInputText, .toolResponse, .setupRawJSON:
                    return false
                }
            }()
            let objects = frame.asJSONObjects()
            guard !objects.isEmpty else {
                // Defensive — only reachable if a new LiveOutboundFrame
                // variant is added without updating the encoder.
                throw TransportError.malformedInbound(message: "outbound frame has no JSON representation")
            }
            for obj in objects {
                if needsValidityCheck {
                    guard JSONSerialization.isValidJSONObject(obj) else {
                        throw TransportError.malformedInbound(message: "outbound frame not JSON-encodable")
                    }
                }
                let data: Data
                do {
                    data = try JSONSerialization.data(withJSONObject: obj, options: [])
                } catch {
                    throw TransportError.malformedInbound(message: "encode failed")
                }
                // Text frames (stringified JSON) for the control channel.
                // Audio is still base64 inside that JSON — we never send
                // binary frames.
                guard let s = String(data: data, encoding: .utf8) else {
                    throw TransportError.malformedInbound(message: "utf8 conversion failed")
                }
                messages.append(s)
            }
        }

        // Serialize across concurrent callers. Without the semaphore,
        // an `await task.send(...)` that suspends during a cellular
        // stall lets the next send-callsite race into
        // URLSessionWebSocketTask.send — which documents FIFO only
        // within a single call, not across concurrent ones. Mic frames
        // at 20 ms cadence plus interleaved tool-result frames made
        // this a realistic ordering hazard. Messages of one frame are
        // sent sequentially so their relative order is preserved.
        for message in messages {
            guard !isClosed, wsTask === task, !Task.isCancelled else {
                throw TransportError.sendAfterClose
            }
            // Response gate: defer while a response is active or our last
            // create is unacknowledged.
            if message == Self.responseCreateMessage, !responseGate.requestCreate() {
                continue
            }
            await sendLock.wait()
            do {
                guard !isClosed, wsTask === task, !Task.isCancelled else {
                    throw TransportError.sendAfterClose
                }
                try await sendMessage(.string(message), over: task)
                await sendLock.signal()
            } catch {
                await sendLock.signal()
                throw error
            }
        }
    }

    private func sendMessage(
        _ message: URLSessionWebSocketTask.Message, over task: URLSessionWebSocketTask
    ) async throws {
        #if DEBUG
        if let testingMessageSender { try await testingMessageSender(message); return }
        #endif
        try await task.send(message)
    }

    // MARK: - Security helpers

    /// Redact client secrets from any string that may contain one. The
    /// secret rides in an `Authorization` header, which URLSession error
    /// descriptions don't normally echo, but a stray header dump or a
    /// pasted request description would carry it into Sentry breadcrumbs /
    /// OSLog / a D.1 transcript. Matches the `ek_...` secret itself and
    /// any `Bearer <value>`.
    ///
    /// The regex is pre-compiled once per process so error paths that call
    /// this repeatedly (every receiveLoop catch, every
    /// VoiceSessionLog.logError) don't pay the compile cost per call.
    static func scrubClientSecret(_ s: String) -> String {
        guard let regex = clientSecretRedactionRegex else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(
            in: s,
            options: [],
            range: range,
            withTemplate: "REDACTED",
        )
    }

    /// Pre-compiled regex for `scrubClientSecret`. nil only if Foundation
    /// somehow refuses the pattern (doesn't happen — it's a literal);
    /// scrub degrades to identity in that case, preserving the
    /// no-crash contract even on a theoretical compile failure.
    private static let clientSecretRedactionRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"ek_[A-Za-z0-9_\-]+|Bearer\s+[^\s"',;]+"#,
            options: [],
        )
    }()

    // MARK: - Keepalive

    /// Start a periodic `sendPing(pongReceiveHandler:)` loop. Each ping
    /// is wrapped in a per-call timeout — if the pong handler doesn't
    /// fire within `pingTimeoutSec`, we count the ping as failed. After
    /// `pingFailuresBeforeDrop` consecutive failures we synthesize a
    /// `connectionDropped` into the inbound stream so
    /// `handleTransportError` fires with the right shape.
    ///
    /// P0-E (2026-04-23): this is the primary defense against cellular
    /// TCP head-of-line stalls documented in CLAUDE.md §sharp-edge #2.
    /// Without it, a frozen session only surfaces at the
    /// `awaitTurnComplete` 30s budget — by which point the user has
    /// already perceived "stuck on Thinking."
    private func startPingTask() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            // Sleep first so the ping cadence doesn't race the setup
            // handshake. Setup completes in ~200-400ms normally; giving
            // it the first 15s free is cheap insurance.
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.pingIntervalSec))
                } catch {
                    return
                }
                guard let self else { return }
                let stillAlive = await self.sendPingWithTimeout()
                if !stillAlive { return }
            }
        }
    }

    /// Send one ping with a bounded timeout. Returns `true` if the ping
    /// loop should continue, `false` if we've synthesized a drop and
    /// there's no point pinging again.
    private func sendPingWithTimeout() async -> Bool {
        guard let task = wsTask, !isClosed else { return false }

        // Single-resume latch so a late pong + timeout don't both
        // resume the same continuation. NSLock-backed for cross-thread
        // safety — the pong handler fires on URLSession's delegate
        // queue, the timeout fires on a @MainActor Task.
        final class ResumeLatch: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            func tryResume() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let latch = ResumeLatch()

        let succeeded = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // Timeout guard
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.pingTimeoutSec))
                guard latch.tryResume() else { return }
                _ = self // keep self alive for the duration of the sleep
                cont.resume(returning: false)
            }
            task.sendPing { error in
                guard latch.tryResume() else { return }
                cont.resume(returning: error == nil)
            }
        }

        if succeeded {
            consecutivePingFailures = 0
            return true
        }

        consecutivePingFailures += 1
        Logger.voice.warning(
            "live_ws_ping_failed consecutive=\(self.consecutivePingFailures, privacy: .public) threshold=\(Self.pingFailuresBeforeDrop, privacy: .public)",
        )
        if consecutivePingFailures >= Self.pingFailuresBeforeDrop {
            Logger.voice.error(
                "live_ws_ping_dropped — synthesizing connectionDropped after \(self.consecutivePingFailures, privacy: .public) consecutive ping failures",
            )
            // Synthesize a drop into the inbound stream. The session
            // actor's receive dispatcher catches it via
            // `handleTransportError`, which (post P0-A) correctly
            // routes to refreshSession or .error recovery.
            inboundContinuation?.finish(
                throwing: TransportError.connectionDropped(code: -1001, reason: "ping_timeout"),
            )
            return false
        }
        return true
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
                //
                // SECURITY: strip any client secret from the reason
                // string so it can't flow into Sentry breadcrumbs /
                // OSLog if an error description ever echoes the request.
                let nsErr = error as NSError
                let scrubbedReason = Self.scrubClientSecret(nsErr.localizedDescription)
                // P2-B (2026-04-23): prepend a symbolic category to the
                // reason string so dashboards can bucket without parsing
                // localized-string contents. `offline | timeout | nccl |
                // cellular_denied | dns | ssl | other` covers the
                // observed failure classes; any un-categorized code
                // falls through to `other`. Category + raw code flow
                // together so ops can still drill into the specific
                // NSURLError number when needed.
                let category = Self.urlErrorCategory(nsErr.code)
                let annotated = "\(category):\(scrubbedReason)"
                Logger.voice.warning(
                    "live_ws_drop category=\(category, privacy: .public) code=\(nsErr.code, privacy: .public)",
                )
                inboundContinuation?.finish(
                    throwing: TransportError.connectionDropped(
                        code: nsErr.code,
                        reason: annotated,
                    ),
                )
                break
            }
        }
    }

    /// Translate raw `NSURLError` codes to short symbolic categories
    /// for ops dashboards. Called from the receive loop only; kept as a
    /// static string-returning helper so it's trivially testable without
    /// touching transport state. Specific codes are documented by Apple
    /// under `NSURLErrorDomain`.
    private static func urlErrorCategory(_ code: Int) -> String {
        switch code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff:
            return "offline"
        case NSURLErrorTimedOut:
            return "timeout"
        case NSURLErrorNetworkConnectionLost:
            return "nccl"
        case NSURLErrorCallIsActive:
            return "cellular_denied"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "dns"
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return "ssl"
        case NSURLErrorCancelled:
            return "cancelled"
        default:
            return "other"
        }
    }

    /// Feed the server's response lifecycle to the gate and send a
    /// deferred `response.create` once the active response ends.
    private func updateResponseGate(_ json: Any) async {
        guard let dict = json as? [String: Any], let type = dict["type"] as? String else { return }
        let errorCode = (dict["error"] as? [String: Any])?["code"] as? String
        guard responseGate.observe(eventType: type, errorCode: errorCode),
              let task = wsTask, !isClosed else { return }
        await sendLock.wait()
        do {
            guard !isClosed, wsTask === task, !Task.isCancelled else {
                throw TransportError.sendAfterClose
            }
            try await sendMessage(.string(Self.responseCreateMessage), over: task)
        } catch {
            responseGate.deferredCreateFailed()
            Logger.voice.warning(
                "live_deferred_response_create_failed error=\(error.localizedDescription, privacy: .private)",
            )
        }
        await sendLock.signal()
    }

    private func handleInboundMessage(_ message: URLSessionWebSocketTask.Message) async {
        let text: String
        switch message {
        case let .string(s):
            text = s
        case let .data(d):
            // Unexpected binary — the Realtime WebSocket is JSON-only.
            // Try UTF-8 decode as a best-effort; malformed binary
            // surfaces as a typed error the session actor logs then
            // drops.
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
                "live_ws_inbound_json_parse_failed error=\(error.localizedDescription, privacy: .private)",
            )
            return
        }

        #if DEBUG
        // Diagnostic: log every inbound event's type and size. On
        // `response.done` also log the status and the raw `usage` object
        // — if token counts look wrong downstream, this shows whether
        // the server sent them and under which keys. Response output
        // (transcript text) is deliberately not logged.
        if Self.verboseFrameLogging, let dict = json as? [String: Any] {
            VoiceSessionLog.log("ws.inbound", [
                "type": dict["type"] as? String ?? "nil",
                "size_bytes": data.count,
            ])
            if (dict["type"] as? String) == "response.done",
               let response = dict["response"] as? [String: Any] {
                var summary: [String: Any] = ["status": response["status"] as? String ?? "nil"]
                if let usage = response["usage"],
                   let usageData = try? JSONSerialization.data(
                       withJSONObject: usage, options: [.sortedKeys],
                   ),
                   let usageString = String(data: usageData, encoding: .utf8) {
                    summary["usage"] = usageString
                }
                VoiceSessionLog.log("ws.response_done", summary)
            }
        }
        #endif

        await updateResponseGate(json)

        let frames = LiveInboundFrame.parseAll(json)
        if frames.isEmpty {
            // Most server events (response.created, rate_limits.updated,
            // ...) are deliberately ignored; this is not an error.
            return
        }
        // One event can fan out to several frames (`response.done` →
        // usage + turnComplete). Yield each so the receive dispatcher
        // handles them in order.
        for frame in frames {
            inboundContinuation?.yield(frame)
        }
    }
}

/// One Realtime response at a time (see `LiveWebSocketTransport.responseGate`).
/// Pure state so the deferral rules are testable without a socket.
struct ResponseGate: Equatable {
    /// Between `response.created` and `response.done`.
    private(set) var inFlight = false
    /// A `response.create` was sent and neither `response.created` nor an
    /// `error` has arrived yet.
    private(set) var unacknowledged = false
    /// One deferred `response.create` to send at the next `response.done`.
    /// One is enough: a single response answers every item added since the
    /// last one.
    private(set) var pending = false

    /// Called before sending `response.create`. Returns true to send it now;
    /// false means it was deferred.
    mutating func requestCreate() -> Bool {
        if inFlight || unacknowledged {
            pending = true
            return false
        }
        unacknowledged = true
        return true
    }

    /// Called for every inbound event. Returns true when a deferred
    /// `response.create` must be sent now (it is then counted as sent).
    mutating func observe(eventType: String, errorCode: String?) -> Bool {
        switch eventType {
        case "response.created":
            inFlight = true
            unacknowledged = false
        case "response.done":
            inFlight = false
            if pending {
                pending = false
                unacknowledged = true
                return true
            }
        case "error":
            unacknowledged = false
            // Lost the race anyway: a response was already running.
            // Retry at the next `response.done`.
            if errorCode == "conversation_already_has_active_response" {
                inFlight = true
                pending = true
            }
        default:
            break
        }
        return false
    }

    /// The deferred send threw; nothing is awaiting acknowledgement.
    mutating func deferredCreateFailed() {
        unacknowledged = false
    }
}
