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

        let results = performOCR(on: cgImage)
        // Entries for closed documents are never evicted individually (their
        // temp URLs are unique per open), so cap the cache to bound memory.
        if cache.count >= 500 { cache.removeAll() }
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

    /// Runs recognition synchronously on the actor. `perform` blocks until the
    /// request completes, so reading `request.results` afterwards is safe and
    /// avoids the completion-handler/continuation dance (which could double-
    /// resume when `perform` both invokes the handler and throws).
    private func performOCR(on image: CGImage) -> [OCRResult] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }
        return observations.compactMap { obs -> OCRResult? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OCRResult(text: candidate.string, boundingBox: obs.boundingBox)
        }
    }
}
