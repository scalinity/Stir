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
        await withCheckedContinuation { cont in
            sessionQueue.async { [weak self] in
                self?.session?.stopRunning()
                cont.resume()
            }
        }
    }

    // MARK: - Capture

    /// Capture a single photo, return JPEG-compressed Data resized to the
    /// pantry-parse payload budget (max 1600px long edge, q=0.85).
    func capturePhoto() async throws -> Data {
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
        settings.flashMode = .auto

        return try await withCheckedThrowingContinuation { continuation in
            self.captureContinuation = continuation
            self.sessionQueue.async {
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - Session configuration

    private func configureSession() throws {
        let s = AVCaptureSession()
        s.beginConfiguration()
        s.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.cameraUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.configurationFailed("input: \(error.localizedDescription)")
        }
        guard s.canAddInput(input) else {
            throw CaptureError.configurationFailed("cannot add input")
        }
        s.addInput(input)

        let output = AVCapturePhotoOutput()
        guard s.canAddOutput(output) else {
            throw CaptureError.configurationFailed("cannot add photo output")
        }
        s.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced

        s.commitConfiguration()
        self.session = s
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
        Task { @MainActor in
            guard let continuation = self.captureContinuation else { return }
            self.captureContinuation = nil
            if let error {
                continuation.resume(throwing: CaptureError.captureFailed(error))
                return
            }
            guard let fullData = photo.fileDataRepresentation(),
                  let image = UIImage(data: fullData) else {
                continuation.resume(throwing: CaptureError.imageProcessingFailed)
                return
            }
            do {
                let compressed = try ImageCompression.jpeg(image, maxLongEdge: 1600, quality: 0.85)
                continuation.resume(returning: compressed)
            } catch {
                continuation.resume(throwing: error)
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
