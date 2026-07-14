import Foundation
import os.log
@preconcurrency import Unrar

private nonisolated let comicLog = Logger(subsystem: "com.palefire.raedad", category: "Comic")

/// Represents a parsed CBZ/CBR comic book archive.
struct ComicArchive: Sendable {
    let extractionDirectory: URL
    let pages: [URL]       // sorted image file URLs
    let pageCount: Int
    private let extractionLease: TemporaryDirectoryLease

    nonisolated init(extractionLease: TemporaryDirectoryLease, pages: [URL]) {
        self.extractionLease = extractionLease
        self.extractionDirectory = extractionLease.url
        self.pages = pages
        self.pageCount = pages.count
    }

    /// Reading direction preference for the comic.
    enum ReadingDirection: String, Codable, Sendable, CaseIterable {
        case leftToRight    // Western comics
        case rightToLeft    // Manga

        var displayName: String {
            switch self {
            case .leftToRight: return "Western (L\u{2192}R)"
            case .rightToLeft: return "Manga (R\u{2192}L)"
            }
        }
    }
}

/// Parses CBZ (ZIP) and CBR (RAR) comic book archives.
enum ComicArchiveParser: Sendable {
    private nonisolated static var imageExtensions: Set<String> { ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"] }

    /// Parse a CBZ (ZIP) comic archive from in-memory data.
    nonisolated static func parse(data: Data) throws -> ComicArchive {
        let extractionDir = try ZipExtractor.extract(data: data)
        let extractionLease = TemporaryDirectoryLease(url: extractionDir)
        let pages = ZipExtractor.imageFiles(under: extractionDir)
        guard !pages.isEmpty else {
            throw DocumentError.parsingFailed("No images found in comic archive")
        }
        return ComicArchive(
            extractionLease: extractionLease,
            pages: pages
        )
    }

    /// Parse a CBR (RAR) comic archive from in-memory data.
    /// Falls back to ZIP extraction if the file is a renamed ZIP archive.
    nonisolated static func parseRAR(data: Data) throws -> ComicArchive {
        // Some CBR files are actually ZIP archives renamed to .cbr
        // Try RAR first, fall back to ZIP
        comicLog.info("parseRAR: data size=\(data.count) bytes")
        do {
            let result = try extractRAR(data: data)
            comicLog.info("parseRAR: RAR extraction succeeded, \(result.pageCount) pages")
            return result
        } catch let rarError {
            comicLog.info("parseRAR: RAR failed: \(rarError.localizedDescription, privacy: .public), trying ZIP fallback")
            do {
                return try parse(data: data)
            } catch {
                comicLog.error("parseRAR: ZIP fallback also failed: \(error.localizedDescription, privacy: .public)")
                throw rarError
            }
        }
    }

    /// Extract a RAR archive to images.
    private nonisolated static func extractRAR(data: Data) throws -> ComicArchive {
        // Unrar.swift requires a file path, so write data to a temp file
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-cbr-\(UUID().uuidString).cbr")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        try data.write(to: tempFile, options: .atomic)

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-cbr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let extractionLease = TemporaryDirectoryLease(url: outputDir)

        let archive = try Unrar.Archive(fileURL: tempFile)
        comicLog.info("extractRAR: archive opened")
        let entries = try archive.entries()
        comicLog.info("extractRAR: \(entries.count) entries")
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
        guard !images.isEmpty else {
            throw DocumentError.parsingFailed("No images found in CBR archive")
        }
        return ComicArchive(
            extractionLease: extractionLease,
            pages: images
        )
    }
}
