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

        audioEngine.inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: hwFormat,
        ) { [weak self] buffer, _ in
            // Tap callback runs on a real-time audio thread; we do the
            // convert + base64 synchronously here but yield onto the
            // MainActor-bound continuation via `Task`. Fast path: the
            // convert is cheap (a few KB); no allocations in the hot
            // loop beyond the output buffer and a base64 String.
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.processInputBuffer(buffer)
            }
        }

        if !audioEngine.isRunning {
            try audioEngine.start()
        }
        isMicRunning = true
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
            try? audioEngine.start()
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

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Output buffer capacity: target rate × buffer duration. We
        // overallocate slightly (2x) so the converter always has room
        // for rate-change rounding artifacts.
        let targetFrames = AVAudioFrameCount(
            Double(buffer.frameLength) * targetInputFormat.sampleRate / buffer.format.sampleRate,
        )
        let capacity = max(targetFrames * 2, 320)
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetInputFormat,
            frameCapacity: capacity,
        ) else {
            Logger.voice.warning("live_audio_out_buffer_alloc_failed")
            return
        }

        var inputDone = false
        let status = converter.convert(to: outBuffer, error: nil) { _, statusPtr in
            if inputDone {
                statusPtr.pointee = .endOfStream
                return nil
            }
            statusPtr.pointee = .haveData
            inputDone = true
            return buffer
        }

        guard status == .haveData || status == .inputRanDry else { return }
        guard let int16Ptr = outBuffer.int16ChannelData?[0] else { return }

        let byteCount = Int(outBuffer.frameLength) * 2
        let outData = Data(bytes: int16Ptr, count: byteCount)
        let base64 = outData.base64EncodedString()
        micContinuation?.yield(
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
