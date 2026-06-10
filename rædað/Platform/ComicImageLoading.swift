import SwiftUI
import ImageIO

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Reads image pixel dimensions without decoding the full image. Used by the
/// comic strip view to lay out its scroll content before any image is loaded.
func imageDimensions(at url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
          let w = props[kCGImagePropertyPixelWidth as String] as? Int,
          let h = props[kCGImagePropertyPixelHeight as String] as? Int else { return nil }
    return CGSize(width: w, height: h)
}

/// Loads a downsampled image via ImageIO without decoding the full bitmap.
/// Used for sidebar thumbnails where full-resolution pages waste memory.
nonisolated func loadComicThumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

#if canImport(UIKit)
/// Loads a comic page from disk, optionally trimming whitespace borders.
/// The trim result is cached by the file's full path — comics extract into
/// per-archive UUID directories, so paths stay unique even when page
/// filenames (e.g. "001.jpg") repeat across different books.
nonisolated func loadComicImage(at url: URL, trim: Bool) -> UIImage? {
    guard let image = UIImage(contentsOfFile: url.path) else { return nil }
    guard trim, let cgImage = image.cgImage else { return image }
    let trimmed = ContentTrimmer.shared.trimmed(cgImage, key: url.path)
    return UIImage(cgImage: trimmed, scale: image.scale, orientation: image.imageOrientation)
}
#endif

#if canImport(AppKit)
/// Loads a comic page from disk, optionally trimming whitespace borders.
/// The trim result is cached by the file's full path — comics extract into
/// per-archive UUID directories, so paths stay unique even when page
/// filenames (e.g. "001.jpg") repeat across different books.
nonisolated func loadComicImage(at url: URL, trim: Bool) -> NSImage? {
    guard let image = NSImage(contentsOf: url) else { return nil }
    guard trim, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
    let trimmed = ContentTrimmer.shared.trimmed(cgImage, key: url.path)
    return NSImage(cgImage: trimmed, size: NSSize(width: trimmed.width, height: trimmed.height))
}

/// NSImageView with a flipped coordinate system, used inside scroll views
/// that need top-down layout (e.g. the comic strip view).
final class FlippedNSImageView: NSImageView {
    override var isFlipped: Bool { true }
}

/// NSView with a flipped coordinate system. The container of stacked image
/// views in the comic strip uses this so vertical layout reads top-to-bottom.
final class FlippedNSView: NSView {
    override var isFlipped: Bool { true }
}
#endif
