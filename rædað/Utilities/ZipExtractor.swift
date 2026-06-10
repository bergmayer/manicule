import Foundation
import ZIPFoundation

/// Extracts ZIP archive contents to a temporary directory.
enum ZipExtractor: Sendable {
    /// Extracts a ZIP archive from in-memory data to a unique temp directory.
    /// Returns the URL of the extraction root directory.
    /// Entries whose paths would escape the extraction root (zip-slip) are skipped.
    nonisolated static func extract(data: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("raedad-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let archive = try Archive(data: data, accessMode: .read)

        for entry in archive {
            let destinationURL = tempDir.appendingPathComponent(entry.path).standardized
            guard destinationURL.path.hasPrefix(tempDir.path + "/") else { continue }
            // Skip directory entries — createDirectory handles them
            if entry.type == .directory {
                try FileManager.default.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
                continue
            }
            // Ensure parent directory exists
            let parentDir = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destinationURL)
        }

        return tempDir
    }

    /// Collects image files under a directory, sorted by filename (natural order).
    nonisolated static func imageFiles(under directory: URL) -> [URL] {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff"]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        var images: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                images.append(url)
            }
        }
        return images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Extracts images from a ZIP archive (for CBZ comics).
    /// Returns sorted image file URLs.
    nonisolated static func extractImages(data: Data) throws -> [URL] {
        imageFiles(under: try extract(data: data))
    }
}
