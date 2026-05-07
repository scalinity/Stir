// CameraService
//
// Thin AVFoundation wrapper around the back camera for the kitchen scan
// flow. iOS 17+, single-photo capture only. Multi-image is Pro-tier
// capability landing in step 7.
//
// Responsibilities:
//   - Permission probe + request (AVCaptureDevice.authorizationStatus).
//   - Capture session setup + teardown (MainActor — session lifecycle
//     is UI-adjacent).
//   - Single-photo capture → JPEG @ 0.85 quality, resized to max 1600px
//     long edge. Empirically ~200-400KB base64 payloads, comfortably
//     under the backend's 6MB decoded cap.
//
// Design notes:
//   - Uses AVCapturePhotoOutput on the main session; no custom pipelines.
//   - Exposes the raw AVCaptureSession so SwiftUI can build a preview
//     layer via UIViewRepresentable (standard pattern; the SwiftUI
//     CameraPreviewView lives in Features/Scan/).
//   - Permission denial is not exceptional — handled in ScanViewModel
//     by offering the bundled sample photo fallback.
//
// ASSUMPTION: back camera is the only sensor of interest for step 3.
// Front camera might surface in step 7 if recipe-screenshot OCR lands
// before the share extension path ships.

import AVFoundation
import CoreImage
import Foundation
import UIKit
import OSLog

@MainActor
final class CameraService: NSObject {
    enum PermissionState: Sendable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    enum CaptureError: Error, Sendable {
        case permissionDenied
        case cameraUnavailable
        case configurationFailed(String)
        case captureFailed(Error?)
        case imageProcessingFailed
    }

    private(set) var session: AVCaptureSession?
    private let sessionQueue = DispatchQueue(label: "com.scalinity.stir.camera", qos: .userInteractive)
    private var photoOutput: AVCapturePhotoOutput?

    // Captured-photo callback state (single in-flight capture only).
    private var captureContinuation: CheckedContinuation<Data, Error>?

    override init() {
        super.init()
    }

    // MARK: - Permission

    var currentPermission: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        @unknown default:    return .denied
        }
    }

    /// Prompt for permission if not yet determined. Returns the final state.
    func requestPermission() async -> PermissionState {
        switch currentPermission {
        case .authorized: return .authorized
        case .denied:     return .denied
        case .restricted: return .restricted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        }
    }

    // MARK: - Session lifecycle

    /// Start the capture session on the session queue. Idempotent — safe
    /// to call on every appear. Throws if permission is denied.
    func start() async throws {
        if currentPermission != .authorized {
            throw CaptureError.permissionDenied
        }

        if session == nil {
            try configureSession()
        }

        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                self?.session?.startRunning()
                cont.resume()
            }
        }
    }

    func stop() async {
        // Resolve any in-flight capture continuation first. Without this, a
        // mid-capture dismiss leaves `captureContinuation` set; the AVFoundation
        // photo delegate later resumes it against an orphaned Task, AND the
        // next capture attempt throws CaptureError.captureFailed because the
        // non-nil continuation blocks a new capture (CA2-2).
        if let continuation = captureContinuation {
            captureContinuation = nil
            continuation.resume(throwing: CaptureError.captureFailed(nil))
        }
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                self?.session?.stopRunning()
                cont.resume()
            }
        }
    }

    // MARK: - Capture

    /// Capture a single photo and return the AVFoundation-encoded JPEG
    /// bytes (full sensor resolution) as fast as possible. The caller
    /// is responsible for any resize / re-encode before AI submit —
    /// keeping that work out of the photo-output delegate is what lets
    /// the shutter-tap → still-on-screen latency stay under ~300ms.
    ///
    /// `flashMode` defaults to `.off`, which preserves the SCA-39
    /// instant-shutter invariant (no `.auto` metering pre-flash). The
    /// scan flow's user-facing flash toggle (SCA-47) overrides via
    /// `ScanFlashMode.avFlashMode` when the user has opted into `.on`
    /// or `.auto`; both arms accept the latency penalty in exchange
    /// for guaranteed exposure in dark pantries.
    func capturePhoto(flashMode: AVCaptureDevice.FlashMode = .off) async throws -> Data {
        guard let output = photoOutput else {
            throw CaptureError.configurationFailed("photoOutput missing")
        }
        if captureContinuation != nil {
            // Already capturing — rare with normal UI but guard against
            // double taps. Drop this one rather than racing continuations.
            throw CaptureError.captureFailed(nil)
        }

        let settings: AVCapturePhotoSettings
        if output.availablePhotoCodecTypes.contains(.jpeg) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        } else {
            settings = AVCapturePhotoSettings()
        }
        // SCA-39: kill shutter latency. .auto flash triggers a metering
        // pre-flash before the actual capture (~100-500 ms in mixed
        // kitchen lighting), and the default `.balanced` quality
        // prioritization waits for an N-frame burst to fuse via Smart
        // HDR / Deep Fusion (~100-300 ms). Combined, the press → shutter
        // gap was 300-700 ms — long enough that phone movement during
        // the click visibly skewed the captured frame. .off + .speed
        // brings it under ~150 ms with no fidelity hit on the kitchen-
        // scan pantry-parse pipeline. SCA-47 made flashMode a per-call
        // parameter (still defaulting .off) so the user-facing toggle
        // can opt into .on / .auto for dark pantries.
        settings.flashMode = flashMode
        settings.photoQualityPrioritization = .speed

        return try await withCheckedThrowingContinuation { continuation in
            self.captureContinuation = continuation
            self.sessionQueue.async {
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - Session configuration

    private func configureSession() throws {
        let captureSession = AVCaptureSession()
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.cameraUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.configurationFailed("input: \(error.localizedDescription)")
        }
        guard captureSession.canAddInput(input) else {
            throw CaptureError.configurationFailed("cannot add input")
        }
        captureSession.addInput(input)

        let output = AVCapturePhotoOutput()
        guard captureSession.canAddOutput(output) else {
            throw CaptureError.configurationFailed("cannot add photo output")
        }
        captureSession.addOutput(output)
        // SCA-39: cap the output's max prioritization at .speed so a
        // future per-shot settings tweak can't accidentally re-opt-in
        // to .balanced fusion processing. Per-shot
        // `photoQualityPrioritization` may not exceed this max.
        output.maxPhotoQualityPrioritization = .speed
        // SCA-40: pin portrait rotation so the captured photo's framing
        // matches the preview connection's framing. Without this, iOS
        // 17+ leaves the photo output's connection at the sensor-native
        // landscape angle while the preview layer auto-tracks portrait —
        // the two get out of sync and the captured image is shifted
        // horizontally relative to what the preview showed. Paired with
        // ScanCaptureView.CameraPreview.makeUIView — both connections
        // must stay pinned to the same angle.
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        captureSession.commitConfiguration()
        self.session = captureSession
        self.photoOutput = output
        Logger.camera.info("AVCaptureSession configured")
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraService: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?,
    ) {
        // Read the encoded JPEG synchronously here — `fileDataRepresentation`
        // is a memcpy of the buffer AVFoundation already encoded, no
        // pixel decode happens. Anything heavier (UIImage decode,
        // UIGraphicsImageRenderer resize, JPEG re-encode) used to live
        // here on the main actor and was the dominant cause of the
        // multi-second tap-to-still latency. Caller now does that work
        // off-main.
        let fullData = photo.fileDataRepresentation()
        let captureError = error

        Task { @MainActor in
            guard let continuation = self.captureContinuation else { return }
            self.captureContinuation = nil
            if let captureError {
                continuation.resume(throwing: CaptureError.captureFailed(captureError))
            } else if let fullData {
                continuation.resume(returning: fullData)
            } else {
                continuation.resume(throwing: CaptureError.imageProcessingFailed)
            }
        }
    }
}

// MARK: - ImageCompression

enum ImageCompression {
    enum ImageError: Error, Sendable {
        case resizeFailed
        case encodeFailed
    }

    /// Resize (if needed) + JPEG-encode. If the image is already below
    /// maxLongEdge, we still re-encode to apply the quality setting,
    /// which shaves bytes off a raw capture.
    static func jpeg(
        _ image: UIImage,
        maxLongEdge: CGFloat,
        quality: CGFloat,
    ) throws -> Data {
        let resized = resized(image, maxLongEdge: maxLongEdge)
        guard let data = resized.jpegData(compressionQuality: quality) else {
            throw ImageError.encodeFailed
        }
        return data
    }

    private static func resized(_ image: UIImage, maxLongEdge: CGFloat) -> UIImage {
        let longEdge = max(image.size.width, image.size.height)
        if longEdge <= maxLongEdge { return image }
        let scale = maxLongEdge / longEdge
        let newSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale,
        )
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - Logger

extension Logger {
    static let camera = Logger(subsystem: "com.scalinity.stir", category: "Camera")
}
