import Vision
import CoreGraphics

import ImageIO

/// A single recognized text observation with its bounding box.
struct OCRResult: Sendable {
    let text: String
    /// Bounding box in normalized Vision coordinates (bottom-left origin, 0-1 range).
    let boundingBox: CGRect
}

/// Performs OCR on images using the Vision framework, with per-URL caching.
actor OCRService {
    static let shared = OCRService()

    private enum Page: Hashable {
        case file(URL)
        case pdf(hash: String, index: Int)
    }
    private var cache: [Page: [OCRResult]] = [:]

    /// Recognize text in the image at the given URL.
    /// Returns an array of recognized text results with bounding boxes.
    func recognizeText(in imageURL: URL) async throws -> [OCRResult] {
        let key = Page.file(imageURL)
        if let cached = cache[key] { return cached }
        try Task.checkCancellation()
        guard let image = loadCGImage(from: imageURL) else { throw CocoaError(.fileReadCorruptFile) }
        return try await recognizeText(in: image, key: key)
    }

    private func recognizeText(in image: CGImage, key: Page) async throws -> [OCRResult] {
        if let cached = cache[key] { return cached }
        try Task.checkCancellation()
        let results = try await performOCR(on: image)
        try Task.checkCancellation()
        // Entries for closed documents are never evicted individually (their
        // temp URLs are unique per open), so cap the cache to bound memory.
        if cache.count >= 500 { cache.removeAll() }
        cache[key] = results
        return results
    }

    /// Check if a page's recognized text contains the query (case-insensitive).
    func pageContains(imageURL: URL, query: String) async throws -> Bool {
        let results = try await recognizeText(in: imageURL)
        let lowered = query.lowercased()
        return results.contains { $0.text.lowercased().contains(lowered) }
    }

    /// PDF searches share recognition by immutable document identity, without
    /// temporary image files or collisions between windows and cancelled scans.
    func pageContains(image: CGImage, fileHash: String, pageIndex: Int, query: String) async throws -> Bool {
        let results = try await recognizeText(in: image, key: .pdf(hash: fileHash, index: pageIndex))
        let lowered = query.lowercased()
        return results.contains { $0.text.lowercased().contains(lowered) }
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func loadCGImage(from url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Vision's Swift request API keeps recognition in the caller's task. Its
    /// throwing result distinguishes analysis failure from a page with no text.
    private func performOCR(on image: CGImage) async throws -> [OCRResult] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        return observations.compactMap { obs -> OCRResult? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OCRResult(text: candidate.string, boundingBox: obs.boundingBox.cgRect)
        }
    }
}
