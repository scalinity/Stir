// OCRService
//
// Vision-backed text recognition for recipe screenshots. Wraps
// VNRecognizeTextRequest with sensible defaults for recipe content:
//   - accurate recognition level (spec §12 recipe-import accuracy
//     target is 85% acceptable, which accurate easily clears)
//   - English + auto language correction
//   - usesLanguageCorrection = true (fixes common OCR slips like
//     "I tsp" → "1 tsp")
//
// Runs OFF the main thread: `VNImageRequestHandler.perform` is
// synchronous + blocking (500–2000 ms typical for a recipe screenshot).
// Callers are on @MainActor; we bounce to a detached Task so the
// progress spinner in `ImportEntryView`'s footer animates through
// the OCR window. Result hops back to the caller's actor implicitly
// via `.value`.

import UIKit
import Vision

struct OCRService: Sendable {
    enum Failure: Error, LocalizedError {
        case imageDecodeFailed
        case visionError(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .imageDecodeFailed:
                return "We couldn't read that image. Try another one."
            case .visionError(let message):
                return "OCR failed: \(message)"
            case .emptyResult:
                return "Nothing readable in that image. Try a clearer shot."
            }
        }
    }

    struct Result: Sendable {
        let text: String
        /// Number of images OCR'd (iOS v1 is single-image, but the field
        /// is captured on the RecipeImport row for audit). Always 1 for
        /// now — multi-image OCR is deferred to step 8+.
        let pageCount: Int
    }

    func recognizeText(in image: UIImage) async throws -> Result {
        // Extract the CGImage on the caller's actor so we pass a
        // Sendable handle into the detached task. UIImage itself is
        // not Sendable; CGImage is (immutable Core Foundation type).
        guard let cgImage = image.cgImage else {
            throw Failure.imageDecodeFailed
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.performOCR(on: cgImage)
        }.value
    }

    /// Synchronous Vision work — runs on the detached task's background
    /// thread. Stays a `static` so it doesn't capture self (keeps the
    /// detached closure free of actor references).
    private static func performOCR(on cgImage: CGImage) throws -> Result {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.visionError(error.localizedDescription)
        }
        let observations = request.results ?? []
        let lines: [String] = observations.compactMap { obs in
            obs.topCandidates(1).first?.string
        }
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyResult }
        return Result(text: text, pageCount: 1)
    }
}
