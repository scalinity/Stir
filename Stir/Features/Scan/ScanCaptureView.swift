// ScanCaptureView
//
// AVCaptureSession preview + single-tap capture. Uses UIViewRepresentable
// to host AVCaptureVideoPreviewLayer — the one exception to our
// SwiftUI-first rule per CLAUDE.md §"What NOT to do by default".
//
// Once a photo is captured, calls the view model's submitCapturedImage
// path then signals onCaptured so the parent can navigate to Review.

import AVFoundation
import SwiftUI

struct ScanCaptureView: View {
    @Bindable var viewModel: ScanViewModel
    let cameraService: CameraService
    let onCaptured: () -> Void

    @State private var isCapturing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let session = cameraService.session {
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
            viewModel.enterCapturing()
            do {
                try await cameraService.start()
            } catch {
                viewModel.resetToPrimer()
            }
        }
        .onDisappear {
            Task { await cameraService.stop() }
        }
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlay: some View {
        VStack {
            Spacer()
            hintBanner
            Spacer()
            captureButton
                .padding(.bottom, 32)
        }
    }

    private var hintBanner: some View {
        Text("Frame as much of your kitchen as you can — lighting matters.")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.horizontal, 24)
            .accessibilityLabel("Framing hint")
    }

    private var captureButton: some View {
        Button {
            Task { await capture() }
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
            let data = try await cameraService.capturePhoto()
            await viewModel.submitCapturedImage(data, mimeType: "image/jpeg")
            if case .review = viewModel.phase {
                onCaptured()
            }
        } catch {
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
