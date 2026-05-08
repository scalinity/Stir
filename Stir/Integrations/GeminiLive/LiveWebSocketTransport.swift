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
    func open(url: URL) throws
    func close()
    func send(_ frame: LiveOutboundFrame) async throws
}

@MainActor
final class LiveWebSocketTransport: LiveTransporting {
    #if DEBUG
    /// Toggle to log every inbound envelope's top-level keys + full
    /// JSON dump (audio base64 redacted) on turnComplete. Off by
    /// default because it fires ~1–5 lines/second during a turn. Flip
    /// to `true` when diagnosing Gemini wire-shape drift (e.g., token
    /// reporting breaking after a Gemini API change). Used by
    /// `handleInboundMessage` and gated via `#if DEBUG` so it's
    /// stripped from release builds entirely.
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
    /// queue without limit while Gemini fires ~50 Hz audio. A 500 ms
    /// MainActor stall queues ~75 frames; a longer stall is
    /// unrecoverable regardless, so dropping oldest newest-first
    /// (`.bufferingNewest`) is strictly safer than OOM. By the time we
    /// hit this cap the session is already broken — the drop just
    /// prevents memory growth while we unwind.
    private static let inboundBufferMax: Int = 200

    // MARK: - Lifecycle

    /// Open the WebSocket. Resolves when the task is `.connecting` —
    /// the `setupComplete` inbound frame is the real "ready" signal and
    /// the session actor awaits that explicitly (don't front-run the
    /// handshake from here).
    ///
    /// SECURITY: Validates scheme + host before opening. The URL
    /// carries the Gemini ephemeral token as `?access_token=...`; a
    /// compromised or MITM'd mint response could redirect it to an
    /// attacker endpoint. Pinning scheme=`wss` + host=`*.googleapis.com`
    /// prevents that silent exfiltration.
    func open(url: URL) throws {
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
        // Exact host pin — `hasSuffix("googleapis.com")` alone would
        // allow `evilgoogleapis.com`. The Gemini Live constrained
        // WebSocket endpoint lives exclusively on this host per the
        // mint's `WS_BASE` constant; no legitimate response should
        // point anywhere else.
        guard let host = url.host?.lowercased(),
              host == "generativelanguage.googleapis.com" else {
            throw TransportError.openFailed(message: "host not pinned to generativelanguage.googleapis.com")
        }
        var request = URLRequest(url: url)
        // Gemini Live's ephemeral-token path uses ?access_token=... in
        // the URL; no Authorization header. Attaching one causes a 401
        // in practice (pinned here so nobody "fixes" it by adding one).
        request.timeoutInterval = 10
        let task = urlSession.webSocketTask(with: request)
        // Cap inbound message size so a malicious/misbehaving endpoint
        // can't OOM the device with an unbounded payload. 512 KiB is
        // well above the largest observed Gemini frame (~30 KiB audio
        // chunks) with headroom for batched usageMetadata blocks.
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

    /// Send an outbound frame as JSON over the socket. Serializes via
    /// JSONSerialization (see LiveOutboundFrame for why we don't use
    /// JSONEncoder).
    func send(_ frame: LiveOutboundFrame) async throws {
        guard let task = wsTask, !isClosed else {
            throw TransportError.sendAfterClose
        }

        // P3-D (2026-04-23): if the frame is already a serialized JSON
        // string (`setupRawJSON`), skip the JSONSerialization encode/
        // decode round-trip entirely. Backend pre-serializes the setup
        // frame; iOS was paying ~4-8 KiB × 3 passes (parse → wrap →
        // re-serialize → stringify) every preWarm + every refresh for
        // a constant. Now: one string send.
        let str: String
        if let raw = frame.asJSONString() {
            str = raw
        } else {
            guard let obj = frame.asJSONObject() else {
                // Defensive — only reachable if a new LiveOutboundFrame
                // variant is added without updating either helper.
                throw TransportError.malformedInbound(message: "outbound frame has no JSON representation")
            }
            // P3-E (2026-04-23): `isValidJSONObject` pre-flight is
            // skipped for statically-shaped frame variants
            // (realtimeInputAudio / realtimeInputText) — those
            // construct `[String: String]` dictionaries whose types
            // are Bridged-Foundation strings and cannot fail the
            // validity check. Audio fires at 50 Hz during a turn and
            // `isValidJSONObject` is an O(n) full-graph walk — paying
            // it per-frame for a guaranteed-valid shape is pure cost.
            // Untyped `toolResponse` / `sessionUpdate` payloads still
            // get the pre-flight because they carry caller-provided
            // `[String: Any]` where a Date/URL/NSNull could sneak in.
            let needsValidityCheck: Bool = {
                switch frame {
                case .realtimeInputAudio, .realtimeInputText, .setup:
                    return false
                case .setupRawJSON:
                    return false  // already handled above; defensive
                case .toolResponse, .sessionUpdate:
                    return true
                }
            }()
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
            // Gemini Live accepts text frames (stringified JSON) for the
            // control channel. Audio is still base64 inside that JSON — we
            // never send binary frames.
            guard let s = String(data: data, encoding: .utf8) else {
                throw TransportError.malformedInbound(message: "utf8 conversion failed")
            }
            str = s
        }

        // Serialize across concurrent callers. Without the semaphore,
        // an `await task.send(...)` that suspends during a cellular
        // stall lets the next send-callsite race into
        // URLSessionWebSocketTask.send — which documents FIFO only
        // within a single call, not across concurrent ones. Mic frames
        // at 20 ms cadence plus interleaved toolResponse frames made
        // this a realistic ordering hazard.
        await sendLock.wait()
        do {
            try await task.send(.string(str))
            await sendLock.signal()
        } catch {
            await sendLock.signal()
            throw error
        }
    }

    // MARK: - Security helpers

    /// Redact the `access_token=...` query-param value from any string
    /// that may contain the Gemini ephemeral token. Used before logging
    /// or surfacing error descriptions that URLSession constructed from
    /// the request URL.
    ///
    /// P3-J (2026-04-23): regex is pre-compiled once per process so
    /// error paths that call this repeatedly (every receiveLoop catch,
    /// every VoiceSessionLog.logError that carries a URL) don't pay
    /// the compile cost per call.
    static func scrubAccessToken(_ s: String) -> String {
        guard let regex = accessTokenRedactionRegex else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(
            in: s,
            options: [],
            range: range,
            withTemplate: "access_token=REDACTED",
        )
    }

    /// Pre-compiled regex for `scrubAccessToken`. nil only if Foundation
    /// somehow refuses the pattern (doesn't happen — it's a literal);
    /// scrub degrades to identity in that case, preserving the
    /// no-crash contract even on a theoretical compile failure.
    private static let accessTokenRedactionRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"access_token=[^&\s"]+"#,
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
                // SECURITY: strip `access_token=...` from the reason
                // string — the ephemeral Gemini token rides in the
                // URL query param and URLError.localizedDescription
                // sometimes embeds the failing URL. We don't want the
                // token flowing into Sentry breadcrumbs / OSLog.
                let nsErr = error as NSError
                let scrubbedReason = Self.scrubAccessToken(nsErr.localizedDescription)
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
                "live_ws_inbound_json_parse_failed error=\(error.localizedDescription, privacy: .private)",
            )
            return
        }

        #if DEBUG
        // Diagnostic: dump every inbound envelope's top-level keys. If
        // `usageMetadata` never appears in this stream, Gemini isn't
        // emitting it (fix lives server-side or in setup config, not in
        // parseAll). If it appears but under a different key, we see
        // that key here. Kept DEBUG-only because the log volume is
        // ~1–5 lines per second during an active turn.
        if let dict = json as? [String: Any] {
            let keys = Array(dict.keys).sorted().joined(separator: ",")
            VoiceSessionLog.log("ws.inbound_keys", [
                "keys": keys,
                "size_bytes": data.count,
            ])
            // Extra: on turnComplete, dump the FULL envelope (audio base64
            // redacted) so we can see exactly what Gemini sends at the
            // token-accounting boundary. This is the envelope where
            // usageMetadata should appear — if it's not at top level,
            // seeing the full shape tells us where it actually lives.
            if let serverContent = dict["serverContent"] as? [String: Any],
               (serverContent["turnComplete"] as? Bool) == true {
                let redacted = redactAudioBase64(dict)
                if let data = try? JSONSerialization.data(
                    withJSONObject: redacted, options: [.sortedKeys],
                ), let str = String(data: data, encoding: .utf8) {
                    VoiceSessionLog.log("ws.turnComplete_envelope", ["json": str])
                }
            }
        }
        #endif

        let frames = LiveInboundFrame.parseAll(json)
        if frames.isEmpty {
            Logger.voice.debug("live_ws_inbound_unparsed_shape")
            return
        }
        // One Gemini Live envelope can carry multiple top-level frames
        // (e.g., `{serverContent, usageMetadata}` on turn-complete). Yield
        // each so the receive dispatcher handles them in order.
        for frame in frames {
            inboundContinuation?.yield(frame)
        }
    }

    #if DEBUG
    /// Recursively replaces `inlineData.data` base64 strings with a
    /// `<audio_NN_bytes>` placeholder so we can log envelope shapes
    /// without flooding the console with megabytes of base64 PCM.
    /// Used by the diagnostic `ws.turnComplete_envelope` log.
    private func redactAudioBase64(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if k == "data",
                   let s = v as? String,
                   s.count > 1000 {
                    out[k] = "<base64_\(s.count)_chars>"
                } else {
                    out[k] = redactAudioBase64(v)
                }
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { redactAudioBase64($0) }
        }
        return value
    }
    #endif
}
