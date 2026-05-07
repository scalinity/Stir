// ScanCaptureView
//
// AVCaptureSession preview + multi-shutter accumulator. Uses
// UIViewRepresentable to host AVCaptureVideoPreviewLayer — the one
// exception to our SwiftUI-first rule per CLAUDE.md §"What NOT to do
// by default".
//
// SCA-35: in-flow accumulator. Each shutter tap captures, freezes the
// still briefly (~350 ms — see `freezeDurationNanos`), appends to
// ScanViewModel.capturedImages, and restarts the live preview for the
// next shot. The user can capture up to `ScanViewModel.maxImagesPerScan`
// photos (Pro: 4; Free/Premium: 1 before paywall fires) then taps the
// ember "Done →" pill to submit.
//
// SCA-43: bottom chrome restored to the mockup's design — thumbnail
// strip on its own row above, then a shutter row that's a centered
// 74pt capture circle with a compact ember Done pill anchored on the
// trailing edge. The earlier SCA-36 W13 stacked layout was a defensive
// response to a long "Done · N photos" label; trimming the label
// removed the collision risk that justified the stacking.

import AVFoundation
import OSLog
import SwiftUI

struct ScanCaptureView: View {
    @Bindable var viewModel: ScanViewModel
    let cameraService: CameraService
    let onCaptured: () -> Void

    /// Freeze duration after a successful shutter — visual confirmation
    /// the shot landed before the live preview restarts. 350 ms
    /// registers without dragging the multi-shot cadence.
    private static let freezeDurationNanos: UInt64 = 350_000_000

    @State private var isCapturing = false
    /// Most recent capture, frozen on screen for `freezeDurationNanos`
    /// after the shutter resolves. Cleared on re-entry, after the
    /// freeze-and-append cycle completes, and before navigation away
    /// from the capture screen so the decoded UIImage isn't retained
    /// alongside the next screen's hosted thumbnail (SCA-36 W20).
    @State private var freezeImage: UIImage?
    /// True while we are actively running an AI parse on the
    /// accumulated captures. Banner copy + button disablement read
    /// off this directly. Set when the user taps "Done", cleared when
    /// the VM transitions to .review or .error.
    @State private var isSubmitting = false
    /// Holds the capture-flow Task so we can cancel it on view dismiss.
    /// Without this, a back-swipe during AI parse would let the task
    /// run to completion and push the review screen onto a popped stack.
    @State private var captureTask: Task<Void, Never>?
    @State private var submitTask: Task<Void, Never>?

    /// SCA-47: user-selectable flash policy, persisted per-installation
    /// via UserDefaults. Default .off preserves the SCA-39 instant-
    /// shutter floor; .on / .auto are user-opt-in for dark pantries
    /// (with the documented metering-pre-flash latency penalty). The
    /// AppStorage key is namespaced so a future reset/migration knows
    /// it's a scan-feature preference rather than a generic toggle.
    @AppStorage("com.scalinity.stir.scan.flashMode")
    private var flashMode: ScanFlashMode = .off

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image = freezeImage {
                Image(uiImage: image)
                    .resizable()
                    // SCA-40: match the live preview's `.resizeAspect`
                    // gravity. Was `.fill` (centered crop) which created
                    // a visual jump between the cropped preview and the
                    // un-cropped captured photo at shutter time.
                    .aspectRatio(contentMode: .fit)
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
            // SCA-36 C2: re-entry from a swipe-back means a fresh
            // scan, not a continuation. Clear the prior buffer so a
            // non-Pro user can't trigger the multi-image paywall on
            // what they perceive as their first shutter, and so a
            // Pro user doesn't silently submit a stale photo merged
            // with newly-captured ones.
            freezeImage = nil
            isSubmitting = false
            viewModel.clearCapturedImages()
            viewModel.enterCapturing()
            do {
                try await cameraService.start()
            } catch {
                viewModel.resetToPrimer()
            }
        }
        .onDisappear {
            // Cancel any in-flight capture/submit. `submit()` checks
            // `Task.isCancelled` after the AI request returns and
            // bails before navigating, which is the SCA-36 C1 fix —
            // without that, a back-swipe-mid-parse would push the
            // review screen onto a popped stack.
            captureTask?.cancel()
            captureTask = nil
            submitTask?.cancel()
            submitTask = nil
            Task { await cameraService.stop() }
        }
        // SCA-19 — full-screen scan-capture tutorial. Suppressed during
        // the parsing phase + while the freeze still is up. SCA-36 W14:
        // `isSubmitting` previously gated this in addition to phase,
        // but `submitCapturedImages` flips phase to .parsing, so the
        // phase check already covers submit; redundant clause dropped.
        .tutorial(
            key: .scanCapture,
            content: { ScanCaptureTutorial() },
            shouldPresent: viewModel.phase != .parsing && freezeImage == nil,
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

    // MARK: - Bottom chrome
    //
    // SCA-43: restored the mockup's 3-column row
    // (`stir-app-design/.../04_scan_flow.html` line 147). Thumbnail
    // strip lives on its own row above so 1-4 thumbs + slot
    // placeholders never crowd the shutter; the shutter row is a
    // ZStack with the 74pt capture circle centered and the Done pill
    // overlaid on the trailing edge. Trimming the label to "Done →"
    // (count is already visible in the strip) keeps the pill ~70pt
    // wide so it can never collide with the centered shutter — which
    // was the real reason SCA-36 W13 had stacked Done above shutter
    // on its own row in the first place.

    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 16) {
            if !viewModel.capturedImages.isEmpty {
                thumbnailStrip
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                doneButtonRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            shutterRow
        }
        // SCA-52 S1: animate the conditional appearance of the thumb
        // strip + Done row on first/last shutter so the layout doesn't
        // jump abruptly. Tracks `isEmpty` (not `count`) so subsequent
        // captures append thumbs without re-triggering the slide.
        .animation(.easeInOut(duration: 0.2), value: viewModel.capturedImages.isEmpty)
    }

    /// SCA-47: shutter + flash toggle. ZStack keeps the 74pt shutter
    /// mathematically centered (the SCA-36 W13 invariant) while the
    /// flash toggle floats on the leading edge — Apple Camera's
    /// top-bar location is unavailable to us because the top of the
    /// scan screen is occupied by the hint banner.
    private var shutterRow: some View {
        ZStack {
            captureButton
            HStack {
                flashToggleButton
                    .padding(.leading, 32)
                Spacer()
            }
        }
    }

    private var flashToggleButton: some View {
        Button {
            flashMode = flashMode.next()
        } label: {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.4))
                    .frame(width: 36, height: 36)
                Image(systemName: flashMode.sfSymbol)
                    // justification: 18pt symbol on a 36pt dark-circle gives
                    // a comfortable tap target while reading clearly against
                    // the live preview; matches the shutter's white-on-dark
                    // contrast.
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .buttonStyle(.plain)
        .disabled(shutterDisabled)
        .opacity(shutterDisabled ? 0.4 : 1.0)
        .accessibilityLabel(flashMode.accessibilityLabel)
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
            // SCA-36 S21 (deferred): `UIImage(data:)` decodes lazily;
            // the decoded bitmap is only retained while the View is
            // realized. With the strip rendering 1-4 thumbnails of
            // 1600pt-long-edge JPEGs (~250 KB each), redraws on
            // unrelated state changes (capture phase, freeze toggle)
            // re-decode at <50ms total. Future opt: cache the decoded
            // UIImage on `CapturedImage` at append time.
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

    /// Shutter disabled when:
    ///   - capture in flight (would race),
    ///   - submit in flight (multi-image AI parse running),
    ///   - VM phase is .parsing,
    ///   - buffer is at the photo cap.
    /// Tier check is intentionally NOT here — SCA-36 W5 puts the
    /// pre-shutter entitlement gate inside `capture()` so the paywall
    /// fires BEFORE the camera runs through stop+freeze+restart.
    private var shutterDisabled: Bool {
        isCapturing
            || isSubmitting
            || viewModel.phase == .parsing
            || viewModel.capturedImages.count >= ScanViewModel.maxImagesPerScan
    }

    private var doneButtonRow: some View {
        HStack {
            Spacer()
            doneButton
                .padding(.trailing, 24)
        }
    }

    private var doneButton: some View {
        Button {
            submitTask = Task { await submit() }
        } label: {
            HStack(spacing: 6) {
                Text("Done")
                    .font(.callout.weight(.semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            // SCA-52 W1: vertical padding 10→14 brings the pill to ~45pt
            // tall so it clears the iOS HIG 44pt tap-target minimum and
            // matches the mockup's `height:44` (`04_scan_flow.html:157`).
            .padding(.vertical, 14)
            .background(Color.Stir.ember600, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.capturedImages.isEmpty || isSubmitting)
        .accessibilityLabel("Scan with \(viewModel.capturedImages.count) \(viewModel.capturedImages.count == 1 ? "photo" : "photos")")
    }

    // MARK: - Capture + submit

    private func capture() async {
        guard !isCapturing else { return }

        // SCA-36 W5: pre-shutter entitlement gate. Without this, a
        // non-Pro user attempting their 2nd shot would watch the
        // camera capture, freeze for 350 ms, stop, then surface the
        // paywall — burning ~500 ms of confusion. Surface the paywall
        // BEFORE the capture cycle so the camera never stops.
        switch viewModel.canAppendCapturedImage() {
        case .appended:
            break
        case .capped:
            // Shutter should be disabled at the cap; defensive bail.
            return
        case .blockedByEntitlement:
            viewModel.firePaywallForMultiImageGate()
            return
        }

        isCapturing = true
        defer { isCapturing = false }

        PostHogClient.shared.capture(.scanStarted, properties: [
            "flash_mode": flashMode.rawValue,
        ])

        do {
            let fullData = try await cameraService.capturePhoto(flashMode: flashMode.avFlashMode)
            try Task.checkCancellation()

            // Two parallel detached tasks: one rasterizes the display
            // image (fast — needed for the on-screen freeze); one
            // resizes + re-encodes for the AI submit (heavier).
            async let displayResult: UIImage? = Task.detached(priority: .userInitiated) {
                UIImage(data: fullData)?.preparingForDisplay()
            }.value
            async let compressedResult: Data? = Task.detached(priority: .userInitiated) {
                guard let image = UIImage(data: fullData) else { return nil }
                return try? ImageCompression.jpeg(image, maxLongEdge: 1600, quality: 0.85)
            }.value

            // Stop the live session while we render the freeze + append.
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
            try? await Task.sleep(nanoseconds: Self.freezeDurationNanos)
            try Task.checkCancellation()

            let result = viewModel.appendCapturedImage(compressed, mimeType: "image/jpeg")
            freezeImage = nil

            // SCA-36 W5/W6/W9: pre-shutter gate (above) means
            // `.appended` is the only expected post-capture result.
            // The other arms are defensive for SwiftUI re-render
            // races. All three branches just restart the camera —
            // paywall is NOT fired here (already handled at the pre-
            // shutter site, or shutter was disabled).
            if result != .appended {
                Logger.scanFeature.warning(
                    "appendCapturedImage post-capture race: \(String(describing: result), privacy: .public)",
                )
            }
            try? await cameraService.start()
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

        // SCA-36 W7: rasterize off-main. preparingForDisplay() does a
        // CG decode that would otherwise block the main actor (~50ms
        // on a 1600pt JPEG). Other capture-path detached tasks already
        // use this pattern.
        if let primary = viewModel.capturedImages.first?.data {
            let prepared = await Task.detached(priority: .userInitiated) {
                UIImage(data: primary)?.preparingForDisplay()
            }.value
            freezeImage = prepared
        }

        await viewModel.submitCapturedImages()

        // SCA-36 C1: bail cleanly if the view was dismissed mid-submit.
        // Without this, a back-swipe-during-parse cancels the URLSession
        // call (URLError(.cancelled)), the VM's catch detects
        // Task.isCancelled and returns without flipping phase, control
        // returns here with phase still .parsing → switch falls into
        // the default arm. The .review/.error guard below would have
        // pushed the review screen onto a popped stack otherwise.
        if Task.isCancelled {
            freezeImage = nil
            return
        }

        // SCA-36 W20: clear the decoded UIImage before navigation so
        // the ~3-5MB RGBA buffer isn't retained alongside the next
        // screen's hosted thumbnail during the transition.
        switch viewModel.phase {
        case .review, .error:
            freezeImage = nil
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
        // SCA-40: `.resizeAspect` (letterbox) — was `.resizeAspectFill`
        // which cropped the 3:4 sensor's left+right edges to fill the
        // ~9:19.5 screen aspect. The preview now shows the full sensor
        // field with black bars on the sides, so what the user sees is
        // exactly the rectangle that gets captured.
        view.videoPreviewLayer.videoGravity = .resizeAspect
        // SCA-40: pin portrait rotation. iOS 17+ deprecated
        // `videoOrientation` in favor of `videoRotationAngle` and the
        // default rotation between preview and photo-output connections
        // can drift across releases / device classes. Pin 90° on both
        // sides (CameraService does the same on the photo output).
        if let connection = view.videoPreviewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
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
