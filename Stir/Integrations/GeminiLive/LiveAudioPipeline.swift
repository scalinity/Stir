// LiveAudioPipeline
//
// Half-duplex audio I/O for the Gemini Live WebSocket session.
//
// Mic capture (PCM16 @ 16 kHz, base64 in `realtimeInput.audio`):
//   - AVAudioEngine input node tap → AVAudioConverter → 16 kHz mono
//     PCM16 Data chunks → base64 string → pushed via an AsyncStream
//     that the session actor reads and forwards over the WebSocket
//
// Playback (PCM16 @ 24 kHz from `serverContent.modelTurn.parts[].inlineData`):
//   - Base64-decoded audio is queued to AVAudioPlayerNode
//   - Each chunk is scheduled as an AVAudioPCMBuffer; node plays on a
//     shared AVAudioEngine
//   - Callers can `cancelPlayback()` to stop the queue immediately
//     (returns when the node transitions to stopped)
//
// CLAUDE.md §sharp-edge #10 pins the input rate at 16 kHz. Output is
// 24 kHz per Gemini docs (not settable; we match whatever the mime
// type says). If rate doesn't match inline_data's mime, we trust the
// mime and reformat on the fly — safer than hardcoding one side.
//
// Why half-duplex: 3.1 Flash Live doesn't emit audio-based barge-in
// signals the way gpt-realtime does. Stir's UX is tap-to-speak; the
// mic is OFF while the model is speaking (state machine enforces
// .modelSpeaking → .ready before .userSpeaking). Building full-duplex
// barge-in here would be wasted plumbing.

import AVFoundation
import Foundation
import OSLog

@MainActor
final class LiveAudioPipeline {
    /// Stream of base64-encoded PCM16 @ 16 kHz mic frames. The session
    /// actor reads this and forwards to the WebSocket as
    /// `realtimeInput.audio`. ~20 ms per frame (640 samples × 2 bytes).
    private(set) var micFrames: AsyncStream<LiveAudioPipeline.MicFrame>!
    private var micContinuation: AsyncStream<MicFrame>.Continuation!

    struct MicFrame: Sendable {
        let base64: String
        /// Always "audio/pcm;rate=16000" for outbound mic frames.
        let mimeType: String
    }

    // MARK: - AudioEngine graph

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()

    /// Format native to the mic hardware — varies by device. Converted
    /// to 16 kHz mono PCM16 via AVAudioConverter before we base64.
    private var hardwareInputFormat: AVAudioFormat?

    /// Target format for Gemini Live audio input. MUST match the mime
    /// type we declare on outbound audio frames.
    private let targetInputFormat: AVAudioFormat = {
        // Int16 linear PCM, mono, 16 kHz. .pcmFormatInt16 is signed.
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true,
        )
        // Force-unwrap: these constants are known-valid on iOS 17+.
        return fmt!
    }()

    private var converter: AVAudioConverter?
    private var isMicRunning = false

    // MARK: - Init

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: MicFrame.self)
        self.micFrames = stream
        self.micContinuation = continuation

        audioEngine.attach(playerNode)
    }

    // MARK: - Mic lifecycle

    /// Begin capturing mic audio. Caller must have already activated
    /// AVAudioSession (see AVAudioSessionConfigurator.activateForCookMode)
    /// and received mic permission. Pre-warm path: call once per
    /// session; start/stop cycles via `startCapture`/`stopCapture`.
    func prepare() throws {
        // Snapshot the hardware input format once — installing a tap
        // requires a concrete format, and the input format can only be
        // read after the engine is prepared.
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw PipelineError.noInputDevice
        }
        self.hardwareInputFormat = hwFormat

        // Converter must accept the hardware format in and produce our
        // 16 kHz target format. AVAudioConverter handles rate-change +
        // channel-mix + format-coerce all at once.
        guard let conv = AVAudioConverter(from: hwFormat, to: targetInputFormat) else {
            throw PipelineError.converterCreateFailed
        }
        self.converter = conv

        // Player node attaches to output; connect with nil format lets
        // the engine pick the output's native format (typically 48 kHz
        // stereo). AVAudioPlayerNode handles the resample internally
        // when we schedule buffers with a different format.
        audioEngine.connect(
            playerNode,
            to: audioEngine.mainMixerNode,
            format: nil,
        )
    }

    /// Start the mic tap + engine. Idempotent — safe to call after stop.
    func startCapture() throws {
        guard !isMicRunning else { return }
        guard let hwFormat = hardwareInputFormat else {
            throw PipelineError.notPrepared
        }
        // 20 ms buffer = reasonable tradeoff. Shorter = more frames +
        // overhead; longer = more perceptible talk-to-send lag.
        let bufferSize: AVAudioFrameCount = AVAudioFrameCount(hwFormat.sampleRate * 0.02)

        Logger.voice.info(
            "mic_tap_installing rate=\(hwFormat.sampleRate, privacy: .public) channels=\(hwFormat.channelCount, privacy: .public) buffer=\(bufferSize, privacy: .public)",
        )

        // Counters shared with the tap callback — these MUST be class
        // storage (not closure-local) so the callback can mutate them
        // across invocations. Wrapped in a tiny helper class rather
        // than globals so the state is cleared on every startCapture.
        let counter = TapCallCounter()

        // Capture the dependencies by value so the tap callback
        // doesn't need to touch @MainActor-isolated self at all.
        // Converter is documented safe for serialized access; we only
        // ever run it from a single audio thread.
        guard let converter = self.converter else {
            throw PipelineError.notPrepared
        }
        let target = self.targetInputFormat
        let continuation = self.micContinuation

        audioEngine.inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: hwFormat,
        ) { buffer, _ in
            // Process synchronously on the audio thread. Earlier draft
            // hopped to the MainActor via `Task { @MainActor ... }` —
            // under load (and on iOS 26 with main thread doing SwiftUI
            // reconciliation) those Tasks apparently queued and never
            // ran, producing zero mic frames over 23 s of active speech
            // (observed 2026-04-22). AsyncStream.Continuation.yield is
            // documented thread-safe, AVAudioConverter is safe for
            // serialized access from a single thread, so there's no
            // reason to hop to the main actor.
            //
            // buffer is valid only for the duration of this callback.
            // All reads + the copy-into-Data happen synchronously here
            // so nothing leaks out to stale memory.
            counter.total &+= 1
            let fl = buffer.frameLength
            if fl == 0 {
                if counter.total % 50 == 0 {
                    Logger.voice.warning(
                        "mic_tap_zero_length count=\(counter.total, privacy: .public)",
                    )
                }
                return
            }
            // Sample peak amplitude — tells us whether real speech is
            // arriving (peak > ~0.01) vs dead silence (peak ~0).
            var peak: Float = 0
            if let ch = buffer.floatChannelData?[0] {
                let n = Int(fl)
                for i in 0..<n {
                    let a = abs(ch[i])
                    if a > peak { peak = a }
                }
            }
            if counter.total == 1 || counter.total % 50 == 0 {
                Logger.voice.info(
                    "mic_tap_fired count=\(counter.total, privacy: .public) frames=\(fl, privacy: .public) peak=\(peak, privacy: .public)",
                )
            }
            Self.convertAndYield(
                buffer,
                converter: converter,
                target: target,
                continuation: continuation,
            )
        }

        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        isMicRunning = true
        Logger.voice.info(
            "mic_tap_installed engine_running=\(self.audioEngine.isRunning, privacy: .public)",
        )
    }

    /// Tiny class so the audio-thread tap callback can mutate a
    /// counter across invocations without capturing the whole pipeline
    /// by reference just for the int.
    private final class TapCallCounter: @unchecked Sendable {
        var total: UInt64 = 0
    }

    /// Stop the mic tap. Engine stays alive so playback can continue;
    /// if the whole pipeline needs to go down, call `tearDown()`.
    func stopCapture() {
        guard isMicRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        isMicRunning = false
    }

    // MARK: - Playback

    /// Schedule a base64-encoded audio chunk to play. Gemini Live
    /// emits these in `serverContent.modelTurn.parts[].inlineData`
    /// with `mimeType: audio/pcm;rate=<N>`. We parse the rate and
    /// feed the player at that rate.
    func enqueuePlayback(_ chunk: LiveAudioChunk) throws {
        guard let data = Data(base64Encoded: chunk.base64) else {
            throw PipelineError.malformedAudioChunk(reason: "not base64")
        }
        let sampleRate = parseSampleRate(from: chunk.mimeType) ?? 24000

        // Gemini's audio is Int16 mono PCM. Build a PCMBuffer from the
        // raw Int16 samples.
        guard let bufferFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: true,
        ) else {
            throw PipelineError.malformedAudioChunk(reason: "can't build AVAudioFormat at \(sampleRate) Hz")
        }

        let frameCount = AVAudioFrameCount(data.count / 2)  // 2 bytes per Int16 sample
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: bufferFormat, frameCapacity: frameCount)
        else {
            throw PipelineError.malformedAudioChunk(reason: "empty buffer")
        }
        pcmBuffer.frameLength = frameCount

        // Copy the raw Int16 bytes into the buffer's Int16ChannelData.
        data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress, let dst = pcmBuffer.int16ChannelData?[0] else {
                return
            }
            memcpy(dst, src, data.count)
        }

        if !audioEngine.isRunning {
            // Only starts if startCapture or tearDown left it stopped.
            // Propagate errors instead of `try?`-swallowing — a silent
            // engine-start failure produces "Gemini speaking, user
            // hears nothing" with no signal for triage. enqueuePlayback
            // already declares `throws`; `handleServerContent` logs
            // the failure via `live_playback_enqueue_failed`.
            do {
                try audioEngine.start()
            } catch {
                Logger.voice.error(
                    "live_audio_engine_start_failed error=\(error.localizedDescription, privacy: .private)",
                )
                throw PipelineError.malformedAudioChunk(reason: "engine start failed: \(error.localizedDescription)")
            }
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    /// Immediately stop playback and flush any queued buffers. Returns
    /// once the player transitions to stopped (the `.stop` call is
    /// synchronous on AVAudioPlayerNode; playback-complete delegates
    /// don't apply).
    func cancelPlayback() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        playerNode.reset()
    }

    // MARK: - Teardown

    func tearDown() {
        stopCapture()
        cancelPlayback()
        audioEngine.stop()
        micContinuation?.finish()
    }

    // MARK: - Internals

    /// Convert the audio-thread-provided buffer and yield a MicFrame.
    /// `nonisolated` so it can run on the audio thread without a
    /// MainActor hop; all parameters are thread-safe:
    /// - AVAudioConverter: documented safe for serialized access
    ///   from one thread (we only ever run it from the audio thread).
    /// - AVAudioFormat: immutable value-type metadata.
    /// - AsyncStream<MicFrame>.Continuation: `yield` is thread-safe
    ///   per Swift Concurrency docs.
    nonisolated private static func convertAndYield(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat,
        continuation: AsyncStream<MicFrame>.Continuation?,
    ) {
        // Output buffer capacity: target rate × buffer duration. We
        // overallocate slightly (2x) so the converter always has room
        // for rate-change rounding artifacts.
        let targetFrames = AVAudioFrameCount(
            Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate,
        )
        let capacity = max(targetFrames * 2, 320)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: capacity,
        ) else {
            Logger.voice.warning("live_audio_out_buffer_alloc_failed")
            return
        }

        var inputDone = false
        let status = converter.convert(to: outBuffer, error: nil) { _, statusPtr in
            if inputDone {
                // `.noDataNow` = "I'm out of input for THIS convert
                // call; you may call me again later." This keeps the
                // converter alive across tap callbacks.
                //
                // DO NOT use `.endOfStream` here: that tells the
                // converter the whole stream is done, and it
                // persistently returns `.endOfStream` for every
                // subsequent `convert()` call — zero output for the
                // rest of the session. Observed 2026-04-22: hundreds
                // of `live_audio_convert_unexpected_status status=2`
                // warnings across 18 s of real speech, zero MicFrames
                // yielded, zero audio reached Gemini.
                statusPtr.pointee = .noDataNow
                return nil
            }
            statusPtr.pointee = .haveData
            inputDone = true
            return buffer
        }

        // Status interpretation:
        //   .haveData     → output buffer is full or has enough for now
        //   .inputRanDry  → output buffer not full but converter consumed
        //                   all our input; whatever's in outBuffer is valid
        //   .endOfStream  → shouldn't happen with `.noDataNow`, but tolerate
        //   .error        → log and drop this frame
        // In all non-error cases, trust `outBuffer.frameLength` as the
        // ground truth for how much valid output we have.
        if status == .error {
            Logger.voice.warning("live_audio_convert_error")
            return
        }
        guard outBuffer.frameLength > 0 else { return }
        guard let int16Ptr = outBuffer.int16ChannelData?[0] else {
            Logger.voice.warning("live_audio_convert_no_int16_data")
            return
        }

        let byteCount = Int(outBuffer.frameLength) * 2
        let outData = Data(bytes: int16Ptr, count: byteCount)
        let base64 = outData.base64EncodedString()
        continuation?.yield(
            MicFrame(base64: base64, mimeType: "audio/pcm;rate=16000"),
        )
    }

    /// Parse `audio/pcm;rate=24000` → 24000. Default to 24000 on miss.
    private func parseSampleRate(from mime: String) -> Int? {
        let lower = mime.lowercased()
        guard let range = lower.range(of: "rate=") else { return nil }
        let rest = lower[range.upperBound...]
        let digits = rest.prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Errors

    enum PipelineError: Error, Equatable, Sendable {
        case notPrepared
        case noInputDevice
        case converterCreateFailed
        case malformedAudioChunk(reason: String)
    }
}
