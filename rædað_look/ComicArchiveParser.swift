import Foundation
@preconcurrency import Unrar

/// Minimal comic archive model for QuickLook preview.
struct ComicArchive: Sendable {
    let pages: [URL]
}

/// Parses CBZ/CBR archives to extract page image URLs.
enum ComicArchiveParser: Sendable {
    private nonisolated static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"]

    /// Parse a CBZ (ZIP) comic archive. Returns sorted image URLs.
    nonisolated static func parseCBZ(data: Data) throws -> ComicArchive {
        let pages = try ZipExtractor.extractImages(data: data)
        guard !pages.isEmpty else {
            throw DocumentError.noImagesFound
        }
        return ComicArchive(pages: pages)
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
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-ql-cbr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let archive = try Unrar.Archive(fileURL: tempFile)
        let entries = try archive.entries()

        for entry in entries {
            guard !entry.directory else { continue }
            let ext = (entry.fileName as NSString).pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }

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

        let enumerator = FileManager.default.enumerator(at: outputDir, includingPropertiesForKeys: nil)
        var images: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                images.append(url)
            }
        }
        images.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        guard !images.isEmpty else { throw DocumentError.noImagesFound }
        return ComicArchive(pages: images)
    }
}
