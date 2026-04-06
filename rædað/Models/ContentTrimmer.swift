import CoreGraphics
import Vision

/// Detects and caches content bounds for page trimming (whitespace removal).
/// Uses Vision framework text recognition as the primary signal, supplemented by
/// saliency for non-text content. Falls back to pixel-based edge analysis.
final class ContentTrimmer: @unchecked Sendable {
    static let shared = ContentTrimmer()

    private var cache: [String: CGRect] = [:]
    private let lock = NSLock()

    /// Returns the content rect (normalized 0..1, top-left origin) for a CGImage.
    /// Cached by key to avoid recomputation.
    func contentRect(for image: CGImage, key: String) -> CGRect {
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let rect = detectContent(in: image)

        lock.lock()
        cache[key] = rect
        lock.unlock()

        return rect
    }

    /// Crops a CGImage to its detected content area.
    func trimmed(_ image: CGImage, key: String) -> CGImage {
        let rect = contentRect(for: image, key: key)
        guard rect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return image }
        let pixelRect = CGRect(
            x: rect.minX * CGFloat(image.width),
            y: rect.minY * CGFloat(image.height),
            width: rect.width * CGFloat(image.width),
            height: rect.height * CGFloat(image.height)
        ).integral
        return image.cropping(to: pixelRect) ?? image
    }

    func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: - Detection

    private func detectContent(in image: CGImage) -> CGRect {
        if let rect = visionDetect(in: image) {
            return rect
        }
        return pixelDetect(in: image)
    }

    /// Uses VNRecognizeTextRequest (fast mode) to find text bounding boxes.
    /// Falls back to saliency only when text detection finds too few results
    /// (non-text pages like images or diagrams).
    private func visionDetect(in image: CGImage) -> CGRect? {
        let handler = VNImageRequestHandler(cgImage: image)
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()

        do {
            try handler.perform([textRequest, saliencyRequest])
        } catch {
            return nil
        }

        // Text recognition — finds actual text content precisely
        var contentRect: CGRect?
        let textCount = textRequest.results?.count ?? 0
        if let results = textRequest.results {
            for obs in results {
                if let existing = contentRect {
                    contentRect = existing.union(obs.boundingBox)
                } else {
                    contentRect = obs.boundingBox
                }
            }
        }

        // Only use saliency as fallback when text detection found very little
        // (non-text pages like images, diagrams). On text-heavy pages, saliency
        // can detect decorative elements near page edges and expand the rect,
        // undermining the trim.
        if textCount < 3,
           let result = saliencyRequest.results?.first,
           let objects = result.salientObjects {
            for obj in objects where obj.confidence > 0.3 {
                if let existing = contentRect {
                    contentRect = existing.union(obj.boundingBox)
                } else {
                    contentRect = obj.boundingBox
                }
            }
        }

        guard let visionRect = contentRect else { return nil }

        // Vision coordinates: bottom-left origin, normalized 0..1.
        // Convert to top-left origin for CGImage.
        let padding: CGFloat = 0.015
        let x = max(0, visionRect.minX - padding)
        let y = max(0, 1.0 - visionRect.maxY - padding)
        let w = min(1.0 - x, visionRect.width + padding * 2)
        let h = min(1.0 - y, visionRect.height + padding * 2)
        let rect = CGRect(x: x, y: y, width: w, height: h)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        // Only trim if removing some whitespace (>0.5% on any edge)
        let minTrim: CGFloat = 0.005
        guard rect.minX > minTrim || rect.minY > minTrim ||
              rect.maxX < 1.0 - minTrim || rect.maxY < 1.0 - minTrim else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return rect
    }

    /// Pixel-based fallback: samples edge pixels to determine background color,
    /// then scans inward from each edge to find where content begins.
    private func pixelDetect(in image: CGImage) -> CGRect {
        let aw = min(image.width, 400)
        let ah = min(image.height, 600)
        let bytesPerRow = aw * 4

        guard let ctx = CGContext(
            data: nil, width: aw, height: ah,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        // Flip context so row 0 in memory = top of image (matches CGImage coordinates)
        ctx.translateBy(x: 0, y: CGFloat(ah))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: aw, height: ah))

        guard let data = ctx.data else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * ah)

        // Sample edge pixels to determine background color
        var totalR = 0, totalG = 0, totalB = 0, sampleCount = 0
        let step = max(1, min(aw, ah) / 20)
        for x in stride(from: 0, to: aw, by: step) {
            for y in [0, ah - 1] {
                let off = y * bytesPerRow + x * 4
                totalR += Int(pixels[off])
                totalG += Int(pixels[off + 1])
                totalB += Int(pixels[off + 2])
                sampleCount += 1
            }
        }
        for y in stride(from: 0, to: ah, by: step) {
            for x in [0, aw - 1] {
                let off = y * bytesPerRow + x * 4
                totalR += Int(pixels[off])
                totalG += Int(pixels[off + 1])
                totalB += Int(pixels[off + 2])
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let bgR = totalR / sampleCount
        let bgG = totalG / sampleCount
        let bgB = totalB / sampleCount
        let colorThreshold = 30

        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let off = y * bytesPerRow + x * 4
            let dr = abs(Int(pixels[off]) - bgR)
            let dg = abs(Int(pixels[off + 1]) - bgG)
            let db = abs(Int(pixels[off + 2]) - bgB)
            return dr + dg + db < colorThreshold
        }

        func rowHasContent(_ y: Int) -> Bool {
            for x in stride(from: 0, to: aw, by: max(1, aw / 50)) {
                if !isBackground(x, y) { return true }
            }
            return false
        }

        func colHasContent(_ x: Int) -> Bool {
            for y in stride(from: 0, to: ah, by: max(1, ah / 50)) {
                if !isBackground(x, y) { return true }
            }
            return false
        }

        var top = 0
        while top < ah && !rowHasContent(top) { top += 1 }
        var bottom = ah - 1
        while bottom > top && !rowHasContent(bottom) { bottom -= 1 }
        var left = 0
        while left < aw && !colHasContent(left) { left += 1 }
        var right = aw - 1
        while right > left && !colHasContent(right) { right -= 1 }

        let padding: CGFloat = 0.005
        let nx = max(0, CGFloat(left) / CGFloat(aw) - padding)
        let ny = max(0, CGFloat(top) / CGFloat(ah) - padding)
        let nw = min(1.0 - nx, CGFloat(right - left + 1) / CGFloat(aw) + padding * 2)
        let nh = min(1.0 - ny, CGFloat(bottom - top + 1) / CGFloat(ah) + padding * 2)

        let rect = CGRect(x: nx, y: ny, width: nw, height: nh)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        let minTrim: CGFloat = 0.01
        guard rect.minX > minTrim || rect.minY > minTrim ||
              rect.maxX < 1.0 - minTrim || rect.maxY < 1.0 - minTrim else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        return rect
    }
}
