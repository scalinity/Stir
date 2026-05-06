// ScanCaptureView
//
// AVCaptureSession preview + multi-shutter accumulator. Uses
// UIViewRepresentable to host AVCaptureVideoPreviewLayer — the one
// exception to our SwiftUI-first rule per CLAUDE.md §"What NOT to do
// by default".
//
// SCA-35: in-flow accumulator. Each shutter tap captures, freezes the
// still briefly, appends to ScanViewModel.capturedImages, and restarts
// the live preview for the next shot. The user can capture up to
// `ScanViewModel.maxImagesPerScan` photos (Pro: 4; Free/Premium: 1
// before paywall fires) then taps "Done · N photos" to submit. A
// thumbnail strip below the live preview shows what's been captured
// and lets the user delete a shot.

import AVFoundation
import SwiftUI

struct ScanCaptureView: View {
    @Bindable var viewModel: ScanViewModel
    let cameraService: CameraService
    let onCaptured: () -> Void

    @State private var isCapturing = false
    /// Most recent capture, frozen on screen for ~400ms after the
    /// shutter resolves so the user gets visual confirmation that the
    /// shot landed before the live preview restarts. Cleared on
    /// re-entry and after the freeze-and-append cycle completes.
    @State private var freezeImage: UIImage?
    /// True while we are actively running an AI parse on the
    /// accumulated captures. Banner copy + button disablement read
    /// off this directly. Set when the user taps "Done", cleared when
    /// the VM transitions to .review or .error.
    @State private var isSubmitting = false
    /// Holds the capture-flow Task so we can cancel it on view dismiss.
    /// Without this, a back-swipe during AI parse would let the task
    /// run to completion and push the review screen onto a stack the
    /// user already navigated away from.
    @State private var captureTask: Task<Void, Never>?
    @State private var submitTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = freezeImage {
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
            freezeImage = nil
            isSubmitting = false
            viewModel.enterCapturing()
            do {
                try await cameraService.start()
            } catch {
                viewModel.resetToPrimer()
            }
        }
        .onDisappear {
            // Cancel any in-flight capture/submit so a pending parse doesn't
            // resolve and push the review screen onto a popped stack.
            captureTask?.cancel()
            captureTask = nil
            submitTask?.cancel()
            submitTask = nil
            Task { await cameraService.stop() }
        }
        // SCA-19 — full-screen scan-capture tutorial. Suppressed during
        // submission and while the freeze still is up so the cover
        // doesn't fight the in-progress task UI. Tutorial's interactive
        // miniatures stand in for the live camera surface.
        .tutorial(
            key: .scanCapture,
            content: { ScanCaptureTutorial() },
            shouldPresent: viewModel.phase != .parsing
                && !isSubmitting
                && freezeImage == nil,
        )
    }

    // MARK: - Overlay

    @ViewBuilder
    private var overlay: some View {
        VStack {
            Spacer()
            banner
            Spacer()
            if !isSubmitting {
                bottomChrome
                    .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if isSubmitting {
            parsingBanner
        } else if viewModel.capturedImages.isEmpty {
            hintBanner(text: "Frame as much of your kitchen as you can — lighting matters.")
        } else if viewModel.capturedImages.count >= ScanViewModel.maxImagesPerScan {
            hintBanner(text: "You've reached the \(ScanViewModel.maxImagesPerScan)-photo cap. Tap Done to scan.")
        } else {
            hintBanner(text: "Add another angle — fridge, pantry, counter — or tap Done to scan.")
        }
    }

    private func hintBanner(text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.5), in: Capsule())
            .padding(.horizontal, 24)
    }

    /// Shown over the still while AI parsing runs. Tells the user
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

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 16) {
            if !viewModel.capturedImages.isEmpty {
                thumbnailStrip
            }
            HStack(alignment: .center) {
                Spacer()
                captureButton
                Spacer()
            }
            .overlay(alignment: .trailing) {
                if !viewModel.capturedImages.isEmpty {
                    doneButton
                        .padding(.trailing, 24)
                }
            }
        }
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.capturedImages) { captured in
                    thumbnailCell(captured)
                }
                ForEach(0 ..< slotsRemaining, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 56, height: 56)
                        .overlay(
                            Rectangle()
                                .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])),
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private var slotsRemaining: Int {
        max(0, ScanViewModel.maxImagesPerScan - viewModel.capturedImages.count)
    }

    private func thumbnailCell(_ captured: ScanViewModel.CapturedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: captured.data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.2))
                    .frame(width: 56, height: 56)
            }
            Button {
                viewModel.removeCapturedImage(id: captured.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    // justification: 18pt symbol size for compact 56pt thumbnail delete affordance, manually tuned to land cleanly inside the corner without crowding the photo
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .offset(x: 6, y: -6)
            .accessibilityLabel("Remove this photo")
        }
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
        .disabled(shutterDisabled)
        .opacity(shutterDisabled ? 0.4 : 1.0)
        .accessibilityLabel("Capture photo")
    }

    private var shutterDisabled: Bool {
        isCapturing
            || isSubmitting
            || viewModel.phase == .parsing
            || viewModel.capturedImages.count >= ScanViewModel.maxImagesPerScan
    }

    private var doneButton: some View {
        Button {
            submitTask = Task { await submit() }
        } label: {
            Text(doneButtonTitle)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.white, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.capturedImages.isEmpty || isSubmitting)
        .accessibilityLabel("Scan with \(viewModel.capturedImages.count) \(viewModel.capturedImages.count == 1 ? "photo" : "photos")")
    }

    private var doneButtonTitle: String {
        let count = viewModel.capturedImages.count
        let noun = count == 1 ? "photo" : "photos"
        return "Done · \(count) \(noun)"
    }

    // MARK: - Capture + submit

    private func capture() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        PostHogClient.shared.capture(.scanStarted, properties: [:])

        do {
            let fullData = try await cameraService.capturePhoto()
            try Task.checkCancellation()

            // Two parallel detached tasks: one rasterizes the display
            // image (fast — needed for the on-screen freeze); one
            // resizes + re-encodes for the AI submit (heavier). The
            // display task usually wins by ~100-200ms so the still
            // appears well before the append+restart cycle.
            async let displayResult: UIImage? = Task.detached(priority: .userInitiated) {
                UIImage(data: fullData)?.preparingForDisplay()
            }.value
            async let compressedResult: Data? = Task.detached(priority: .userInitiated) {
                guard let image = UIImage(data: fullData) else { return nil }
                return try? ImageCompression.jpeg(image, maxLongEdge: 1600, quality: 0.85)
            }.value

            // Stop the live session while we render the freeze + append.
            // We restart it after appending — the user is still in the
            // capture phase and may shoot another photo.
            await cameraService.stop()

            if let display = await displayResult {
                try Task.checkCancellation()
                freezeImage = display
            }

            guard let compressed = await compressedResult else {
                // Couldn't produce a payload — bail back to live preview.
                freezeImage = nil
                try? await cameraService.start()
                return
            }
            try Task.checkCancellation()

            // Hold the freeze briefly so the user sees confirmation.
            // 350ms is enough to register without dragging the
            // multi-shot cadence.
            try? await Task.sleep(nanoseconds: 350_000_000)
            try Task.checkCancellation()

            let result = viewModel.appendCapturedImage(compressed, mimeType: "image/jpeg")
            freezeImage = nil

            switch result {
            case .appended:
                // Restart camera for the next shot (unless we're capped,
                // in which case the shutter is disabled anyway).
                if viewModel.capturedImages.count < ScanViewModel.maxImagesPerScan {
                    try? await cameraService.start()
                } else {
                    // At cap: keep the live preview running so the user
                    // can re-frame for retake-via-X-then-add. The Done
                    // button is the dominant CTA here.
                    try? await cameraService.start()
                }
            case .capped:
                // Defensive — shutter should be disabled before this fires.
                try? await cameraService.start()
            case .blockedByEntitlement:
                // Paywall fired by the VM. Restart camera so the user
                // sees live preview when they dismiss the paywall.
                try? await cameraService.start()
            }
        } catch is CancellationError {
            // View was dismissed mid-capture; nothing to do. The
            // .onDisappear handler already stopped the camera.
        } catch {
            freezeImage = nil
            try? await cameraService.start()
        }
    }

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        // Stop the live session — the user is done capturing.
        await cameraService.stop()

        // Render the most recent capture as the freeze surface so the
        // parsing banner has a stable photo behind it instead of a
        // black void or stale preview frame.
        if let primary = viewModel.capturedImages.first?.data,
           let image = UIImage(data: primary)?.preparingForDisplay()
        {
            freezeImage = image
        }

        await viewModel.submitCapturedImages()

        // Always navigate to review on a terminal phase — the
        // review screen owns both the success-chip path and the
        // error-card path. Avoids leaving the user staring at a
        // restarted live preview after a parse error with no
        // explanation.
        switch viewModel.phase {
        case .review, .error:
            onCaptured()
        default:
            // Shouldn't happen — defensive reset back to live preview
            // if the VM ends up in an unexpected phase.
            freezeImage = nil
            try? await cameraService.start()
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
