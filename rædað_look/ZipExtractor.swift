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
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: tempDir) }
        }

        let archive = try Archive(data: data, accessMode: .read)
        var entryCount = 0
        var totalUncompressedSize: UInt64 = 0

        for entry in archive {
            entryCount += 1
            guard entryCount <= 100_000,
                  entry.uncompressedSize <= 1_073_741_824,
                  totalUncompressedSize <= 4_294_967_296 - entry.uncompressedSize else {
                throw DocumentError.zipExtractionFailed
            }
            totalUncompressedSize += entry.uncompressedSize
            let destinationURL = tempDir.appendingPathComponent(entry.path).standardized
            guard destinationURL.path.hasPrefix(tempDir.path + "/") else { continue }
            if entry.type == .directory {
                try FileManager.default.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
                continue
            }
            guard entry.type == .file else { continue }
            let parentDir = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destinationURL)
        }

        completed = true
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

}
