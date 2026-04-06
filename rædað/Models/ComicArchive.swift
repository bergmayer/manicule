import Foundation
import os.log
@preconcurrency import Unrar

private nonisolated let comicLog = Logger(subsystem: "com.palefire.raedad", category: "Comic")

/// Represents a parsed CBZ/CBR comic book archive.
struct ComicArchive: Sendable {
    let extractionDirectory: URL
    let pages: [URL]       // sorted image file URLs
    let pageCount: Int

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
        let pages = try ZipExtractor.extractImages(data: data)
        guard !pages.isEmpty else {
            throw DocumentError.parsingFailed("No images found in comic archive")
        }
        let extractionDir = pages[0].deletingLastPathComponent()
        return ComicArchive(
            extractionDirectory: extractionDir,
            pages: pages,
            pageCount: pages.count
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
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-cbr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let archive = try Unrar.Archive(fileURL: tempFile)
        comicLog.info("extractRAR: archive opened")
        let entries = try archive.entries()
        comicLog.info("extractRAR: \(entries.count) entries")

        for entry in entries {
            guard !entry.directory else { continue }
            let ext = (entry.fileName as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }

            // Use callback-based extraction for reliability
            var entryData = Data()
            try archive.extract(entry) { chunk, _ in
                entryData.append(chunk)
            }
            guard !entryData.isEmpty else { continue }

            let destinationURL = outputDir.appendingPathComponent(entry.fileName)
            let parentDir = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try entryData.write(to: destinationURL)
        }

        // Collect and sort extracted images
        let enumerator = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: nil)
        var images: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                images.append(url)
            }
        }
        images.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !images.isEmpty else {
            throw DocumentError.parsingFailed("No images found in CBR archive")
        }
        return ComicArchive(
            extractionDirectory: outputDir,
            pages: images,
            pageCount: images.count
        )
    }
}
