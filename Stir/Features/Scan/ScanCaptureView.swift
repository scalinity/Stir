// ScanCaptureView
//
// AVCaptureSession preview + single-tap capture. Uses UIViewRepresentable
// to host AVCaptureVideoPreviewLayer — the one exception to our
// SwiftUI-first rule per CLAUDE.md §"What NOT to do by default".
//
// Once a photo is captured, the live preview is replaced with the still
// frame and the capture session is stopped immediately. The user no
// longer feels they need to hold the phone steady while AI parsing
// runs. After the view model transitions to .review (or .error) the
// parent navigates to the review screen — the review surface owns
// both the success chips and the error card.

import AVFoundation
import SwiftUI

struct ScanCaptureView: View {
    @Bindable var viewModel: ScanViewModel
    let cameraService: CameraService
    let onCaptured: () -> Void

    @State private var isCapturing = false
    /// True from the moment `capturePhoto()` resolves until we navigate
    /// to review or restart the camera. Banner-state truth — independent
    /// of the still image's decode success — so a failed UIImage decode
    /// can't leave the framing-hint banner up while the session is
    /// being torn down.
    @State private var isReviewingCapture = false
    /// Captured still image, pre-rasterized off-main. While non-nil the
    /// live `CameraPreview` is hidden and this frame is displayed
    /// instead. Cleared on `.task` re-entry (e.g. swipe-back from
    /// review).
    @State private var capturedImage: UIImage?
    /// Holds the capture-flow Task so we can cancel it on view dismiss.
    /// Without this, a back-swipe during AI parse would let the task
    /// run to completion and push the review screen onto a stack the
    /// user already navigated away from.
    @State private var captureTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            } else if let session = cameraService.session {
                CameraPreview(session: session)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            overlay
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            // Re-entry from a swipe-back: discard prior capture state
            // and restart the live session.
            isReviewingCapture = false
            capturedImage = nil
            viewModel.enterCapturing()
            do {
                try await cameraService.start()
            } catch {
                viewModel.resetToPrimer()
            }
        }
        .onDisappear {
            // Cancel any in-flight capture so a pending AI parse doesn't
            // resolve and push the review screen onto a popped stack.
            captureTask?.cancel()
            captureTask = nil
            Task { await cameraService.stop() }
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlay: some View {
        VStack {
            Spacer()
            if isReviewingCapture {
                parsingBanner
            } else {
                hintBanner
            }
            Spacer()
            if !isReviewingCapture {
                captureButton
                    .padding(.bottom, 32)
            }
        }
    }

    private var hintBanner: some View {
        // VoiceOver should read the actual copy, not a bare "Framing hint"
        // noun — the text is the hint. Strip the label override.
        Text("Frame as much of your kitchen as you can — lighting matters.")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.horizontal, 24)
    }

    /// Shown over the frozen still while AI parsing runs. Tells the user
    /// the shot is taken and they can put the phone down.
    private var parsingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            Text("Looking at your kitchen…")
                .font(.footnote)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Looking at your kitchen")
    }

    private var captureButton: some View {
        Button {
            captureTask = Task { await capture() }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                if isCapturing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 60, height: 60)
                }
            }
        }
        .disabled(isCapturing || viewModel.phase == .parsing)
        .accessibilityLabel("Capture photo")
    }

    private func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        PostHogClient.shared.capture(.scanStarted, properties: [:])

        do {
            let fullData = try await cameraService.capturePhoto()
            try Task.checkCancellation()

            // Snap the banner state immediately — capturePhoto now
            // resolves with the AVFoundation-encoded full JPEG in
            // ~50ms, so the framing hint flips to "Looking at your
            // kitchen…" almost as fast as the shutter sound.
            isReviewingCapture = true

            // Stop the session right after we have the bytes — the
            // user no longer needs the live preview, and the session
            // is the most expensive resource in the stack.
            await cameraService.stop()

            // Two parallel detached tasks: one rasterizes the display
            // image (fast — needed for the on-screen still); one
            // resizes + re-encodes for the AI submit (heavier). The
            // display task usually wins by ~100-200ms so the still
            // appears well before the AI request fires.
            async let displayResult: UIImage? = Task.detached(priority: .userInitiated) {
                UIImage(data: fullData)?.preparingForDisplay()
            }.value
            async let compressedResult: Data? = Task.detached(priority: .userInitiated) {
                guard let image = UIImage(data: fullData) else { return nil }
                return try? ImageCompression.jpeg(image, maxLongEdge: 1600, quality: 0.85)
            }.value

            if let display = await displayResult {
                try Task.checkCancellation()
                capturedImage = display
            }

            guard let compressed = await compressedResult else {
                // Couldn't produce a payload for AI submit — bail
                // back to live preview so the user can retake.
                isReviewingCapture = false
                capturedImage = nil
                viewModel.resetToPrimer()
                try? await cameraService.start()
                return
            }
            try Task.checkCancellation()

            viewModel.setCapturedImageData(compressed)
            await viewModel.submitCapturedImage(compressed, mimeType: "image/jpeg")
            try Task.checkCancellation()

            // Always navigate to review on a terminal phase — the
            // review screen owns both the success-chip path and the
            // error-card path. Avoids leaving the user staring at a
            // restarted live preview after a parse error with no
            // explanation.
            switch viewModel.phase {
            case .review, .error:
                onCaptured()
            default:
                // Shouldn't happen — defensive reset back to live
                // preview if the VM ends up in an unexpected phase.
                isReviewingCapture = false
                capturedImage = nil
                try? await cameraService.start()
            }
        } catch is CancellationError {
            // View was dismissed mid-capture; nothing to do. The
            // .onDisappear handler already stopped the camera.
        } catch {
            isReviewingCapture = false
            capturedImage = nil
            viewModel.resetToPrimer()
        }
    }
}

// MARK: - AVCaptureSession preview

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // No-op — session binding is one-shot at makeUIView time.
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // swiftlint:disable:next force_cast
            return layer as! AVCaptureVideoPreviewLayer
        }
    }
}
