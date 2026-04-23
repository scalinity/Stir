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
import os
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

    /// Linear gain factor applied to Gemini Live audio output before it
    /// hits the player node. 2.0 == +6 dB, perceptually "twice as loud".
    /// Rationale: `AVAudioSession.mode = .voiceChat` applies voice-
    /// processing AGC tuned for phone-to-ear distance. With the phone
    /// sitting on a counter 0.5-1 m from the user, unity-gain output is
    /// hard to hear over ambient kitchen noise (observed 2026-04-23).
    /// We pre-amplify in the sample domain and hard-clamp to [-1, 1] so
    /// any rare over-range samples get clipped rather than wrapped.
    /// Tuning bound: 2.0 is a safe ceiling — speech rarely sustains at
    /// peak, so clipping should be negligible. Above ~3.0 we'd hear
    /// audible distortion on loud consonants.
    private static let playbackGain: Float = 2.0

    /// Count of scheduled-but-not-yet-rendered audio buffers. Incremented
    /// synchronously in `enqueuePlayback` before `scheduleBuffer`, and
    /// decremented in the `.dataPlayedBack` completion callback when the
    /// output device has rendered the audio.
    ///
    /// DO NOT use `playerNode.isPlaying` as a "still speaking" signal —
    /// `isPlaying` reflects whether `play()` has been called without a
    /// matching `stop()`, NOT whether audio is currently rendering. Once
    /// `play()` is called on the first buffer, `isPlaying` stays true
    /// forever (observed 2026-04-22: mic stayed muted for 40+ s after
    /// the model finished speaking because `isPlaying=true` never cleared).
    ///
    /// `OSAllocatedUnfairLock` because the decrement runs on an
    /// AVFoundation-internal thread (the audio render thread calls the
    /// completion handler asynchronously), while the increment runs on
    /// `@MainActor`.
    private let pendingPlaybackBuffers = OSAllocatedUnfairLock(initialState: 0)

    /// Is the output device currently rendering model audio? True iff
    /// at least one scheduled buffer hasn't hit its `.dataPlayedBack`
    /// completion yet. Accurate proxy for "speaker is emitting sound".
    var isPlayingBack: Bool {
        pendingPlaybackBuffers.withLock { $0 > 0 }
    }

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

    /// Stable format the playerNode is connected with AND every
    /// scheduled buffer must use. Mono Float32 at 24 kHz matches
    /// Gemini Live's documented output (`audio/pcm;rate=24000`, mono),
    /// and AVAudioPlayerNode auto-resamples + auto-mixes to the
    /// hardware output format via the mainMixer stage — so we only
    /// need to pin the *input* side of the node.
    ///
    /// Earlier draft connected with `format: nil`, which inherited the
    /// mainMixer's native format (stereo Float32 at 48 kHz on real
    /// devices). Scheduling a mono Int16 buffer on a stereo-formatted
    /// node triggers an NSException at scheduleBuffer:
    ///   "required condition is false:
    ///    _outputFormat.channelCount == buffer.format.channelCount"
    /// Observed 2026-04-22 as a fatal crash on the first model audio
    /// chunk.
    private let playerFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24000,
            channels: 1,
            interleaved: false,
        )!
    }()

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
        // AEC is provided by `AVAudioSession.mode = .videoChat` (see
        // AVAudioSessionConfigurator). Do NOT also call
        // `inputNode.setVoiceProcessingEnabled(true)` — the two paths
        // are the same underlying Voice Processing IO unit, and
        // double-enabling produced a silent-tap failure on iPhone
        // 2026-04-22: `mic_tap_installed engine_running=true` appeared
        // in the log, but the tap callback never fired over 7s of
        // live speech. Session mode alone gives us AEC; the Voice
        // Processing IO unit activates once, driven by the session
        // configuration, and the tap fires normally.
        //
        // Mode is `.videoChat` (not `.voiceChat`) because `.voiceChat`
        // produced telephony-style output routing even with
        // `.defaultToSpeaker` set (observed 2026-04-23). Both modes
        // engage the same Voice Processing IO unit, so AEC is
        // unchanged; `.videoChat` just routes to the speaker by
        // default and uses a flatter frequency response.
        //
        // If AEC quality proves insufficient in D.1 validation,
        // consider switching to `setVoiceProcessingEnabled(true)` AND
        // `mode = .default` (engine-driven VP), not both.

        // Pin playerNode → mainMixer with our own `playerFormat` so
        // every scheduled buffer matches. See `playerFormat` doc
        // comment for the crash that motivated this.
        audioEngine.connect(
            playerNode,
            to: audioEngine.mainMixerNode,
            format: playerFormat,
        )

        // Input format + converter are captured at tap-install time
        // in `startCapture`, NOT here — the inputNode's format can
        // change between prepare and start once the AVAudioSession is
        // fully negotiated, so snapshotting it early risks a tap/
        // converter that doesn't match what the engine is actually
        // producing. Keep `prepare()` structural only.
    }

    /// Start the mic tap + engine. Idempotent — safe to call after stop.
    func startCapture() throws {
        guard !isMicRunning else { return }

        // Capture the inputNode's CURRENT output format here, not at
        // prepare() time. Reason: AVAudioSession negotiation (voiceChat
        // mode + Voice Processing IO unit activation) can shift the
        // inputNode's output format between `prepare` and `start`. A
        // stale format passed to installTap produces a tap that installs
        // successfully but never fires its callback — the exact silent
        // failure observed 2026-04-22 on iPhone (mic_tap_installed with
        // engine_running=true, then zero tap callbacks over 7 s of
        // live speech). Re-query here so the tap + converter match
        // whatever the engine is actually producing.
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw PipelineError.noInputDevice
        }
        self.hardwareInputFormat = hwFormat

        guard let converter = AVAudioConverter(from: hwFormat, to: targetInputFormat) else {
            throw PipelineError.converterCreateFailed
        }
        self.converter = converter

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
        let target = self.targetInputFormat
        let continuation = self.micContinuation

        inputNode.installTap(
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
        // Format + converter are captured per-startCapture (AVAudioSession
        // renegotiation between start/stop cycles can shift the input
        // format). Clear them on stop so a subsequent read of `converter`
        // outside startCapture can never use a stale reference.
        hardwareInputFormat = nil
        converter = nil
    }

    // MARK: - Playback

    /// Schedule a base64-encoded audio chunk to play. Gemini Live
    /// emits these in `serverContent.modelTurn.parts[].inlineData`
    /// with `mimeType: audio/pcm;rate=<N>` — documented as mono Int16
    /// at 24 kHz.
    ///
    /// Scheduled buffer MUST match the format that `playerNode` was
    /// connected with (see `playerFormat` — mono Float32 24 kHz).
    /// We convert Int16 samples to Float32 in [-1, 1] on the fly;
    /// AVAudioPlayerNode auto-resamples + auto-mixes to the hardware
    /// output channel layout via the mainMixer stage.
    func enqueuePlayback(_ chunk: LiveAudioChunk) throws {
        guard let data = Data(base64Encoded: chunk.base64) else {
            throw PipelineError.malformedAudioChunk(reason: "not base64")
        }
        let incomingRate = parseSampleRate(from: chunk.mimeType) ?? 24000
        if Int(playerFormat.sampleRate) != incomingRate {
            // Gemini hasn't shipped a non-24kHz chunk in testing, but
            // guard for the day it does: logging here means we'll see
            // the drift before users do. Playing it at our fixed
            // `playerFormat` rate would make speech sound pitched.
            Logger.voice.warning(
                "live_playback_rate_mismatch incoming=\(incomingRate, privacy: .public) expected=\(Int(self.playerFormat.sampleRate), privacy: .public)",
            )
        }

        // 2 bytes per Int16 sample; frame count is sample count (mono).
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount)
        else {
            throw PipelineError.malformedAudioChunk(reason: "empty buffer")
        }
        pcmBuffer.frameLength = frameCount

        // Convert Int16 [-32768, 32767] → Float32 [-1, 1] directly
        // into the buffer's Float32ChannelData. Division by 32768.0
        // matches Apple's documented normalization factor. Multiply by
        // `playbackGain` (see docstring) to overcome .voiceChat mode's
        // tightened output level; hard-clamp to [-1, 1] so any rare
        // over-range samples clip cleanly instead of wrapping.
        data.withUnsafeBytes { rawPtr in
            guard let int16Src = rawPtr.bindMemory(to: Int16.self).baseAddress,
                  let floatDst = pcmBuffer.floatChannelData?[0]
            else { return }
            let n = Int(frameCount)
            let gain = Self.playbackGain
            for i in 0..<n {
                let gained = (Float(int16Src[i]) / 32768.0) * gain
                floatDst[i] = max(-1.0, min(1.0, gained))
            }
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
        // Increment BEFORE scheduling so the gate correctly reflects
        // "at least one buffer is outstanding" even if the completion
        // handler fires almost immediately. Decrement in the
        // `.dataPlayedBack` completion (fires after the output device
        // has rendered the audio).
        pendingPlaybackBuffers.withLock { $0 += 1 }
        playerNode.scheduleBuffer(
            pcmBuffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack,
        ) { [pendingPlaybackBuffers] _ in
            pendingPlaybackBuffers.withLock { $0 = max(0, $0 - 1) }
        }
    }

    /// Immediately stop playback and flush any queued buffers. Returns
    /// once the player transitions to stopped (the `.stop` call is
    /// synchronous on AVAudioPlayerNode; playback-complete delegates
    /// don't apply).
    ///
    /// Resets the pending-buffer counter because `playerNode.reset()`
    /// drops scheduled buffers without firing their completion handlers
    /// — without this reset, the counter would stay stuck at N and
    /// `isPlayingBack` would permanently report true.
    func cancelPlayback() {
        if playerNode.isPlaying {
            playerNode.stop()
        }
        playerNode.reset()
        pendingPlaybackBuffers.withLock { $0 = 0 }
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
