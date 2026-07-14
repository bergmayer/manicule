import Foundation
@preconcurrency import Unrar

/// Minimal comic archive model for QuickLook preview.
struct ComicArchive: Sendable {
    let pages: [URL]
    private let extractionLease: TemporaryDirectoryLease

    nonisolated init(extractionLease: TemporaryDirectoryLease, pages: [URL]) {
        self.extractionLease = extractionLease
        self.pages = pages
    }
}

/// Parses CBZ/CBR archives to extract page image URLs.
enum ComicArchiveParser: Sendable {
    private nonisolated static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"]

    /// Parse a CBZ (ZIP) comic archive. Returns sorted image URLs.
    nonisolated static func parseCBZ(data: Data) throws -> ComicArchive {
        let extractionDir = try ZipExtractor.extract(data: data)
        let extractionLease = TemporaryDirectoryLease(url: extractionDir)
        let pages = ZipExtractor.imageFiles(under: extractionDir)
        guard !pages.isEmpty else {
            throw DocumentError.noImagesFound
        }
        return ComicArchive(extractionLease: extractionLease, pages: pages)
    }

    /// Parse a CBR (RAR) comic archive. Falls back to ZIP if RAR fails.
    nonisolated static func parseCBR(data: Data) throws -> ComicArchive {
        do {
            return try extractRAR(data: data)
        } catch {
            // Some .cbr files are actually ZIP archives
            do {
                return try parseCBZ(data: data)
            } catch {
                throw DocumentError.noImagesFound
            }
        }
    }

    private nonisolated static func extractRAR(data: Data) throws -> ComicArchive {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-ql-cbr-\(UUID().uuidString).cbr")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try data.write(to: tempFile, options: .atomic)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-ql-cbr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let extractionLease = TemporaryDirectoryLease(url: outputDir)

        let archive = try Unrar.Archive(fileURL: tempFile)
        let entries = try archive.entries()
        guard entries.count <= 100_000 else { throw DocumentError.zipExtractionFailed }
        var totalUncompressedSize: UInt64 = 0

        for entry in entries {
            guard !entry.directory else { continue }
            let ext = (entry.fileName as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }
            guard entry.uncompressedSize <= 1_073_741_824,
                  totalUncompressedSize <= 4_294_967_296 - entry.uncompressedSize else {
                throw DocumentError.zipExtractionFailed
            }
            totalUncompressedSize += entry.uncompressedSize

            // Reject entry paths that would escape the output directory
            let destinationURL = outputDir.appendingPathComponent(entry.fileName).standardized
            guard destinationURL.path.hasPrefix(outputDir.path + "/") else { continue }

            let parentDir = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destinationURL)
            var writeError: Error?
            do {
                try archive.extract(entry) { chunk, _ in
                    guard writeError == nil else { return }
                    do { try handle.write(contentsOf: chunk) }
                    catch { writeError = error }
                }
                try handle.close()
                if let writeError { throw writeError }
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
        }

        let images = ZipExtractor.imageFiles(under: outputDir)
        guard !images.isEmpty else { throw DocumentError.noImagesFound }
        return ComicArchive(extractionLease: extractionLease, pages: images)
    }
}
