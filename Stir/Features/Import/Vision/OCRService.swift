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
// Returns ordered plain text joined with newlines. The Edge Function
// then does the JSON-LD / HTML stripping / prose extraction — iOS
// only produces raw OCR text.
//
// Async: runs on Vision's internal queue, hops back to MainActor
// only for the result delivery.

import UIKit
import Vision

@MainActor
struct OCRService {
    enum Failure: Error, LocalizedError {
        case imageDecodeFailed
        case visionError(Error)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .imageDecodeFailed:
                return "We couldn't read that image. Try another one."
            case .visionError(let err):
                return "OCR failed: \(err.localizedDescription)"
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

    /// Recognize text in a single image. v1 single-image scope; if
    /// called with UIImage it blocks until Vision completes or throws.
    func recognizeText(in image: UIImage) async throws -> Result {
        guard let cgImage = image.cgImage else {
            throw Failure.imageDecodeFailed
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.visionError(error)
        }
        let observations = (request.results ?? [])
        let lines: [String] = observations.compactMap { obs in
            obs.topCandidates(1).first?.string
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.emptyResult }
        return Result(text: text, pageCount: 1)
    }
}
