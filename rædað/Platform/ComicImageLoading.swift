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

/// Loads a page as a CGImage, optionally downsampling before decode and
/// applying the cached normalized trim rectangle. Returning Core Graphics
/// keeps disk I/O and decode work safe for detached tasks on every platform.
nonisolated func loadComicPageCGImage(
    at url: URL,
    trim: Bool,
    maxPixelSize: Int? = nil
) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let image: CGImage?
    if let maxPixelSize {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    } else {
        image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    guard let image else { return nil }
    return trim ? ContentTrimmer.shared.trimmed(image, key: url.path) : image
}

#if canImport(UIKit)
/// Loads a comic page from disk, optionally trimming whitespace borders.
/// The trim result is cached by the file's full path — comics extract into
/// per-archive UUID directories, so paths stay unique even when page
/// filenames (e.g. "001.jpg") repeat across different books.
nonisolated func loadComicImage(at url: URL, trim: Bool) -> UIImage? {
    guard let image = loadComicPageCGImage(at: url, trim: trim) else { return nil }
    return UIImage(cgImage: image)
}
#endif

#if canImport(AppKit)
/// Loads a comic page from disk, optionally trimming whitespace borders.
/// The trim result is cached by the file's full path — comics extract into
/// per-archive UUID directories, so paths stay unique even when page
/// filenames (e.g. "001.jpg") repeat across different books.
nonisolated func loadComicImage(at url: URL, trim: Bool) -> NSImage? {
    guard let image = loadComicPageCGImage(at: url, trim: trim) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
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
