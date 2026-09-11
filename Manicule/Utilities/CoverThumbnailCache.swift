import Foundation
@preconcurrency import PDFKit
import ImageIO
import UniformTypeIdentifiers
import os.log

/// Generates and caches cover thumbnails for documents on disk.
/// Thumbnails are stored as JPEGs in the app's Caches directory, keyed by fileHash.
/// Small versions are also synced via iCloud KV store so covers appear on all devices.
/// All heavy work uses CGImage (not UIImage/NSImage) to avoid main-actor constraints.
@MainActor
final class CoverThumbnailCache {
    static let shared = CoverThumbnailCache()
    private nonisolated static let logger = Logger(subsystem: "com.palefire.manicule", category: "CoverCache")

    private let cacheDir: URL
    private var jobs: [String: Task<Void, Never>] = [:]
    private let renderer = CoverRenderer()

    private enum Source: Sendable {
        case content(DocumentContent)
        case file(URL, Data)
    }

    /// Serialize archive/PDF decoding so rapid library changes cannot start
    /// an unbounded number of heavy extractions in parallel.
    private actor CoverRenderer {
        func image(_ source: Source, dimension: CGFloat) -> CGImage? {
            guard !Task.isCancelled else { return nil }
            switch source {
            case .content(let content): return CoverThumbnailCache.extractCover(from: content, maxDim: dimension)
            case .file(let url, let data): return CoverThumbnailCache.extractCoverFromFile(url: url, data: data, maxDim: dimension)
            }
        }
    }
    private let maxDim: CGFloat = 240
    /// Smaller dimension for the iCloud-synced version (keeps JPEG under ~8KB)
    private let syncDim: CGFloat = 120
    private nonisolated static let iCloudCoverPrefix = "manicule.cover."

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
            MainActor.assumeIsolated { self?.pullCoversFromiCloud() }
        }
    }

    // MARK: - Public API

    /// Returns the cached thumbnail path if it exists on disk.
    func cachedPath(for fileHash: String) -> URL? {
        let path = jpegPath(for: fileHash)
        if FileManager.default.fileExists(atPath: path.path) { return path }
        // Try pulling from iCloud if not in local cache
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: Self.iCloudCoverPrefix + fileHash) {
            do {
                try data.write(to: path, options: .atomic)
                return path
            } catch { Self.logger.info("Cover cache write failed: \(error.localizedDescription)") }
        }
        return nil
    }

    func generateIfNeeded(for content: DocumentContent, fileHash: String) {
        generate(.content(content), fileHash: fileHash)
    }

    func generateFromFile(at url: URL, data: Data, fileHash: String) {
        generate(.file(url, data), fileHash: fileHash)
    }

    func waitForCover(for fileHash: String) async {
        await jobs[fileHash]?.value
    }

    private func generate(_ source: Source, fileHash: String) {
        guard jobs[fileHash] == nil else { return }
        let path = jpegPath(for: fileHash)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            pushCoverToiCloudIfNeeded(fileHash: fileHash)
            return
        }
        jobs[fileHash] = Task { [weak self, renderer, maxDim] in
            let image = await renderer.image(source, dimension: maxDim)
            guard !Task.isCancelled, let self else { return }
            defer { jobs.removeValue(forKey: fileHash) }
            guard let image else { return }
            Self.saveCGImageAsJPEG(image, to: path)
            Self.pushToiCloud(cgImage: image, fileHash: fileHash, syncDim: syncDim)
        }
    }

    /// Delete the cached cover (local JPEG and the iCloud-synced copy).
    /// Called when a book leaves the tracked list so cover data doesn't
    /// accumulate in the Caches directory and the iCloud KV quota.
    func removeCover(for fileHash: String) {
        jobs.removeValue(forKey: fileHash)?.cancel()
        try? FileManager.default.removeItem(at: jpegPath(for: fileHash))
        NSUbiquitousKeyValueStore.default.removeObject(forKey: Self.iCloudCoverPrefix + fileHash)
    }

    /// Moves a cached cover from a legacy content identifier to its full-data
    /// identifier without regenerating the thumbnail.
    func migrateCover(from legacyHash: String, to fileHash: String) {
        guard legacyHash != fileHash else { return }
        jobs.removeValue(forKey: legacyHash)?.cancel()
        let oldPath = jpegPath(for: legacyHash)
        let newPath = jpegPath(for: fileHash)
        if FileManager.default.fileExists(atPath: oldPath.path) {
            if !FileManager.default.fileExists(atPath: newPath.path) {
                try? FileManager.default.moveItem(at: oldPath, to: newPath)
            } else {
                try? FileManager.default.removeItem(at: oldPath)
            }
        }

        let store = NSUbiquitousKeyValueStore.default
        let oldKey = Self.iCloudCoverPrefix + legacyHash
        let newKey = Self.iCloudCoverPrefix + fileHash
        if store.data(forKey: newKey) == nil, let data = store.data(forKey: oldKey) {
            store.set(data, forKey: newKey)
        }
        store.removeObject(forKey: oldKey)
        store.synchronize()
    }

    private func jpegPath(for fileHash: String) -> URL {
        // Hashes from cloud data are an external boundary, not trusted paths.
        let component = (fileHash.count == 32 || fileHash.count == 64) && fileHash.allSatisfy(\.isHexDigit)
            ? fileHash : FileHasher.hash(data: Data(fileHash.utf8))
        return cacheDir.appendingPathComponent("\(component).jpg")
    }

    // MARK: - iCloud Sync

    /// Push a cover thumbnail to iCloud KV store (small JPEG for cross-device sync).
    private static func pushToiCloud(cgImage: CGImage, fileHash: String, syncDim: CGFloat) {
        guard let syncImage = resized(cgImage, maxDimension: syncDim) else { return }
        var jpegData: Data?
        for quality in [0.55, 0.42, 0.3] {
            let mutableData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                mutableData, UTType.jpeg.identifier as CFString, 1, nil
            ) else { return }
            CGImageDestinationAddImage(
                dest,
                syncImage,
                [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            )
            guard CGImageDestinationFinalize(dest) else { continue }
            let candidate = mutableData as Data
            if candidate.count < 12_000 {
                jpegData = candidate
                break
            }
        }

        // Keeping each of at most 60 covers below 12 KiB also respects the
        // iCloud KVS store-wide quota, not merely its per-key limit.
        guard let jpegData else {
            logger.info("Cover could not be reduced enough for iCloud sync")
            return
        }

        let key = iCloudCoverPrefix + fileHash
        // Covers yield quota to irreplaceable reading state.
        do { try ReadingCloud.write(jpegData, key: key) }
        catch { logger.info("Cover sync skipped: \(error.localizedDescription)") }
    }

    /// Ensure a locally cached cover is also pushed to iCloud.
    private func pushCoverToiCloudIfNeeded(fileHash: String) {
        let key = Self.iCloudCoverPrefix + fileHash
        guard NSUbiquitousKeyValueStore.default.data(forKey: key) == nil else { return }
        let path = jpegPath(for: fileHash)
        guard let source = CGImageSourceCreateWithURL(path as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        Self.pushToiCloud(cgImage: image, fileHash: fileHash, syncDim: syncDim)
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
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        do { try (data as Data).write(to: url, options: .atomic) }
        catch { logger.info("Cover cache write failed: \(error.localizedDescription)") }
    }

    private nonisolated static func resized(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = max(1, Int((width * scale).rounded()))
        let targetHeight = max(1, Int((height * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }
}
