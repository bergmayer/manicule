import Vision
import CoreGraphics

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A single recognized text observation with its bounding box.
struct OCRResult: Sendable {
    let text: String
    /// Bounding box in normalized Vision coordinates (bottom-left origin, 0-1 range).
    let boundingBox: CGRect
}

/// Performs OCR on images using the Vision framework, with per-URL caching.
actor OCRService {
    static let shared = OCRService()

    private var cache: [URL: [OCRResult]] = [:]

    /// Recognize text in the image at the given URL.
    /// Returns an array of recognized text results with bounding boxes.
    func recognizeText(in imageURL: URL) async -> [OCRResult] {
        if let cached = cache[imageURL] { return cached }

        guard let cgImage = loadCGImage(from: imageURL) else { return [] }

        let results = await performOCR(on: cgImage)
        cache[imageURL] = results
        return results
    }

    /// Check if a page's recognized text contains the query (case-insensitive).
    func pageContains(imageURL: URL, query: String) async -> Bool {
        let results = await recognizeText(in: imageURL)
        let lowered = query.lowercased()
        return results.contains { $0.text.lowercased().contains(lowered) }
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func loadCGImage(from url: URL) -> CGImage? {
        #if canImport(UIKit)
        guard let uiImage = UIImage(contentsOfFile: url.path),
              let cgImage = uiImage.cgImage else { return nil }
        return cgImage
        #else
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return cgImage
        #endif
    }

    private func performOCR(on image: CGImage) async -> [OCRResult] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }
                let results = observations.compactMap { obs -> OCRResult? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return OCRResult(text: candidate.string, boundingBox: obs.boundingBox)
                }
                continuation.resume(returning: results)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
