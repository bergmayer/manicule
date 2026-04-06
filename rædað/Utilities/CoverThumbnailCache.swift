import Foundation
@preconcurrency import PDFKit
import ImageIO
import UniformTypeIdentifiers
import os.log

/// Generates and caches cover thumbnails for documents on disk.
/// Thumbnails are stored as JPEGs in the app's Caches directory, keyed by fileHash.
/// Small versions are also synced via iCloud KV store so covers appear on all devices.
/// All heavy work uses CGImage (not UIImage/NSImage) to avoid main-actor constraints.
final class CoverThumbnailCache: Sendable {
    static let shared = CoverThumbnailCache()
    private nonisolated static let logger = Logger(subsystem: "com.palefire.raedad", category: "CoverCache")

    private let cacheDir: URL
    private let maxDim: CGFloat = 240
    /// Smaller dimension for the iCloud-synced version (keeps JPEG under ~8KB)
    private let syncDim: CGFloat = 120
    private nonisolated static let iCloudCoverPrefix = "raedad.cover."

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("cover-thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Pull any covers synced from other devices into local cache
        pullCoversFromiCloud()

        // Listen for iCloud changes to get covers from other devices
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] _ in
            self?.pullCoversFromiCloud()
        }
    }

    // MARK: - Public API

    /// Returns the cached thumbnail path if it exists on disk.
    func cachedPath(for fileHash: String) -> URL? {
        let path = jpegPath(for: fileHash)
        if FileManager.default.fileExists(atPath: path.path) { return path }
        // Try pulling from iCloud if not in local cache
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.iCloudCoverPrefix + fileHash) {
            try? data.write(to: path, options: .atomic)
            return path
        }
        return nil
    }

    /// Generate and cache a cover from parsed document content (called at open time).
    /// Dispatches heavy work to a background thread. Also syncs to iCloud.
    func generateIfNeeded(for content: DocumentContent, fileHash: String) {
        let path = jpegPath(for: fileHash)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            // Local cache exists — ensure it's also in iCloud
            pushCoverToiCloudIfNeeded(fileHash: fileHash)
            return
        }
        let dim = maxDim
        let syncDim = self.syncDim
        Task.detached(priority: .utility) {
            guard let cgImage = Self.extractCover(from: content, maxDim: dim) else { return }
            Self.saveCGImageAsJPEG(cgImage, to: path)
            // Also create a small version for iCloud sync
            Self.pushToiCloud(cgImage: cgImage, fileHash: fileHash, syncDim: syncDim)
        }
    }

    /// Generate a cover from raw file data + URL (for Recents grid on-demand generation).
    /// Runs synchronously — caller is responsible for dispatching to background.
    nonisolated func generateFromFileSync(at url: URL, data: Data, fileHash: String) {
        let path = jpegPath(for: fileHash)
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        guard let cgImage = Self.extractCoverFromFile(url: url, data: data, maxDim: maxDim) else { return }
        Self.saveCGImageAsJPEG(cgImage, to: path)
        Self.pushToiCloud(cgImage: cgImage, fileHash: fileHash, syncDim: syncDim)
    }

    private nonisolated func jpegPath(for fileHash: String) -> URL {
        cacheDir.appendingPathComponent("\(fileHash).jpg")
    }

    // MARK: - iCloud Sync

    /// Push a cover thumbnail to iCloud KV store (small JPEG for cross-device sync).
    private nonisolated static func pushToiCloud(cgImage: CGImage, fileHash: String, syncDim: CGFloat) {
        // Re-encode the CGImage as JPEG data at lower quality for sync
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.5] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        let jpegData = mutableData as Data

        // Only sync if under 60KB (iCloud KV per-key limit is 64KB)
        guard jpegData.count < 60_000 else {
            logger.info("Cover too large for iCloud sync: \(jpegData.count) bytes")
            return
        }

        let key = iCloudCoverPrefix + fileHash
        NSUbiquitousKeyValueStore.default.set(jpegData, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Ensure a locally cached cover is also pushed to iCloud.
    private func pushCoverToiCloudIfNeeded(fileHash: String) {
        let key = Self.iCloudCoverPrefix + fileHash
        guard NSUbiquitousKeyValueStore.default.data(forKey: key) == nil else { return }
        // Read from local cache and push
        let path = jpegPath(for: fileHash)
        guard let data = try? Data(contentsOf: path), data.count < 60_000 else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    /// Pull all cover thumbnails from iCloud KV store into the local cache.
    private func pullCoversFromiCloud() {
        let store = NSUbiquitousKeyValueStore.default
        let allKeys = store.dictionaryRepresentation.keys
        var pulled = 0
        for key in allKeys where key.hasPrefix(Self.iCloudCoverPrefix) {
            let fileHash = String(key.dropFirst(Self.iCloudCoverPrefix.count))
            let localPath = jpegPath(for: fileHash)
            guard !FileManager.default.fileExists(atPath: localPath.path) else { continue }
            if let data = store.data(forKey: key) {
                try? data.write(to: localPath, options: .atomic)
                pulled += 1
            }
        }
        if pulled > 0 {
            Self.logger.info("Pulled \(pulled) cover(s) from iCloud")
        }
    }

    // MARK: - Cover Extraction (all CGImage, no UIImage/NSImage)

    private nonisolated static func extractCover(from content: DocumentContent, maxDim: CGFloat) -> CGImage? {
        switch content {
        case .pdf(let data):
            return pdfCover(data: data, maxDim: maxDim)
        case .epub(let book):
            return epubCover(book: book, maxDim: maxDim)
        case .comic(let archive):
            return imageCover(url: archive.pages.first, maxDim: maxDim)
        case .plainText, .markdown:
            return nil
        }
    }

    private nonisolated static func extractCoverFromFile(url: URL, data: Data, maxDim: CGFloat) -> CGImage? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return pdfCover(data: data, maxDim: maxDim)
        case "epub":
            guard let book = try? EPubParser.parse(data: data) else { return nil }
            return epubCover(book: book, maxDim: maxDim)
        case "cbz":
            guard let archive = try? ComicArchiveParser.parse(data: data) else { return nil }
            return imageCover(url: archive.pages.first, maxDim: maxDim)
        case "cbr":
            guard let archive = try? ComicArchiveParser.parseRAR(data: data) else { return nil }
            return imageCover(url: archive.pages.first, maxDim: maxDim)
        default:
            return nil
        }
    }

    // MARK: - Per-type extraction

    private nonisolated static func pdfCover(data: Data, maxDim: CGFloat) -> CGImage? {
        guard let doc = PDFDocument(data: data),
              let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(maxDim / bounds.width, maxDim / bounds.height, 2.0)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        #if canImport(UIKit)
        return page.thumbnail(of: size, for: .mediaBox).cgImage
        #else
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }

    private nonisolated static func epubCover(book: EPubBook, maxDim: CGFloat) -> CGImage? {
        // Inline cover URL resolution to avoid calling actor-isolated coverImageURL()
        let coverURL: URL? = {
            if let item = book.manifest.values.first(where: { $0.properties?.contains("cover-image") == true }) {
                let url = book.extractionDirectory.appendingPathComponent(item.href)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            if let metaID = book.coverMetaID, let item = book.manifest[metaID] {
                let url = book.extractionDirectory.appendingPathComponent(item.href)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            if let item = book.manifest.values.first(where: {
                $0.mediaType.hasPrefix("image/") &&
                ($0.id.localizedCaseInsensitiveContains("cover") ||
                 $0.href.localizedCaseInsensitiveContains("cover"))
            }) {
                let url = book.extractionDirectory.appendingPathComponent(item.href)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        }()
        return imageCover(url: coverURL, maxDim: maxDim)
    }

    /// Load an image file URL and downscale via ImageIO (no UIImage/NSImage needed).
    private nonisolated static func imageCover(url: URL?, maxDim: CGFloat) -> CGImage? {
        guard let url else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDim),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Save

    private nonisolated static func saveCGImageAsJPEG(_ cgImage: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
